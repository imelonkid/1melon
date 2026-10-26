import Crypto
import Foundation

/// 本机快速解锁（Touch ID 等）用的「账户密钥信封」。**只在这台设备上有效，不进保险库格式、不同步**。
///
/// 做法：账户密钥 AK 用一把 P-256 密钥协商出来的对称密钥加密。桌面端那把私钥在安全隔区里，
/// 每次使用都要过 Touch ID；文件里只有它的不透明句柄（离开这台 Mac 就没用）和一个临时公钥。
///
///   wrapKey = HKDF-SHA256(ECDH(设备私钥, 临时公钥), salt = accountId, info = "1melon:v1:local-unlock")
///   sealed  = AES-256-GCM(wrapKey, AK, AAD = "1melon:v1:local-unlock:<accountId>")
public struct LocalUnlockFile: Codable, Equatable, Sendable {
    public static let formatName = "1melon-local-unlock"

    public var format = formatName
    public var version = 1
    public var accountId: String
    /// 设备私钥的不透明句柄（桌面端：安全隔区密钥的 dataRepresentation）
    public var deviceKey: Data
    /// 临时公钥（X9.63 未压缩格式）
    public var ephemeralPublicKey: Data
    var sealed: Sealed

    static func info() -> Data { Data("1melon:v1:local-unlock".utf8) }
    static func aad(_ accountId: String) -> Data { Data("1melon:v1:local-unlock:\(accountId)".utf8) }

    /// 把账户密钥封给 `recipient`（设备私钥对应的公钥）。
    public static func seal(account: UnlockedAccount, to recipient: P256.KeyAgreement.PublicKey, deviceKey: Data) throws -> LocalUnlockFile {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let wrapKey = derive(shared, accountId: account.accountId)
        let akBytes = account.accountKey.withUnsafeBytes { Data($0) }
        return LocalUnlockFile(
            accountId: account.accountId, deviceKey: deviceKey,
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            sealed: try MelonCore.seal(akBytes, key: wrapKey, aad: aad(account.accountId))
        )
    }

    /// 用设备私钥算出共享密钥后打开，得到账户密钥。`agree` 由调用方提供（桌面端里会弹 Touch ID）。
    public func open(agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> SymmetricKey {
        guard format == Self.formatName, version == 1 else { throw VaultError.invalidFormat("不是本机解锁文件") }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)
        let wrapKey = Self.derive(try agree(ephemeral), accountId: accountId)
        do {
            return SymmetricKey(data: try unseal(sealed, key: wrapKey, aad: Self.aad(accountId)))
        } catch {
            throw VaultError.tampered("本机解锁文件无法解开")
        }
    }

    static func derive(_ shared: SharedSecret, accountId: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(accountId.utf8), sharedInfo: info(), outputByteCount: 32)
    }
}

public extension AccountRepository {
    /// 只属于这台设备的东西（本机解锁文件）。以后做云同步时，这个目录**不同步**。
    var deviceDirectory: URL { root.appendingPathComponent("device") }
    var localUnlockURL: URL { deviceDirectory.appendingPathComponent("local-unlock.json") }

    /// 用账户密钥直接解锁（本机快速解锁）。
    /// 账户密钥不对（比如账户重建过）时，保险库会全部打不开：这种情况按主密码错误处理，让用户输主密码。
    func unlock(accountKey: SymmetricKey) throws -> LoadedAccount {
        let account = try UnlockedAccount.open(try VaultStore.read(accountURL), accountKey: accountKey, secretKey: readSecretKey())
        let loaded = loadVaults(account)
        if loaded.vaults.isEmpty && !loaded.failures.isEmpty { throw VaultError.wrongPassword }
        return loaded
    }

    func readLocalUnlock() -> LocalUnlockFile? {
        guard let data = try? VaultStore.read(localUnlockURL) else { return nil }
        return try? JSONDecoder().decode(LocalUnlockFile.self, from: data)
    }

    func writeLocalUnlock(_ file: LocalUnlockFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try VaultStore.write(try encoder.encode(file), to: localUnlockURL)
    }

    func removeLocalUnlock() {
        try? FileManager.default.removeItem(at: localUnlockURL)
    }
}

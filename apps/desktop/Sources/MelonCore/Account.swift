import Crypto
import Foundation

/// 账户文件 `account.1melon`（spec §3.1）：主密码派生的 KEK 包装账户密钥 AK；AK 再包装各保险库的密钥。
struct AccountFile {
    static let formatName = "1melon-account"
    static let currentVersion = 1

    var format = formatName
    var version = currentVersion
    var accountId: String
    var kdf: KDFParameters
    /// Secret Key 预留位（spec §8「为云同步预留」）：v1 只接受 `none`
    var secretKey = "none"
    var wrappedKey: Sealed
    var extras: [String: JSONValue] = [:]
}

extension AccountFile: Codable {
    private static let known: Set<String> = ["format", "version", "accountId", "kdf", "secretKey", "wrappedKey"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        format = try c.decode(String.self, forKey: AnyKey("format"))
        version = try c.decode(Int.self, forKey: AnyKey("version"))
        guard format == Self.formatName else { throw VaultError.invalidFormat("不是 1Melon 账户文件") }
        guard version <= Self.currentVersion else { throw VaultError.unsupportedVersion(version) }
        guard version == Self.currentVersion else { throw VaultError.invalidFormat("格式版本 \(version) 无效") }
        accountId = try c.decode(String.self, forKey: AnyKey("accountId"))
        kdf = try c.decode(KDFParameters.self, forKey: AnyKey("kdf"))
        secretKey = try c.decode(String.self, forKey: AnyKey("secretKey"))
        wrappedKey = try c.decode(Sealed.self, forKey: AnyKey("wrappedKey"))
        extras = try c.extras(excluding: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extras)
        try c.encode(format, forKey: AnyKey("format"))
        try c.encode(version, forKey: AnyKey("version"))
        try c.encode(accountId, forKey: AnyKey("accountId"))
        try c.encode(kdf, forKey: AnyKey("kdf"))
        try c.encode(secretKey, forKey: AnyKey("secretKey"))
        try c.encode(wrappedKey, forKey: AnyKey("wrappedKey"))
    }
}

/// 解锁后的账户。只有它知道账户密钥 AK；保险库都靠它打开。
public struct UnlockedAccount: Sendable {
    public let accountId: String
    public private(set) var kdf: KDFParameters
    private var keyBox: SendableKey
    private var wrappedKey: Sealed
    private var fileExtras: [String: JSONValue]

    var accountKey: SymmetricKey { keyBox.key }

    /// 新建账户：随机生成 AK，用主密码派生的 KEK 包装。
    public static func create(password: String, kdf: KDFParameters = .defaults()) throws -> UnlockedAccount {
        let accountId = newID()
        let ak = SymmetricKey(size: .bits256)
        let kek = try deriveKEK(password: password, kdf: kdf)
        let wrapped = try seal(ak.withUnsafeBytes { Data($0) }, key: kek, aad: AAD.account(accountId))
        return UnlockedAccount(accountId: accountId, kdf: kdf, keyBox: SendableKey(ak), wrappedKey: wrapped, fileExtras: [:])
    }

    /// 用主密码打开。主密码错误抛 `.wrongPassword`。
    public static func open(_ data: Data, password: String) throws -> UnlockedAccount {
        let file = try decodeFile(data)
        return try open(file, kek: try deriveKEK(password: password, kdf: file.kdf))
    }

    /// 用已经派生好的 KEK 打开（测试里避免重复跑 KDF）
    static func open(_ data: Data, kek: SymmetricKey) throws -> UnlockedAccount {
        try open(try decodeFile(data), kek: kek)
    }

    /// 用账户密钥直接打开（本地快速解锁：AK 存在钥匙串里，由 Touch ID 保护）。
    public static func open(_ data: Data, accountKey: SymmetricKey) throws -> UnlockedAccount {
        let file = try decodeFile(data)
        return UnlockedAccount(accountId: file.accountId, kdf: file.kdf, keyBox: SendableKey(accountKey),
                               wrappedKey: file.wrappedKey, fileExtras: file.extras)
    }

    /// 本地快速解锁要存进钥匙串的账户密钥。只能交给平台安全存储，不能落盘或写日志。
    public var accountKeyForLocalUnlock: SymmetricKey { accountKey }

    /// 改主密码：新 salt、新 KEK、重新包装 AK。保险库文件一个都不用动。
    public mutating func changePassword(to password: String, kdf: KDFParameters = .defaults()) throws {
        let kek = try Self.deriveKEK(password: password, kdf: kdf)
        wrappedKey = try seal(accountKey.withUnsafeBytes { Data($0) }, key: kek, aad: AAD.account(accountId))
        self.kdf = kdf
    }

    public func serialized() throws -> Data {
        let file = AccountFile(accountId: accountId, kdf: kdf, wrappedKey: wrappedKey, extras: fileExtras)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(file)
    }

    /// 主密码 → KEK（spec §2）：先做 Unicode NFC 规范化，再按 UTF-8 编码进 Argon2id，输出 32 字节。
    static func deriveKEK(password: String, kdf: KDFParameters) throws -> SymmetricKey {
        try kdf.validate()
        let normalized = password.precomposedStringWithCanonicalMapping
        var bytes = try Argon2id.hash(
            password: Array(normalized.utf8), salt: Array(kdf.salt),
            memoryKiB: kdf.memKiB, iterations: kdf.iterations, parallelism: kdf.parallelism, length: 32
        )
        defer { for i in bytes.indices { bytes[i] = 0 } }
        return SymmetricKey(data: bytes)
    }

    static func decodeFile(_ data: Data) throws -> AccountFile {
        let file: AccountFile
        do {
            file = try JSONDecoder().decode(AccountFile.self, from: data)
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.invalidFormat("账户文件结构无法解析")
        }
        guard isLowercaseUUID(file.accountId) else { throw VaultError.invalidFormat("accountId 不是小写 UUID") }
        guard file.secretKey == "none" else { throw VaultError.invalidFormat("这个账户需要 Secret Key，当前版本还不支持") }
        try file.kdf.validate()
        guard file.wrappedKey.ct.count == 32 + 16 else { throw VaultError.tampered("账户 wrappedKey 长度不对") }
        return file
    }

    private static func open(_ file: AccountFile, kek: SymmetricKey) throws -> UnlockedAccount {
        let akBytes: Data
        do {
            akBytes = try unseal(file.wrappedKey, key: kek, aad: AAD.account(file.accountId))
        } catch {
            throw VaultError.wrongPassword
        }
        return UnlockedAccount(accountId: file.accountId, kdf: file.kdf, keyBox: SendableKey(SymmetricKey(data: akBytes)),
                               wrappedKey: file.wrappedKey, fileExtras: file.extras)
    }
}

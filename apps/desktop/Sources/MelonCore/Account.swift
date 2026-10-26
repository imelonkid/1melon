import Crypto
import Foundation

/// 账户文件 `account.1melon`（spec §3.1）：主密码派生的 KEK 包装账户密钥 AK；AK 再包装各保险库的密钥。
/// v1 不带 Secret Key；v2 带（`secretKey: required` + `secretKeyId`），KEK 由 Argon2id 输出和 Secret Key 经 HKDF 得到。
struct AccountFile {
    static let formatName = "1melon-account"
    /// 能读写的最高版本
    static let currentVersion = 2

    var format = formatName
    var version: Int
    var accountId: String
    var kdf: KDFParameters
    var secretKey: String
    /// 只有 v2 有：用来在解开之前分辨「Secret Key 不对」和「主密码不对」
    var secretKeyId: Data?
    var wrappedKey: Sealed
    var extras: [String: JSONValue] = [:]

    var requiresSecretKey: Bool { version >= 2 }
    var aad: Data { requiresSecretKey ? AAD.accountV2(accountId) : AAD.account(accountId) }
}

extension AccountFile: Codable {
    private static let known: Set<String> = ["format", "version", "accountId", "kdf", "secretKey", "secretKeyId", "wrappedKey"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        format = try c.decode(String.self, forKey: AnyKey("format"))
        version = try c.decode(Int.self, forKey: AnyKey("version"))
        guard format == Self.formatName else { throw VaultError.invalidFormat("不是 1Melon 账户文件") }
        guard version <= Self.currentVersion else { throw VaultError.unsupportedVersion(version) }
        guard version >= 1 else { throw VaultError.invalidFormat("格式版本 \(version) 无效") }
        accountId = try c.decode(String.self, forKey: AnyKey("accountId"))
        kdf = try c.decode(KDFParameters.self, forKey: AnyKey("kdf"))
        secretKey = try c.decode(String.self, forKey: AnyKey("secretKey"))
        secretKeyId = try c.decodeIfPresent(Data.self, forKey: AnyKey("secretKeyId"))
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
        try c.encodeIfPresent(secretKeyId, forKey: AnyKey("secretKeyId"))
        try c.encode(wrappedKey, forKey: AnyKey("wrappedKey"))
    }
}

/// 解锁后的账户。只有它知道账户密钥 AK；保险库都靠它打开。
public struct UnlockedAccount: Sendable {
    public let accountId: String
    public private(set) var kdf: KDFParameters
    /// 带 Secret Key 的账户（文件 v2）才有。只在内存里；落盘只在设备目录（`device/secret-key.json`）
    public private(set) var secretKey: SecretKey?
    private var keyBox: SendableKey
    private var wrappedKey: Sealed
    private var fileExtras: [String: JSONValue]

    var accountKey: SymmetricKey { keyBox.key }

    /// 新建账户：随机生成 AK，用主密码（和 Secret Key）派生的 KEK 包装。
    public static func create(password: String, kdf: KDFParameters = .defaults(), secretKey: SecretKey? = nil) throws -> UnlockedAccount {
        var account = UnlockedAccount(accountId: newID(), kdf: kdf, secretKey: nil, keyBox: SendableKey(SymmetricKey(size: .bits256)),
                                      wrappedKey: Sealed(nonce: Data(), ct: Data()), fileExtras: [:])
        try account.rewrap(password: password, kdf: kdf, secretKey: secretKey)
        return account
    }

    /// 用主密码打开。账户带 Secret Key 时还要给 Secret Key。
    /// 错误：主密码错 `.wrongPassword`；缺 Secret Key `.secretKeyRequired`；Secret Key 错 `.wrongSecretKey`（不跑 KDF）。
    public static func open(_ data: Data, password: String, secretKey: SecretKey? = nil) throws -> UnlockedAccount {
        let file = try decodeFile(data)
        let sk = try checkSecretKey(file, secretKey)
        let kek = try deriveKEK(password: password, kdf: file.kdf, secretKey: sk, accountId: file.accountId)
        return try open(file, kek: kek, secretKey: sk)
    }

    /// 用已经派生好的 KEK 打开（测试里避免重复跑 KDF）
    static func open(_ data: Data, kek: SymmetricKey, secretKey: SecretKey? = nil) throws -> UnlockedAccount {
        let file = try decodeFile(data)
        return try open(file, kek: kek, secretKey: try checkSecretKey(file, secretKey))
    }

    /// 用账户密钥直接打开（本机快速解锁：AK 由 Touch ID 保护）。带 Secret Key 的账户把本机存的 Secret Key 一起带上，
    /// 改主密码时要用；本机没有也能打开，只是改主密码前要先补上。
    public static func open(_ data: Data, accountKey: SymmetricKey, secretKey: SecretKey? = nil) throws -> UnlockedAccount {
        let file = try decodeFile(data)
        let sk = file.requiresSecretKey ? (try? checkSecretKey(file, secretKey)) ?? nil : nil
        return UnlockedAccount(accountId: file.accountId, kdf: file.kdf, secretKey: sk, keyBox: SendableKey(accountKey),
                               wrappedKey: file.wrappedKey, fileExtras: file.extras)
    }

    /// 本地快速解锁要存进钥匙串的账户密钥。只能交给平台安全存储，不能落盘或写日志。
    public var accountKeyForLocalUnlock: SymmetricKey { accountKey }

    /// 改主密码：新 salt、新 KEK、重新包装 AK。保险库文件一个都不用动；Secret Key 不变。
    public mutating func changePassword(to password: String, kdf: KDFParameters = .defaults()) throws {
        try rewrap(password: password, kdf: kdf, secretKey: secretKey)
    }

    /// 启用（传新的 Secret Key）或停用（传 nil）Secret Key：要主密码，只重新包装 AK（spec §3.1）。
    /// 账户文件随之变成 v2 或 v1；调用方负责把 Secret Key 存进设备目录、写回账户文件。
    public mutating func setSecretKey(_ secretKey: SecretKey?, password: String) throws {
        try rewrap(password: password, kdf: kdf, secretKey: secretKey)
    }

    private mutating func rewrap(password: String, kdf: KDFParameters, secretKey: SecretKey?) throws {
        let kek = try Self.deriveKEK(password: password, kdf: kdf, secretKey: secretKey, accountId: accountId)
        let aad = secretKey == nil ? AAD.account(accountId) : AAD.accountV2(accountId)
        wrappedKey = try seal(accountKey.withUnsafeBytes { Data($0) }, key: kek, aad: aad)
        self.kdf = kdf
        self.secretKey = secretKey
    }

    public func serialized() throws -> Data {
        let file = AccountFile(version: secretKey == nil ? 1 : 2, accountId: accountId, kdf: kdf,
                               secretKey: secretKey == nil ? "none" : "required",
                               secretKeyId: secretKey?.id(accountId: accountId), wrappedKey: wrappedKey, extras: fileExtras)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(file)
    }

    /// 带 Secret Key 时的 KEK（spec §2）：Argon2id 输出再和 Secret Key 一起过 HKDF
    static func deriveKEK(password: String, kdf: KDFParameters, secretKey: SecretKey?, accountId: String) throws -> SymmetricKey {
        let argon = try deriveKEK(password: password, kdf: kdf)
        guard let secretKey else { return argon }
        return secretKey.deriveKEK(argon2Output: argon, accountId: accountId)
    }

    /// v2 账户：要有 Secret Key，并且和 secretKeyId 对得上；v1 账户：不需要，给了也不用
    private static func checkSecretKey(_ file: AccountFile, _ secretKey: SecretKey?) throws -> SecretKey? {
        guard file.requiresSecretKey else { return nil }
        guard let secretKey else { throw VaultError.secretKeyRequired }
        guard secretKey.id(accountId: file.accountId) == file.secretKeyId else { throw VaultError.wrongSecretKey }
        return secretKey
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
        if file.requiresSecretKey {
            guard file.secretKey == "required", file.secretKeyId?.count == 8 else {
                throw VaultError.invalidFormat("v2 账户文件的 Secret Key 字段不对")
            }
        } else {
            guard file.secretKey == "none", file.secretKeyId == nil else {
                throw VaultError.invalidFormat("v1 账户文件不能要求 Secret Key")
            }
        }
        try file.kdf.validate()
        guard file.wrappedKey.ct.count == 32 + 16 else { throw VaultError.tampered("账户 wrappedKey 长度不对") }
        return file
    }

    private static func open(_ file: AccountFile, kek: SymmetricKey, secretKey: SecretKey?) throws -> UnlockedAccount {
        let akBytes: Data
        do {
            akBytes = try unseal(file.wrappedKey, key: kek, aad: file.aad)
        } catch {
            throw VaultError.wrongPassword
        }
        return UnlockedAccount(accountId: file.accountId, kdf: file.kdf, secretKey: secretKey,
                               keyBox: SendableKey(SymmetricKey(data: akBytes)), wrappedKey: file.wrappedKey, fileExtras: file.extras)
    }
}

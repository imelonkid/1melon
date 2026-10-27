import Crypto
import Foundation

/// Secret Key（spec §3.4）：每个账户一把 128 位随机密钥，**只存在设备上**，和主密码一起才能派生 KEK。
/// 云端只有密文时，没有它就没法离线暴力破解主密码。
///
/// 给人看的写法：`M1-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX`（Crockford Base32，26 个数据字符 + 2 个校验字符）。
public struct SecretKey: Sendable, Equatable {
    public static let byteCount = 16
    public static let textPrefix = "M1"
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public enum ParseError: Error, Equatable {
        /// 字符数不对、有不认识的字符，或者校验对不上（多半是抄错了）
        case invalid
    }

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw ParseError.invalid }
        self.bytes = bytes
    }

    public static func generate() -> SecretKey {
        // 长度固定是 16 字节，不会失败
        try! SecretKey(bytes: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
    }

    // MARK: 写法

    public var text: String {
        let body = Self.encode(bits: [false, false] + Self.bits(bytes)) + Self.checksum(bytes)
        let groups = stride(from: 0, to: body.count, by: 7).map { i in
            String(body[body.index(body.startIndex, offsetBy: i)..<body.index(body.startIndex, offsetBy: min(i + 7, body.count))])
        }
        return ([Self.textPrefix] + groups).joined(separator: "-")
    }

    /// 解析：忽略大小写、连字符、空白；`M1` 前缀可省略；O 当 0，I、L 当 1。
    public init(text: String) throws {
        var s = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        if s.count == 30, s.hasPrefix(Self.textPrefix) { s.removeFirst(2) }
        guard s.count == 28 else { throw ParseError.invalid }
        let normalized = s.map { c -> Character in
            switch c {
            case "O": "0"
            case "I", "L": "1"
            default: c
            }
        }
        var values: [Int] = []
        for c in normalized {
            guard let v = Self.alphabet.firstIndex(of: c) else { throw ParseError.invalid }
            values.append(v)
        }
        guard values[0] < 8 else { throw ParseError.invalid } // 前 2 个比特是补的 0
        var bits: [Bool] = []
        for v in values.prefix(26) { for shift in (0..<5).reversed() { bits.append((v >> shift) & 1 == 1) } }
        let data = Self.bytes(Array(bits.dropFirst(2)))
        guard String(normalized.suffix(2)) == Self.checksum(data) else { throw ParseError.invalid }
        try self.init(bytes: data)
    }

    // MARK: 派生

    /// 账户文件 v2 的 `secretKeyId`：HMAC-SHA256(Secret Key, "1melon:v2:secret-key-id:<accountId>") 的前 8 字节
    func id(accountId: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("1melon:v2:secret-key-id:\(accountId)".utf8),
                                                  using: SymmetricKey(data: bytes))
        return Data(mac).prefix(8)
    }

    /// KEK（v2）= HKDF-SHA256(IKM = Argon2id 输出, salt = Secret Key, info = "1melon:v2:kek:<accountId>", 32 字节)
    func deriveKEK(argon2Output: SymmetricKey, accountId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: argon2Output, salt: bytes,
                               info: Data("1melon:v2:kek:\(accountId)".utf8), outputByteCount: 32)
    }

    // MARK: 比特工具

    static func bits(_ data: Data) -> [Bool] {
        data.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 == 1 } }
    }

    static func bytes(_ bits: [Bool]) -> Data {
        Data(stride(from: 0, to: bits.count, by: 8).map { i in
            bits[i..<i + 8].reduce(UInt8(0)) { ($0 << 1) | ($1 ? 1 : 0) }
        })
    }

    static func encode(bits: [Bool]) -> String {
        String(stride(from: 0, to: bits.count, by: 5).map { i in
            alphabet[bits[i..<i + 5].reduce(0) { ($0 << 1) | ($1 ? 1 : 0) }]
        })
    }

    /// 校验：SHA-256(16 字节) 的前 10 个比特，两个字符
    static func checksum(_ data: Data) -> String {
        encode(bits: Array(bits(Data(SHA256.hash(data: data))).prefix(10)))
    }
}

/// 设备上的 Secret Key 文件 `device/secret-key.json`（spec §3.4）：只属于这台设备，权限 0600，不同步、不备份。
struct SecretKeyFile: Codable, Equatable {
    static let formatName = "1melon-device-secret-key"
    var format = formatName
    var version = 1
    var accountId: String
    var secretKey: String
}

public extension AccountRepository {
    var secretKeyURL: URL { deviceDirectory.appendingPathComponent("secret-key.json") }

    /// 这台设备上存的、属于这个账户的 Secret Key。没有或格式不对返回 nil
    func readSecretKey(accountId: String? = nil) -> SecretKey? {
        guard let data = try? VaultStore.read(secretKeyURL),
              let file = try? JSONDecoder().decode(SecretKeyFile.self, from: data),
              file.format == SecretKeyFile.formatName, file.version == 1,
              accountId == nil || file.accountId == accountId else { return nil }
        return try? SecretKey(text: file.secretKey)
    }

    func writeSecretKey(_ secretKey: SecretKey, accountId: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try VaultStore.write(try encoder.encode(SecretKeyFile(accountId: accountId, secretKey: secretKey.text)), to: secretKeyURL)
    }

    func removeSecretKey() {
        try? FileManager.default.removeItem(at: secretKeyURL)
    }

    /// 账户文件是否要求 Secret Key（解锁页据此决定要不要显示 Secret Key 输入框）
    var accountRequiresSecretKey: Bool {
        guard let data = try? VaultStore.read(accountURL), let file = try? UnlockedAccount.decodeFile(data) else { return false }
        return file.requiresSecretKey
    }
}

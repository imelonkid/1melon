import Foundation

/// 设置码（sync-api §7）：新设备加入账户用的一段文字，里面有服务端地址、`accountId` 和 Secret Key。
/// **和主密码一样要保密**：只在界面上显示、复制或打印，不写日志、不落盘。
public struct SetupCode: Sendable, Equatable {
    public static let prefix = "1MELON-SETUP1:"

    /// 服务端根地址，结尾不带 `/`
    public var server: String
    public var accountId: String
    public var secretKey: SecretKey

    public enum ParseError: Error, Equatable {
        /// 前缀、Base64url 或 JSON 不对：多半是没复制完整
        case malformed
        /// 地址不是 https，或者带了用户名、查询、片段
        case invalidServer
        case invalidAccountId
        /// Secret Key 的校验字符对不上：多半是抄错了
        case invalidSecretKey
    }

    public init(server: String, accountId: String, secretKey: SecretKey) {
        var s = server
        while s.hasSuffix("/") { s.removeLast() }
        self.server = s
        self.accountId = accountId
        self.secretKey = secretKey
    }

    public var serverURL: URL? { URL(string: server) }

    /// 生成：键排好序、不带空白、`/` 不转义，Base64url 不带填充。各端生成的字节相同
    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(["accountId": accountId, "secretKey": secretKey.text, "server": server])) ?? Data()
        let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return Self.prefix + b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// 解析：去掉所有空白换行；前缀一模一样；Base64url 带不带填充都行；不认识的键忽略；有一项不对就整体拒绝
    public init(text: String) throws {
        let s = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard s.hasPrefix(Self.prefix) else { throw ParseError.malformed }
        let payload = s.dropFirst(Self.prefix.count)
        var body = String(payload)
        while body.hasSuffix("=") { body.removeLast() }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !body.isEmpty, payload.count - body.count <= 2, body.allSatisfy(allowed.contains) else { throw ParseError.malformed }
        var b64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = obj["server"] as? String, let accountId = obj["accountId"] as? String,
              let secretKey = obj["secretKey"] as? String
        else { throw ParseError.malformed }

        guard !server.contains("?"), !server.contains("#"), let url = URL(string: server), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { throw ParseError.invalidServer }
        guard let uuid = UUID(uuidString: accountId), uuid.uuidString.lowercased() == accountId else { throw ParseError.invalidAccountId }
        guard let sk = try? SecretKey(text: secretKey) else { throw ParseError.invalidSecretKey }
        self.init(server: server, accountId: accountId, secretKey: sk)
    }
}

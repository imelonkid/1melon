import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 和 1Melon 服务端打交道的 HTTP 层（spec/sync-api.md §2–§5）。
// 只发三类东西：登录签名、加密后的文件、注册时的账户文件（也是加密的）。主密码、Secret Key、明文都不出本机。

// MARK: HTTP

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String] = [:]
    public var body: Data?
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// 键一律小写
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }
}

/// 测试里换成假的；正式用 `URLSessionHTTPClient`
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// 不带 cookie、不用缓存、不存凭据、不跟随重定向（同步地址只信设置码里的那一个）
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 4
        config.httpAdditionalHeaders = ["User-Agent": "1Melon"]
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body
        return try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: req) { data, response, error in
                if let error { return cont.resume(throwing: error) }
                guard let http = response as? HTTPURLResponse else { return cont.resume(throwing: SyncAPIError.invalidResponse) }
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
                }
                cont.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }.resume()
        }
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

// MARK: 错误

/// 服务端返回的错误（sync-api §2 的错误表）和本机能判断出的问题。
/// 412 和 404 在文件接口上以 `SyncTransportError` 抛出，同步引擎按它处理。
public enum SyncAPIError: Error, Equatable, Sendable {
    /// 服务端地址不是 https（只有本机回环地址允许 http，开发和测试用）
    case insecureServer
    /// 401：主密码或 Secret Key 不对、账户不存在、登录过期
    case unauthorized
    /// 403：账户或设备被停用，或邀请码无效、用过、过期
    case forbidden
    /// 409：账户已经注册过
    case exists
    /// 413：文件太大或超过配额
    case tooLarge
    /// 429
    case rateLimited(retryAfter: Int?)
    /// 400：多半是客户端的 bug
    case badRequest(String?)
    /// 5xx 或其他意外的状态码：稍后重试
    case server(status: Int, traceId: String?)
    /// 响应格式不对，或者内容和响应头里的哈希对不上
    case invalidResponse
}

// MARK: 不用登录的接口

/// 不用登录的接口：登录挑战、注册
public enum SyncAPI {
    public static let platform = "macos"

    /// 服务端根地址（如 `https://1melon.melonkid.cn`）→ API 基础地址 `…/api/v1`。
    /// 只认 https；本机回环地址（127.0.0.1、localhost、::1）允许 http，开发和测试用
    /// https 都行；http 只给本机回环地址（127.0.0.1、localhost、::1）。设置码解析也用它（sync-api §2、§7）
    static func isAllowedScheme(_ scheme: String, host: String) -> Bool {
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
        return scheme.lowercased() == "https" || (scheme.lowercased() == "http" && loopback)
    }

    public static func baseURL(server: URL) throws -> URL {
        guard let scheme = server.scheme?.lowercased(), let host = server.host?.lowercased(), !host.isEmpty,
              server.query == nil, server.fragment == nil, server.user == nil
        else { throw SyncAPIError.insecureServer }
        guard isAllowedScheme(scheme, host: host) else { throw SyncAPIError.insecureServer }
        var s = server.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s + "/api/v1") else { throw SyncAPIError.insecureServer }
        return url
    }

    public struct Challenge: Sendable {
        public var challenge: String
        public var expiresAt: Int64
        /// 账户文件里的 KDF 参数；账户不存在时是服务端给的假参数（照样能算，只是登录不上）
        public var kdf: KDFParameters
    }

    /// `POST /auth/challenge`（sync-api §3.2）
    public static func challenge(server: URL, accountId: String, http: HTTPClient) async throws -> Challenge {
        struct Body: Decodable { var challenge: String; var expiresAt: Int64; var kdf: KDFParameters }
        let res = try await send(http, "POST", try baseURL(server: server).appendingPathComponent("auth/challenge"),
                                 json: json(["accountId": accountId]))
        let b: Body = try decode(res)
        try b.kdf.validate()
        return Challenge(challenge: b.challenge, expiresAt: b.expiresAt, kdf: b.kdf)
    }

    /// `POST /accounts`（sync-api §4.1）：凭邀请码注册，账户文件成为这个账户的第一个文件（rev 1）
    public static func register(server: URL, inviteCode: String, accountId: String, authPublicKey: Data, accountFile: Data,
                                http: HTTPClient) async throws {
        _ = try await send(http, "POST", try baseURL(server: server).appendingPathComponent("accounts"), json: json([
            "inviteCode": inviteCode, "accountId": accountId,
            "authPublicKey": authPublicKey.base64EncodedString(), "account": accountFile.base64EncodedString(),
        ]))
    }

    // MARK: 公用

    static func send(_ http: HTTPClient, _ method: String, _ url: URL, headers: [String: String] = [:],
                     json: Data? = nil, body: Data? = nil) async throws -> HTTPResponse {
        var req = HTTPRequest(method: method, url: url, headers: headers)
        req.headers["X-Request-Id"] = UUID().uuidString.lowercased()
        req.headers["Accept"] = "application/json"
        if let json {
            req.headers["Content-Type"] = "application/json"
            req.body = json
        } else if let body {
            req.headers["Content-Type"] = "application/octet-stream"
            req.body = body
        }
        let res = try await http.send(req)
        guard (200..<300).contains(res.status) else { throw error(for: res) }
        return res
    }

    /// 把错误响应翻译成 `SyncAPIError`；412、404 由文件接口另行处理
    static func error(for res: HTTPResponse) -> Error {
        struct Body: Decodable {
            struct E: Decodable { var code: String?; var message: String? }
            var error: E?
            var rev: Int?
            var traceId: String?
        }
        let b = try? JSONDecoder().decode(Body.self, from: res.body)
        switch res.status {
        case 400: return SyncAPIError.badRequest(b?.error?.message)
        case 401: return SyncAPIError.unauthorized
        case 403: return SyncAPIError.forbidden
        case 404: return SyncTransportError.notFound
        case 409: return SyncAPIError.exists
        case 412: return SyncTransportError.conflict(rev: b?.rev)
        case 413: return SyncAPIError.tooLarge
        case 429: return SyncAPIError.rateLimited(retryAfter: res.headers["retry-after"].flatMap { Int($0) })
        default: return SyncAPIError.server(status: res.status, traceId: b?.traceId)
        }
    }

    static func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ res: HTTPResponse) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: res.body) } catch { throw SyncAPIError.invalidResponse }
    }
}

// MARK: 登录后的接口

/// 一台设备和服务端的连接：自己登录（挑战签名 → 会话令牌，过期或 401 时重新登录一次），按 sync-api §5 收发文件。
/// 只在内存里持有登录密钥和会话令牌，不落盘。
public actor SyncClient: SyncTransport {
    public nonisolated let server: URL
    public nonisolated let accountId: String
    public nonisolated let deviceId: String
    let base: URL
    let deviceName: String
    let loginKey: LoginKey
    let http: HTTPClient
    let clock: @Sendable () -> Int64

    private var token: String?
    private var tokenExpiresAt: Int64 = 0

    public init(server: URL, accountId: String, deviceId: String, deviceName: String, loginKey: LoginKey,
                http: HTTPClient = URLSessionHTTPClient(),
                clock: @escaping @Sendable () -> Int64 = { Date().unixMilliseconds }) throws {
        self.server = server
        self.base = try SyncAPI.baseURL(server: server)
        self.accountId = accountId
        self.deviceId = deviceId
        self.deviceName = String(deviceName.prefix(100))
        self.loginKey = loginKey
        self.http = http
        self.clock = clock
    }

    /// 用同步状态里的服务端、账户和设备 id
    public init(state: SyncState, deviceName: String, loginKey: LoginKey, http: HTTPClient = URLSessionHTTPClient()) throws {
        guard let url = URL(string: state.server) else { throw SyncAPIError.insecureServer }
        try self.init(server: url, accountId: state.accountId, deviceId: state.deviceId, deviceName: deviceName,
                      loginKey: loginKey, http: http)
    }

    /// 挑战签名换会话令牌（sync-api §3.2）。401 = 主密码或 Secret Key 不对，或者账户不存在（服务端不区分）
    public func login() async throws {
        let c = try await SyncAPI.challenge(server: server, accountId: accountId, http: http)
        let signature = try loginKey.signLogin(accountId: accountId, challenge: c.challenge)
        struct Device: Encodable { var id, name, platform: String }
        struct Request: Encodable { var accountId, challenge, signature: String; var device: Device }
        struct Body: Decodable { var token: String; var expiresAt: Int64 }
        let req = Request(accountId: accountId, challenge: c.challenge, signature: signature.base64EncodedString(),
                          device: Device(id: deviceId, name: deviceName.isEmpty ? "Mac" : deviceName, platform: SyncAPI.platform))
        let res = try await SyncAPI.send(http, "POST", base.appendingPathComponent("auth/session"), json: try SyncAPI.json(req))
        let b: Body = try SyncAPI.decode(res)
        token = b.token
        tokenExpiresAt = b.expiresAt
    }

    /// 带会话令牌发请求：快过期就先重新登录；拿旧令牌碰到 401（被服务端提前作废）重新登录再试一次
    private func authed(_ method: String, _ path: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
                        body: Data? = nil) async throws -> HTTPResponse {
        var fresh = false
        if token == nil || clock() > tokenExpiresAt - 60_000 {
            try await login()
            fresh = true
        }
        var url = base.appendingPathComponent(path)
        if !query.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.queryItems = query
            url = c.url ?? url
        }
        while true {
            var h = headers
            h["Authorization"] = "Bearer \(token ?? "")"
            do {
                return try await SyncAPI.send(http, method, url, headers: h, body: body ?? (method == "PUT" ? Data() : nil))
            } catch SyncAPIError.unauthorized where !fresh {
                token = nil
                try await login()
                fresh = true
            }
        }
    }

    /// 文件名只允许 `account.1melon` 和 `vaults/<小写 UUID>.1melon`（sync-api §5），拼路径前先查
    static func checkName(_ name: String) throws -> String {
        guard name == SyncEngine.accountFile || SyncEngine.vaultId(name) != nil else { throw SyncAPIError.badRequest("文件名不对") }
        return "files/" + name
    }

    // MARK: SyncTransport

    public func listFiles(since cursor: String?) async throws -> (files: [RemoteFile], cursor: String) {
        struct Body: Decodable {
            struct F: Decodable { var name: String; var rev: Int; var sha256: String; var deleted: Bool? }
            var files: [F]
            var cursor: String
        }
        let res = try await authed("GET", "files", query: cursor.map { [URLQueryItem(name: "since", value: $0)] } ?? [])
        let b: Body = try SyncAPI.decode(res)
        return (b.files.map { RemoteFile(name: $0.name, rev: $0.rev, sha256: $0.sha256, deleted: $0.deleted ?? false) }, b.cursor)
    }

    public func download(_ name: String) async throws -> (data: Data, rev: Int) {
        let res = try await authed("GET", try Self.checkName(name))
        guard let etag = res.headers["etag"], let rev = Int(etag.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))),
              let sha = res.headers["x-content-sha256"], sha.lowercased() == SyncEngine.sha256(res.body)
        else { throw SyncAPIError.invalidResponse }
        return (res.body, rev)
    }

    public func upload(_ name: String, data: Data, baseRev: Int?, proof: AccountUploadProof?) async throws -> Int {
        var headers: [String: String] = [:]
        if let baseRev { headers["If-Match"] = "\"\(baseRev)\"" } else { headers["If-None-Match"] = "*" }
        if let proof {
            headers["X-Auth-Public-Key"] = proof.publicKey.base64EncodedString()
            headers["X-Auth-Proof"] = proof.proof.base64EncodedString()
        }
        struct Body: Decodable { var rev: Int; var sha256: String }
        let res = try await authed("PUT", try Self.checkName(name), headers: headers, body: data)
        let b: Body = try SyncAPI.decode(res)
        guard b.sha256.lowercased() == SyncEngine.sha256(data) else { throw SyncAPIError.invalidResponse }
        return b.rev
    }

    public func delete(_ name: String, baseRev: Int) async throws -> Int {
        struct Body: Decodable { var rev: Int }
        let res = try await authed("DELETE", try Self.checkName(name), headers: ["If-Match": "\"\(baseRev)\""])
        let b: Body = try SyncAPI.decode(res)
        return b.rev
    }
}

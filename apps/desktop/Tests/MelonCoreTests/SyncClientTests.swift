import Crypto
import Foundation
import XCTest
@testable import MelonCore

// MARK: 假的 HTTP：按请求现编响应，记下发过的请求

actor ScriptedHTTP: HTTPClient {
    typealias Handler = @Sendable (HTTPRequest, Int) -> HTTPResponse
    private let handler: Handler
    private(set) var requests: [HTTPRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return handler(request, requests.filter { $0.url.path == request.url.path && $0.method == request.method }.count)
    }

    func paths() -> [String] { requests.map { "\($0.method) \($0.url.path)" } }
}

private let fakeServer = URL(string: "https://sync.example.test")!
private let fakeAccountId = "0d3a3c62-6a8e-4c39-9a4e-3a4d2b1f0c11"
private let fakeKey = LoginKey.derive(argon2Output: SymmetricKey(size: .bits256), secretKey: .generate(), accountId: fakeAccountId)

private func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: object))
}

/// 登录两步的标准应答；其余交给 `files`
private func loginThen(_ files: @escaping @Sendable (HTTPRequest, Int) -> HTTPResponse) -> ScriptedHTTP.Handler {
    { req, n in
        switch req.url.path {
        case "/api/v1/auth/challenge":
            return json(200, ["challenge": "Y2hhbGxlbmdlLTEyMw==", "expiresAt": 1_761_400_120_000, "kdf": [
                "alg": "argon2id13", "memKiB": 65536, "iterations": 2, "parallelism": 1, "salt": Data(count: 16).base64EncodedString(),
            ]])
        case "/api/v1/auth/session":
            return json(200, ["token": "token-\(n)", "expiresAt": Int64.max / 2, "deviceId": "x"])
        default:
            return files(req, n)
        }
    }
}

private func client(_ http: ScriptedHTTP) throws -> SyncClient {
    try SyncClient(server: fakeServer, accountId: fakeAccountId, deviceId: "5b6f7c1e-2d3a-4b5c-8d9e-0f1a2b3c4d5e",
                   deviceName: "测试用的 Mac", loginKey: fakeKey, http: http, clock: { 1_761_400_000_000 })
}

final class SyncClientTests: XCTestCase {
    func testBaseURLOnlyHTTPS() throws {
        XCTAssertEqual(try SyncAPI.baseURL(server: URL(string: "https://sync.example.test/")!).absoluteString, "https://sync.example.test/api/v1")
        XCTAssertEqual(try SyncAPI.baseURL(server: URL(string: "http://127.0.0.1:8790")!).absoluteString, "http://127.0.0.1:8790/api/v1")
        for bad in ["http://sync.example.test", "ftp://sync.example.test", "https://user@sync.example.test", "https://sync.example.test/?a=1"] {
            XCTAssertThrowsError(try SyncAPI.baseURL(server: URL(string: bad)!), bad) { XCTAssertEqual($0 as? SyncAPIError, .insecureServer) }
        }
    }

    func testLoginSignsChallengeAndSendsBearer() async throws {
        let http = ScriptedHTTP(loginThen { req, _ in
            json(200, ["files": [["name": "account.1melon", "rev": 2, "sha256": "ab", "size": 10, "updatedAt": 1, "deleted": false]], "cursor": "7"])
        })
        let (files, cursor) = try await client(http).listFiles(since: "3")
        XCTAssertEqual(files, [RemoteFile(name: "account.1melon", rev: 2, sha256: "ab")])
        XCTAssertEqual(cursor, "7")

        let reqs = await http.requests
        XCTAssertEqual(reqs.map(\.method), ["POST", "POST", "GET"])
        // 会话请求：签名能用登录公钥验过，设备信息带上
        let body = try JSONSerialization.jsonObject(with: reqs[1].body!) as! [String: Any]
        let sig = Data(base64Encoded: body["signature"] as! String)!
        XCTAssertTrue(LoginKey.verify(publicKey: fakeKey.publicKey,
                                      message: LoginKey.loginMessage(accountId: fakeAccountId, challenge: "Y2hhbGxlbmdlLTEyMw=="),
                                      signature: sig))
        XCTAssertEqual((body["device"] as! [String: String])["platform"], "macos")
        // 文件列表：带令牌和游标；每个请求一个不同的追踪号
        XCTAssertEqual(reqs[2].headers["Authorization"], "Bearer token-1")
        XCTAssertEqual(reqs[2].url.query, "since=3")
        XCTAssertEqual(Set(reqs.compactMap { $0.headers["X-Request-Id"] }).count, 3)
        XCTAssertNil(reqs.first { $0.url.path.contains("auth") && $0.headers["Authorization"] != nil })
    }

    func testRelogsInOnceWhenTokenRejected() async throws {
        let http = ScriptedHTTP(loginThen { _, n in
            n == 2 ? json(401, ["error": ["code": "unauthorized"]]) : json(200, ["files": [], "cursor": "0"])
        })
        let c = try client(http)
        _ = try await c.listFiles(since: nil)   // 第一次：登录 + 列表
        _ = try await c.listFiles(since: nil)   // 第二次：令牌被拒（401）→ 重新登录 → 成功
        let paths = await http.paths()
        XCTAssertEqual(paths.filter { $0.hasSuffix("auth/session") }.count, 2)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/files") }.count, 3)

        // 刚登录完就 401（签名不对、账户不存在）：不再重试，直接报错
        let denied = ScriptedHTTP { req, _ in
            req.url.path.hasSuffix("challenge") ? loginThen { _, _ in json(500, [:]) }(req, 1) : json(401, ["error": ["code": "unauthorized"]])
        }
        do { _ = try await client(denied).listFiles(since: nil); XCTFail() } catch { XCTAssertEqual(error as? SyncAPIError, .unauthorized) }
        let deniedPaths = await denied.paths()
        XCTAssertEqual(deniedPaths.count, 2)
    }

    func testUploadPreconditionsAndConflict() async throws {
        let data = Data("{}".utf8)
        let http = ScriptedHTTP(loginThen { req, n in
            n == 1 ? json(200, ["rev": 4, "sha256": SyncEngine.sha256(data)]) : json(412, ["error": ["code": "conflict"], "rev": 9])
        })
        let c = try client(http)
        let name = "vaults/9a4e3a4d-2b1f-4c11-8d3a-3c626a8e4c39.1melon"
        let rev = try await c.upload(name, data: data, baseRev: 3, proof: nil)
        XCTAssertEqual(rev, 4)
        do { _ = try await c.upload(name, data: data, baseRev: nil, proof: nil); XCTFail() } catch {
            XCTAssertEqual(error as? SyncTransportError, .conflict(rev: 9))
        }
        let puts = await http.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(puts[0].url.path, "/api/v1/files/" + name)
        XCTAssertEqual(puts[0].headers["If-Match"], "\"3\"")
        XCTAssertNil(puts[0].headers["If-None-Match"])
        XCTAssertEqual(puts[1].headers["If-None-Match"], "*")
        XCTAssertEqual(puts[0].headers["Content-Type"], "application/octet-stream")
        XCTAssertEqual(puts[0].body, data)
    }

    func testAccountUploadCarriesProof() async throws {
        let data = Data("account".utf8)
        let http = ScriptedHTTP(loginThen { _, _ in json(200, ["rev": 2, "sha256": SyncEngine.sha256(data)]) })
        let proof = AccountUploadProof(publicKey: fakeKey.publicKey, proof: try fakeKey.signRotate(accountId: fakeAccountId, accountFile: data))
        _ = try await client(http).upload("account.1melon", data: data, baseRev: 1, proof: proof)
        let put = await http.requests.last!
        XCTAssertEqual(put.headers["X-Auth-Public-Key"], fakeKey.publicKey.base64EncodedString())
        XCTAssertEqual(put.headers["X-Auth-Proof"], proof.proof.base64EncodedString())
    }

    func testDownloadVerifiesHashAndMapsErrors() async throws {
        let body = Data("cipher".utf8)
        let http = ScriptedHTTP(loginThen { req, _ in
            switch req.url.lastPathComponent {
            case "account.1melon": return HTTPResponse(status: 200, headers: ["ETag": "\"5\"", "X-Content-SHA256": SyncEngine.sha256(body)], body: body)
            case "9a4e3a4d-2b1f-4c11-8d3a-3c626a8e4c39.1melon":
                return HTTPResponse(status: 200, headers: ["ETag": "\"5\"", "X-Content-SHA256": SyncEngine.sha256(Data("别的".utf8))], body: body)
            default: return json(404, ["error": ["code": "not_found"]])
            }
        })
        let c = try client(http)
        let (data, rev) = try await c.download("account.1melon")
        XCTAssertEqual(data, body)
        XCTAssertEqual(rev, 5)
        do { _ = try await c.download("vaults/9a4e3a4d-2b1f-4c11-8d3a-3c626a8e4c39.1melon"); XCTFail() } catch {
            XCTAssertEqual(error as? SyncAPIError, .invalidResponse)
        }
        do { _ = try await c.download("vaults/00000000-0000-4000-8000-000000000000.1melon"); XCTFail() } catch {
            XCTAssertEqual(error as? SyncTransportError, .notFound)
        }
        // 不合规的文件名根本不发出去
        do { _ = try await c.download("../account.1melon"); XCTFail() } catch { XCTAssertEqual(error as? SyncAPIError, .badRequest("文件名不对")) }
    }

    func testErrorMapping() {
        func map(_ status: Int, _ headers: [String: String] = [:]) -> Error {
            SyncAPI.error(for: json(status, ["error": ["code": "x", "message": "说明"], "traceId": "t-1"], headers: headers))
        }
        XCTAssertEqual(map(403) as? SyncAPIError, .forbidden)
        XCTAssertEqual(map(409) as? SyncAPIError, .exists)
        XCTAssertEqual(map(413) as? SyncAPIError, .tooLarge)
        XCTAssertEqual(map(429, ["Retry-After": "12"]) as? SyncAPIError, .rateLimited(retryAfter: 12))
        XCTAssertEqual(map(400) as? SyncAPIError, .badRequest("说明"))
        XCTAssertEqual(map(503) as? SyncAPIError, .server(status: 503, traceId: "t-1"))
    }

    func testRegisterNeedsSecretKey() async throws {
        let repo = AccountRepository(root: FileManager.default.temporaryDirectory.appendingPathComponent("1melon-reg-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.saveAccount(testAccount)   // v1，没有 Secret Key
        let http = ScriptedHTTP { _, _ in json(201, [:]) }
        do { try await SyncSetup.register(server: fakeServer, inviteCode: "x", repository: repo, loginKey: fakeKey, http: http); XCTFail() } catch {
            XCTAssertEqual(error as? SyncSetup.SetupError, .secretKeyRequired)
        }
        let sent = await http.requests
        XCTAssertTrue(sent.isEmpty)
    }
}

// MARK: 对真实服务端的端到端测试

/// 起一个真实的 Go 服务端进程（`MELON_TEST_SERVER_BIN` 指向编好的二进制；没设就跳过），
/// 走注册、登录、上传、新设备加入、并发修改合并、改主密码换登录密钥。
final class SyncServerE2ETests: XCTestCase {
    var process: Process?
    var dataDir: URL!
    var server: URL!
    var binary: URL!

    override func setUp() async throws {
        guard let bin = ProcessInfo.processInfo.environment["MELON_TEST_SERVER_BIN"], !bin.isEmpty else {
            throw XCTSkip("没设 MELON_TEST_SERVER_BIN，跳过对真实服务端的测试")
        }
        binary = URL(fileURLWithPath: bin)
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("1melon-e2e-\(UUID().uuidString)")
        let port = Int.random(in: 20000...40000)
        server = URL(string: "http://127.0.0.1:\(port)")!
        let p = Process()
        p.executableURL = binary
        p.environment = environment(port: port)
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        process = p
        let http = URLSessionHTTPClient(timeout: 1)
        for _ in 0..<100 {
            if let res = try? await http.send(HTTPRequest(method: "GET", url: server.appendingPathComponent("health"))), res.status == 200 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("服务端没起来")
    }

    override func tearDown() async throws {
        process?.terminate()
        process?.waitUntilExit()
        if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
    }

    func environment(port: Int) -> [String: String] {
        ["DATA_DIR": dataDir.path, "PORT": String(port), "APP_VERSION": "server-v0.0.0-test", "LOG_LEVEL": "error",
         "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin"]
    }

    /// `1melon-server invite create`：输出的第一行是邀请码
    func createInvite() throws -> String {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["invite", "create", "-note", "e2e"]
        p.environment = environment(port: 1)
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return String(text.split(separator: "\n").first ?? "")
    }

    func tempRepo() throws -> AccountRepository {
        let repo = AccountRepository(root: FileManager.default.temporaryDirectory.appendingPathComponent("1melon-e2e-dev-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: repo.vaultsDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo.root) }
        return repo
    }

    func titles(_ repo: AccountRepository, _ account: UnlockedAccount) -> Set<String> {
        Set(repo.loadVaults(account).vaults.flatMap { $0.activeItems.map(\.title) })
    }

    func testRegisterJoinMergeAndRotate() async throws {
        let password = "演示用主密码 e2e"
        let sk = SecretKey.generate()

        // 设备甲：本机已有账户（带 Secret Key）和一个保险库
        let repoA = try tempRepo()
        var account = try UnlockedAccount.create(password: password, kdf: testKDF, secretKey: sk)
        var vault = try UnlockedVault.create(in: account, meta: VaultMeta(name: "个人", created: t0))
        vault.save(sampleLogin(t0, title: "甲的第一条"), now: t0)
        try repoA.save(&vault, now: t0)
        try repoA.saveAccount(account)
        let (_, keyA) = try UnlockedAccount.openWithLoginKey(try VaultStore.read(repoA.accountURL), password: password, secretKey: sk)

        // 注册：同一个账户不能注册两次；邀请码只能用一次
        let invite = try createInvite()
        var stateA = try await SyncSetup.register(server: server, inviteCode: invite, repository: repoA, loginKey: keyA)
        do {
            try await SyncAPI.register(server: server, inviteCode: try createInvite(), accountId: account.accountId,
                                       authPublicKey: keyA.publicKey, accountFile: try VaultStore.read(repoA.accountURL), http: URLSessionHTTPClient())
            XCTFail()
        } catch { XCTAssertEqual(error as? SyncAPIError, .exists) }
        let other = try UnlockedAccount.create(password: password, kdf: testKDF, secretKey: .generate())
        do {
            try await SyncAPI.register(server: server, inviteCode: invite, accountId: other.accountId, authPublicKey: keyA.publicKey,
                                       accountFile: try other.serialized(), http: URLSessionHTTPClient())
            XCTFail()
        } catch { XCTAssertEqual(error as? SyncAPIError, .forbidden) }

        let clientA = try SyncClient(state: stateA, deviceName: "测试机甲", loginKey: keyA)
        let engineA = SyncEngine(repository: repoA, transport: clientA)
        var r = try await engineA.sync(account: account, state: &stateA, now: t0 + 1)
        XCTAssertEqual(r.uploaded, 1)
        XCTAssertTrue(r.failures.isEmpty)

        // 设备乙：主密码错了进不来，本机什么都不留
        let repoB = try tempRepo()
        do {
            _ = try await SyncSetup.join(server: server, accountId: account.accountId, secretKey: sk, password: "不对的密码",
                                         repository: repoB, deviceName: "测试机乙", now: t0 + 2)
            XCTFail()
        } catch { XCTAssertEqual(error as? SyncAPIError, .unauthorized) }
        XCTAssertFalse(repoB.exists)
        XCTAssertNil(repoB.readSyncState())

        // 主密码对了：下载账户文件和保险库
        let joined = try await SyncSetup.join(server: server, accountId: account.accountId.uppercased(), secretKey: sk,
                                              password: password, repository: repoB, deviceName: "测试机乙", now: t0 + 2)
        XCTAssertEqual(joined.loaded.vaults.flatMap { $0.activeItems.map(\.title) }, ["甲的第一条"])
        XCTAssertEqual(repoB.readSecretKey(accountId: account.accountId), sk)
        var stateB = try XCTUnwrap(repoB.readSyncState())
        XCTAssertNotNil(stateB.cursor)
        let engineB = SyncEngine(repository: repoB, transport: joined.client)

        // 两台设备同时改同一个保险库：后传的那台收到 412，合并后重传
        var va = try UnlockedVault.open(try VaultStore.read(repoA.vaultURL(vault.vaultId)), account: account)
        va.save(sampleLogin(t0 + 10, title: "甲加的"), now: t0 + 10)
        try repoA.save(&va, now: t0 + 10)
        var vb = try UnlockedVault.open(try VaultStore.read(repoB.vaultURL(vault.vaultId)), account: joined.loaded.account)
        vb.save(sampleLogin(t0 + 20, title: "乙加的"), now: t0 + 20)
        try repoB.save(&vb, now: t0 + 20)
        r = try await engineA.sync(account: account, state: &stateA, now: t0 + 30)
        XCTAssertEqual(r.uploaded, 1)
        r = try await engineB.sync(account: joined.loaded.account, state: &stateB, now: t0 + 31)
        XCTAssertEqual(r.updatedVaults, [vault.vaultId])
        XCTAssertEqual(r.uploaded, 1)
        _ = try await engineA.sync(account: account, state: &stateA, now: t0 + 32)
        let all: Set<String> = ["甲的第一条", "甲加的", "乙加的"]
        XCTAssertEqual(titles(repoA, account), all)
        XCTAssertEqual(titles(repoB, joined.loaded.account), all)

        // 甲改主密码：新账户文件带新登录公钥上传；乙收到新账户文件；旧登录密钥登不上了
        let newPassword = "换过的演示主密码"
        let newKDF = KDFParameters(alg: KDFParameters.algorithm, memKiB: 65_536, iterations: 2, parallelism: 1, salt: randomBytes(16))
        try account.changePassword(to: newPassword, kdf: newKDF)
        try repoA.saveAccount(account)
        let newKey = try LoginKey.derive(password: newPassword, kdf: newKDF, secretKey: sk, accountId: account.accountId)
        r = try await engineA.sync(account: account, state: &stateA, accountUploadKey: newKey, now: t0 + 40)
        XCTAssertEqual(r.uploaded, 1)
        XCTAssertTrue(r.failures.isEmpty)
        r = try await engineB.sync(account: joined.loaded.account, state: &stateB, now: t0 + 41)
        XCTAssertTrue(r.accountReplaced)
        _ = try UnlockedAccount.open(try VaultStore.read(repoB.accountURL), password: newPassword, secretKey: sk)

        let stale = try SyncClient(state: stateA, deviceName: "测试机甲", loginKey: keyA)
        do { try await stale.login(); XCTFail() } catch { XCTAssertEqual(error as? SyncAPIError, .unauthorized) }
        let fresh = try SyncClient(state: stateA, deviceName: "测试机甲", loginKey: newKey)
        try await fresh.login()
    }
}

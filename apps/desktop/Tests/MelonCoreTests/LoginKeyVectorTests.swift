import Crypto
import Foundation
import XCTest
@testable import MelonCore

/// 同步登录密钥的跨端测试向量（spec/sync-api.md §3.1、vault-format.md §7 `sync-auth/`）。服务端（Go）和
/// verify-vectors.py 也读同一份。校验每次都跑；生成只在 `MELON_REGEN_VECTORS=1` 时跑，只重写 `sync-auth/`。
final class LoginKeyVectorTests: XCTestCase {
    static var dir: URL { SpecVectorTests.dir.appendingPathComponent("sync-auth") }

    struct Vectors: Decodable {
        struct Case: Decodable {
            let name, password, accountId, secretKey, argon2, authSeed, publicKey, kek: String
            let salt: Data
            let memKiB, iterations: UInt32
        }
        struct Signed: Decodable {
            let what, publicKey, message, signature: String
        }
        struct Login: Decodable { let accountId, challenge, message, publicKey, signature: String }
        struct Rotate: Decodable { let accountId, accountFile, sha256, message, publicKey, signature: String }
        let cases: [Case]
        let login: Login
        let rotate: Rotate
        let invalid: [Signed]
    }

    func load() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.dir.appendingPathComponent("auth.json")))
    }

    // MARK: 校验

    func testDerivationVectors() throws {
        let v = try load()
        XCTAssertFalse(v.cases.isEmpty)
        for c in v.cases {
            let kdf = KDFParameters(alg: KDFParameters.algorithm, memKiB: c.memKiB, iterations: c.iterations, parallelism: 1, salt: c.salt)
            let sk = try SecretKey(text: c.secretKey)
            let argon = try UnlockedAccount.deriveKEK(password: c.password, kdf: kdf)
            XCTAssertEqual(argon.withUnsafeBytes { hex(Array($0)) }, c.argon2, c.name)
            let seed = LoginKey.seed(argon2Output: argon, secretKey: sk, accountId: c.accountId)
            XCTAssertEqual(seed.withUnsafeBytes { hex(Array($0)) }, c.authSeed, c.name)
            XCTAssertEqual(LoginKey.derive(argon2Output: argon, secretKey: sk, accountId: c.accountId).publicKey.base64EncodedString(),
                           c.publicKey, c.name)
            // 登录种子和 KEK 必须不同
            let kek = sk.deriveKEK(argon2Output: argon, accountId: c.accountId)
            XCTAssertEqual(kek.withUnsafeBytes { hex(Array($0)) }, c.kek, c.name)
            XCTAssertNotEqual(c.kek, c.authSeed, c.name)
        }
    }

    func testSignatureVectors() throws {
        let v = try load()
        let login = LoginKey.loginMessage(accountId: v.login.accountId, challenge: v.login.challenge)
        XCTAssertEqual(String(decoding: login, as: UTF8.self), v.login.message)
        XCTAssertTrue(LoginKey.verify(publicKey: Data(base64Encoded: v.login.publicKey)!, message: login,
                                      signature: Data(base64Encoded: v.login.signature)!))

        let file = Data(base64Encoded: v.rotate.accountFile)!
        XCTAssertEqual(LoginKey.sha256Hex(file), v.rotate.sha256)
        let rotate = LoginKey.rotateMessage(accountId: v.rotate.accountId, fileSHA256Hex: v.rotate.sha256)
        XCTAssertEqual(String(decoding: rotate, as: UTF8.self), v.rotate.message)
        XCTAssertTrue(LoginKey.verify(publicKey: Data(base64Encoded: v.rotate.publicKey)!, message: rotate,
                                      signature: Data(base64Encoded: v.rotate.signature)!))

        XCTAssertFalse(v.invalid.isEmpty)
        for c in v.invalid {
            XCTAssertFalse(LoginKey.verify(publicKey: Data(base64Encoded: c.publicKey)!, message: Data(c.message.utf8),
                                           signature: Data(base64Encoded: c.signature)!), c.what)
        }
    }

    /// 自己签的，用向量里的公钥能验过（Ed25519 签名在有些实现里带随机数，所以不比字节，只比能不能验过）
    func testOwnSignaturesVerify() throws {
        let v = try load()
        let c = v.cases[0]
        let kdf = KDFParameters(alg: KDFParameters.algorithm, memKiB: c.memKiB, iterations: c.iterations, parallelism: 1, salt: c.salt)
        let key = try LoginKey.derive(password: c.password, kdf: kdf, secretKey: try SecretKey(text: c.secretKey), accountId: c.accountId)
        let pub = Data(base64Encoded: c.publicKey)!
        let sig = try key.signLogin(accountId: c.accountId, challenge: v.login.challenge)
        XCTAssertTrue(LoginKey.verify(publicKey: pub, message: LoginKey.loginMessage(accountId: c.accountId, challenge: v.login.challenge), signature: sig))
        XCTAssertFalse(LoginKey.verify(publicKey: pub, message: LoginKey.loginMessage(accountId: c.accountId, challenge: "x" + v.login.challenge), signature: sig))
    }

    /// 解锁时一次 Argon2id 同时得到账户和登录密钥，和单独派生的一致
    func testOpenWithLoginKey() throws {
        let e = try JSONDecoder().decode(SecretKeyVectorTests.AccountExpectation.self,
                                         from: Data(contentsOf: SecretKeyVectorTests.dir.appendingPathComponent("expected.json")))
        let data = try Data(contentsOf: SecretKeyVectorTests.dir.appendingPathComponent("account.1melon"))
        let sk = try SecretKey(text: e.secretKey)
        let (account, key) = try UnlockedAccount.openWithLoginKey(data, password: e.password, secretKey: sk)
        XCTAssertEqual(account.accountKey.withUnsafeBytes { hex(Array($0)) }, e.accountKey)
        let alone = try LoginKey.derive(password: e.password, kdf: account.kdf, secretKey: sk, accountId: account.accountId)
        XCTAssertEqual(key.publicKey, alone.publicKey)
        XCTAssertThrowsError(try UnlockedAccount.openWithLoginKey(data, password: e.wrongPassword, secretKey: sk)) {
            XCTAssertEqual(SpecVectorTests.kind($0), "wrongPassword")
        }
    }

    // MARK: 生成（MELON_REGEN_VECTORS=1）

    func testRegenerateLoginKeyVectors() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MELON_REGEN_VECTORS"] == "1", "设置 MELON_REGEN_VECTORS=1 才重新生成向量")
        let fm = FileManager.default
        try? fm.removeItem(at: Self.dir)
        try fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let sk = try SecretKey(bytes: SecretKeyVectorTests.secretKeyBytes)
        let ones = try SecretKey(bytes: Data(repeating: 0xFF, count: 16))
        let inputs: [(String, String, UInt8, String, SecretKey)] = [
            ("ascii", "password", 0x44, "00000000-0000-4000-8000-000000000001", sk),
            ("中文与符号", "主密码：瓜！🍉", 0x55, "00000000-0000-4000-8000-000000000002", ones),
        ]
        var cases: [JSONValue] = []
        var keys: [LoginKey] = []
        for (name, pw, saltByte, accountId, key) in inputs {
            let salt = Data(repeating: saltByte, count: 16)
            let kdf = KDFParameters(alg: KDFParameters.algorithm, memKiB: 65_536, iterations: 2, parallelism: 1, salt: salt)
            let argon = try UnlockedAccount.deriveKEK(password: pw, kdf: kdf)
            let login = LoginKey.derive(argon2Output: argon, secretKey: key, accountId: accountId)
            keys.append(login)
            cases.append(.object([
                "name": .string(name), "password": .string(pw), "salt": .string(salt.base64EncodedString()),
                "memKiB": .number(65_536), "iterations": .number(2), "parallelism": .number(1),
                "accountId": .string(accountId), "secretKey": .string(key.text),
                "argon2": .string(argon.withUnsafeBytes { hex(Array($0)) }),
                "authSeed": .string(LoginKey.seed(argon2Output: argon, secretKey: key, accountId: accountId).withUnsafeBytes { hex(Array($0)) }),
                "publicKey": .string(login.publicKey.base64EncodedString()),
                "kek": .string(key.deriveKEK(argon2Output: argon, accountId: accountId).withUnsafeBytes { hex(Array($0)) }),
            ]))
        }

        let accountId = "00000000-0000-4000-8000-000000000001"
        let key = keys[0]
        let pub = key.publicKey.base64EncodedString()
        // 挑战的格式和服务端一致：nonce(16) ‖ 过期时间(8) ‖ MAC(16)，这里用固定字节，客户端只当它是一段不透明的 Base64
        let challenge = Data((0..<40).map { UInt8($0) }).base64EncodedString()
        let loginMessage = LoginKey.loginMessage(accountId: accountId, challenge: challenge)
        let loginSig = try key.signLogin(accountId: accountId, challenge: challenge)

        // 换钥：用 secret-key/ 里那个 v2 账户文件，私钥由它自己的主密码和 Secret Key 派生
        let e = try JSONDecoder().decode(SecretKeyVectorTests.AccountExpectation.self,
                                         from: Data(contentsOf: SecretKeyVectorTests.dir.appendingPathComponent("expected.json")))
        let accountFile = try Data(contentsOf: SecretKeyVectorTests.dir.appendingPathComponent("account.1melon"))
        let (_, rotateKey) = try UnlockedAccount.openWithLoginKey(accountFile, password: e.password, secretKey: try SecretKey(text: e.secretKey))
        let sha = LoginKey.sha256Hex(accountFile)
        let rotateMessage = LoginKey.rotateMessage(accountId: e.accountId, fileSHA256Hex: sha)
        let rotateSig = try rotateKey.signRotate(accountId: e.accountId, accountFile: accountFile)

        func signed(_ what: String, _ publicKey: Data, _ message: Data, _ signature: Data) -> JSONValue {
            .object(["what": .string(what), "publicKey": .string(publicKey.base64EncodedString()),
                     "message": .string(String(decoding: message, as: UTF8.self)), "signature": .string(signature.base64EncodedString())])
        }
        var flipped = loginSig
        flipped[0] ^= 1
        let invalid: [JSONValue] = [
            signed("换成另一个账户的公钥", keys[1].publicKey, loginMessage, loginSig),
            signed("消息里换了 accountId", key.publicKey, LoginKey.loginMessage(accountId: "00000000-0000-4000-8000-000000000002", challenge: challenge), loginSig),
            signed("签名翻转一位", key.publicKey, loginMessage, flipped),
            signed("登录签名拿去当换钥签名", key.publicKey, LoginKey.rotateMessage(accountId: accountId, fileSHA256Hex: sha), loginSig),
            signed("换钥消息里的 sha256 不是这份文件的", rotateKey.publicKey,
                   LoginKey.rotateMessage(accountId: e.accountId, fileSHA256Hex: String(repeating: "0", count: 64)), rotateSig),
        ]

        try pretty.encode(JSONValue.object([
            "description": .string("同步登录密钥（sync-api.md §3.1）：authSeed = HKDF-SHA256(IKM = Argon2id 输出, salt = Secret Key, info = 1melon:v2:auth:<accountId>, 32 字节)，作 Ed25519 私钥种子；kek 一并列出，必须和 authSeed 不同。login / rotate 是签名的消息和一个能验过的签名（Ed25519 签名在有些实现里带随机数，各端只比能否验过，不比字节）；invalid 每个都必须验不过"),
            "cases": .array(cases),
            "login": .object([
                "accountId": .string(accountId), "challenge": .string(challenge),
                "message": .string(String(decoding: loginMessage, as: UTF8.self)),
                "publicKey": .string(pub), "signature": .string(loginSig.base64EncodedString()),
            ]),
            "rotate": .object([
                "accountId": .string(e.accountId), "accountFile": .string(accountFile.base64EncodedString()), "sha256": .string(sha),
                "message": .string(String(decoding: rotateMessage, as: UTF8.self)),
                "publicKey": .string(rotateKey.publicKey.base64EncodedString()), "signature": .string(rotateSig.base64EncodedString()),
            ]),
            "invalid": .array(invalid),
        ])).write(to: Self.dir.appendingPathComponent("auth.json"))
    }
}

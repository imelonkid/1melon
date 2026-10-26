import Crypto
import Foundation
import XCTest
@testable import MelonCore

/// Secret Key 的跨端测试向量（spec §7 `secret-key/`）。校验每次都跑；生成只在 `MELON_REGEN_VECTORS=1` 时跑，
/// 只重写 `secret-key/` 目录，不动 example/ 和 tamper/。
final class SecretKeyVectorTests: XCTestCase {
    static var dir: URL { SpecVectorTests.dir.appendingPathComponent("secret-key") }

    static let password = "correct horse battery staple · 1Melon"
    /// 固定的 Secret Key（向量用，虚构）
    static let secretKeyBytes = Data((0..<16).map { UInt8(($0 * 17) & 0xFF) })

    struct KDFVectors: Decodable {
        struct Case: Decodable {
            let name, password, accountId, secretKey, secretKeyBytes, argon2, kek, secretKeyId: String
            let salt: Data
            let memKiB, iterations: UInt32
        }
        let cases: [Case]
    }

    struct TextVectors: Decodable {
        struct Valid: Decodable { let input, bytes, canonical: String }
        struct Invalid: Decodable { let input, why: String }
        let valid: [Valid]
        let invalid: [Invalid]
    }

    struct AccountExpectation: Decodable {
        let password, wrongPassword, secretKey, wrongSecretKey, accountId, accountKey: String
    }

    // MARK: 校验

    func testSecretKeyKDFVectors() throws {
        let v = try JSONDecoder().decode(KDFVectors.self, from: Data(contentsOf: Self.dir.appendingPathComponent("kdf.json")))
        XCTAssertFalse(v.cases.isEmpty)
        for c in v.cases {
            let kdf = KDFParameters(alg: KDFParameters.algorithm, memKiB: c.memKiB, iterations: c.iterations, parallelism: 1, salt: c.salt)
            let sk = try SecretKey(text: c.secretKey)
            XCTAssertEqual(sk.bytes.base64EncodedString(), c.secretKeyBytes, c.name)
            let argon = try UnlockedAccount.deriveKEK(password: c.password, kdf: kdf)
            XCTAssertEqual(argon.withUnsafeBytes { hex(Array($0)) }, c.argon2, c.name)
            let kek = try UnlockedAccount.deriveKEK(password: c.password, kdf: kdf, secretKey: sk, accountId: c.accountId)
            XCTAssertEqual(kek.withUnsafeBytes { hex(Array($0)) }, c.kek, c.name)
            XCTAssertEqual(sk.id(accountId: c.accountId).base64EncodedString(), c.secretKeyId, c.name)
        }
    }

    func testSecretKeyTextVectors() throws {
        let v = try JSONDecoder().decode(TextVectors.self, from: Data(contentsOf: Self.dir.appendingPathComponent("text.json")))
        XCTAssertFalse(v.valid.isEmpty)
        for c in v.valid {
            let sk = try SecretKey(text: c.input)
            XCTAssertEqual(sk.bytes.base64EncodedString(), c.bytes, c.input)
            XCTAssertEqual(sk.text, c.canonical, c.input)
        }
        for c in v.invalid {
            XCTAssertThrowsError(try SecretKey(text: c.input), c.why)
        }
    }

    func testSecretKeyAccountVectors() throws {
        let e = try JSONDecoder().decode(AccountExpectation.self, from: Data(contentsOf: Self.dir.appendingPathComponent("expected.json")))
        let data = try Data(contentsOf: Self.dir.appendingPathComponent("account.1melon"))
        let sk = try SecretKey(text: e.secretKey)
        let account = try UnlockedAccount.open(data, password: e.password, secretKey: sk)
        XCTAssertEqual(account.accountId, e.accountId)
        XCTAssertEqual(account.accountKey.withUnsafeBytes { hex(Array($0)) }, e.accountKey)
        XCTAssertThrowsError(try UnlockedAccount.open(data, password: e.password)) {
            XCTAssertEqual(SpecVectorTests.kind($0), "secretKeyRequired")
        }
        XCTAssertThrowsError(try UnlockedAccount.open(data, password: e.password, secretKey: try SecretKey(text: e.wrongSecretKey))) {
            XCTAssertEqual(SpecVectorTests.kind($0), "wrongSecretKey")
        }
        XCTAssertThrowsError(try UnlockedAccount.open(data, password: e.wrongPassword, secretKey: sk)) {
            XCTAssertEqual(SpecVectorTests.kind($0), "wrongPassword")
        }

        let cases = try JSONDecoder().decode([SpecVectorTests.TamperCase].self,
                                             from: Data(contentsOf: Self.dir.appendingPathComponent("tamper/cases.json")))
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let f = try Data(contentsOf: Self.dir.appendingPathComponent("tamper/\(c.file)"))
            XCTAssertThrowsError(try UnlockedAccount.open(f, password: e.password, secretKey: sk), c.file) {
                XCTAssertEqual(SpecVectorTests.kind($0), c.expect, "\(c.file)：\(c.what)")
            }
        }
    }

    // MARK: 生成（MELON_REGEN_VECTORS=1）

    func testRegenerateSecretKeyVectors() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MELON_REGEN_VECTORS"] == "1", "设置 MELON_REGEN_VECTORS=1 才重新生成向量")
        let fm = FileManager.default
        try? fm.removeItem(at: Self.dir)
        try fm.createDirectory(at: Self.dir.appendingPathComponent("tamper"), withIntermediateDirectories: true)
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let sk = try SecretKey(bytes: Self.secretKeyBytes)
        let ones = try SecretKey(bytes: Data(repeating: 0xFF, count: 16))
        let zero = try SecretKey(bytes: Data(count: 16))

        // kdf.json：主密码 + salt + Secret Key → Argon2id 输出 → KEK；secretKeyId
        var kdfCases: [JSONValue] = []
        let inputs: [(String, String, UInt8, String, SecretKey)] = [
            ("ascii", "password", 0x44, "00000000-0000-4000-8000-000000000001", sk),
            ("中文与符号", "主密码：瓜！🍉", 0x55, "00000000-0000-4000-8000-000000000002", ones),
        ]
        for (name, pw, saltByte, accountId, key) in inputs {
            let salt = Data(repeating: saltByte, count: 16)
            let kdf = KDFParameters(alg: KDFParameters.algorithm, memKiB: 65_536, iterations: 2, parallelism: 1, salt: salt)
            let argon = try UnlockedAccount.deriveKEK(password: pw, kdf: kdf)
            let kek = try UnlockedAccount.deriveKEK(password: pw, kdf: kdf, secretKey: key, accountId: accountId)
            kdfCases.append(.object([
                "name": .string(name), "password": .string(pw), "salt": .string(salt.base64EncodedString()),
                "memKiB": .number(65_536), "iterations": .number(2), "parallelism": .number(1),
                "accountId": .string(accountId), "secretKey": .string(key.text),
                "secretKeyBytes": .string(key.bytes.base64EncodedString()),
                "argon2": .string(argon.withUnsafeBytes { hex(Array($0)) }),
                "kek": .string(kek.withUnsafeBytes { hex(Array($0)) }),
                "secretKeyId": .string(key.id(accountId: accountId).base64EncodedString()),
            ]))
        }
        try pretty.encode(JSONValue.object([
            "description": .string("带 Secret Key 的 KEK（spec §2、§3.4）：KEK = HKDF-SHA256(IKM = Argon2id 输出, salt = Secret Key, info = 1melon:v2:kek:<accountId>, 32 字节)；secretKeyId = HMAC-SHA256(Secret Key, 1melon:v2:secret-key-id:<accountId>) 前 8 字节"),
            "cases": .array(kdfCases),
        ])).write(to: Self.dir.appendingPathComponent("kdf.json"))

        // text.json：写法的编码和解析
        func valid(_ input: String, _ key: SecretKey) -> JSONValue {
            .object(["input": .string(input), "bytes": .string(key.bytes.base64EncodedString()), "canonical": .string(key.text)])
        }
        let body = String(sk.text.dropFirst(3))
        var badCheck = Array(sk.text)
        badCheck[badCheck.count - 1] = badCheck.last == "0" ? "2" : "0"
        let invalid: [(String, String)] = [
            ("", "空"),
            (String(sk.text.dropLast()), "少一个字符"),
            (sk.text + "0", "多一个字符"),
            (String(badCheck), "校验位不对"),
            ("M1-8" + String(sk.text.dropFirst(4)), "第一个数据字符大于 7"),
            (sk.text.replacingOccurrences(of: "-", with: "U"), "U 不在字母表里"),
            ("M2-" + body, "写法版本不是 M1"),
        ]
        try pretty.encode(JSONValue.object([
            "description": .string("Secret Key 的写法（spec §3.4）：M1- + Crockford Base32 26 个数据字符 + 2 个校验字符，每 7 个一组"),
            "valid": .array([
                valid(sk.text, sk), valid(sk.text.lowercased(), sk), valid(body, sk),
                valid(body.replacingOccurrences(of: "-", with: " "), sk),
                valid("M1-" + body.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "L"), sk),
                valid(zero.text, zero), valid(ones.text, ones),
            ]),
            "invalid": .array(invalid.map { .object(["input": .string($0.0), "why": .string($0.1)]) }),
        ])).write(to: Self.dir.appendingPathComponent("text.json"))

        // account.1melon + expected.json：一个 v2 账户
        var kdf = testKDF
        kdf.salt = Data(repeating: 0x66, count: 16)
        let account = try UnlockedAccount.create(password: Self.password, kdf: kdf, secretKey: sk)
        let accountData = try account.serialized()
        try accountData.write(to: Self.dir.appendingPathComponent("account.1melon"))
        try pretty.encode(JSONValue.object([
            "description": .string("account.1melon 用 password + secretKey 解开后应得到的账户密钥；没给 Secret Key → secretKeyRequired；Secret Key 错 → wrongSecretKey；主密码错 → wrongPassword"),
            "password": .string(Self.password),
            "wrongPassword": .string("correct horse battery staple · 1melon"),
            "secretKey": .string(sk.text),
            "wrongSecretKey": .string(ones.text),
            "accountId": .string(account.accountId),
            "accountKey": .string(account.accountKey.withUnsafeBytes { hex(Array($0)) }),
        ])).write(to: Self.dir.appendingPathComponent("expected.json"))

        // tamper/：都用正确的主密码和 Secret Key 打开，必须拒绝
        func edit(_ f: (inout [String: JSONValue]) -> Void) throws -> Data {
            var top = try jsonObject(accountData)
            f(&top)
            return try pretty.encode(top)
        }
        let cases: [(String, String, String, Data)] = [
            ("v2-secret-key-none.1melon", "invalidFormat", "v2 账户文件写成 secretKey: none", try edit { $0["secretKey"] = .string("none") }),
            ("v2-missing-key-id.1melon", "invalidFormat", "v2 账户文件没有 secretKeyId", try edit { $0["secretKeyId"] = nil }),
            ("v2-key-id-changed.1melon", "wrongSecretKey", "secretKeyId 被改", try edit {
                $0["secretKeyId"] = .string(Data(repeating: 0, count: 8).base64EncodedString())
            }),
            ("v2-downgraded-to-v1.1melon", "wrongPassword", "改成 v1（去掉 Secret Key）：KEK 和 AAD 都对不上", try edit {
                $0["version"] = .number(1); $0["secretKey"] = .string("none"); $0["secretKeyId"] = nil
            }),
            ("v2-version-future.1melon", "unsupportedVersion", "账户格式版本是 3", try edit { $0["version"] = .number(3) }),
        ]
        for c in cases { try c.3.write(to: Self.dir.appendingPathComponent("tamper/\(c.0)")) }
        try pretty.encode(JSONValue.array(cases.map {
            .object(["file": .string($0.0), "target": .string("account"), "expect": .string($0.1), "what": .string($0.2)])
        })).write(to: Self.dir.appendingPathComponent("tamper/cases.json"))
    }
}

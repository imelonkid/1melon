import Foundation
import XCTest
@testable import MelonCore

/// 设置码的跨端测试向量：spec/test-vectors/sync-setup/setup-code.json（sync-api §7）
final class SetupCodeTests: XCTestCase {
    struct Vectors: Decodable {
        struct Valid: Decodable { let name, server, accountId, secretKey, code: String }
        struct Parse: Decodable { let name, input, server, accountId, secretKey: String }
        struct Invalid: Decodable { let why, input: String }
        let prefix: String
        let valid: [Valid]
        let parse: [Parse]
        let invalid: [Invalid]
    }

    func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: SpecVectorTests.dir.appendingPathComponent("sync-setup/setup-code.json")))
    }

    func testVectors() throws {
        let v = try vectors()
        XCTAssertEqual(v.prefix, SetupCode.prefix)
        for c in v.valid {
            let code = SetupCode(server: c.server, accountId: c.accountId, secretKey: try SecretKey(text: c.secretKey))
            XCTAssertEqual(code.text, c.code, c.name)
            let parsed = try SetupCode(text: c.code)
            XCTAssertEqual([parsed.server, parsed.accountId, parsed.secretKey.text], [c.server, c.accountId, c.secretKey], c.name)
        }
        for c in v.parse {
            let parsed = try SetupCode(text: c.input)
            XCTAssertEqual([parsed.server, parsed.accountId, parsed.secretKey.text], [c.server, c.accountId, c.secretKey], c.name)
        }
        for c in v.invalid {
            XCTAssertThrowsError(try SetupCode(text: c.input), c.why)
        }
    }

    func testRoundTripAndErrorKinds() throws {
        let sk = SecretKey.generate()
        let code = SetupCode(server: "https://sync.example.test/", accountId: "0d3a3c62-6a8e-4c39-9a4e-3a4d2b1f0c11", secretKey: sk)
        XCTAssertEqual(code.server, "https://sync.example.test")
        XCTAssertEqual(try SetupCode(text: code.text), code)
        let v = try vectors()
        func kind(_ why: String) -> SetupCode.ParseError? {
            let input = v.invalid.first { $0.why == why }!.input
            do { _ = try SetupCode(text: input); return nil } catch { return error as? SetupCode.ParseError }
        }
        XCTAssertEqual(kind("前缀小写"), .malformed)
        XCTAssertEqual(kind("http 地址"), .invalidServer)
        XCTAssertEqual(kind("accountId 大写"), .invalidAccountId)
        XCTAssertEqual(kind("Secret Key 校验字符对不上"), .invalidSecretKey)
    }
}

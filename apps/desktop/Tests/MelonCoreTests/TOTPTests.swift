import Foundation
import XCTest
@testable import MelonCore

/// 跨端测试向量：spec/test-vectors/totp.json（RFC 6238 附录 B）。
final class TOTPTests: XCTestCase {
    struct Vectors: Decodable {
        struct Case: Decodable { let time: Int64; let digits8: String; let digits6: String }
        let secretAscii: String
        let secretBase32: String
        let period: Int
        let cases: [Case]
    }

    static func loadVectors() throws -> Vectors {
        // Tests/MelonCoreTests/TOTPTests.swift → 仓库根
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("spec/test-vectors/totp.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func testSpecVectors() throws {
        let v = try Self.loadVectors()
        XCTAssertEqual(try Base32.decode(v.secretBase32), Array(v.secretAscii.utf8))
        let eight = TOTP(secret: Array(v.secretAscii.utf8), digits: 8, period: v.period)
        let six = TOTP(secret: Array(v.secretAscii.utf8), digits: 6, period: v.period)
        XCTAssertFalse(v.cases.isEmpty)
        for c in v.cases {
            XCTAssertEqual(eight.code(atUnixTime: c.time), c.digits8, "t=\(c.time)")
            XCTAssertEqual(six.code(atUnixTime: c.time), c.digits6, "t=\(c.time)")
        }
    }

    func testParseBase32Secret() throws {
        let totp = try TOTP.parse("  gezd gnbv gy3t qojq gezd gnbv gy3t qojq ")
        XCTAssertEqual(totp.digits, 6)
        XCTAssertEqual(totp.code(atUnixTime: 59), "287082")
    }

    func testParseOtpauthURL() throws {
        let url = "otpauth://totp/GitHub:me?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=GitHub&digits=8&period=30&algorithm=SHA1"
        let totp = try TOTP.parse(url)
        XCTAssertEqual(totp.digits, 8)
        XCTAssertEqual(totp.code(atUnixTime: 1_111_111_109), "07081804")
    }

    func testParseRejectsBadInput() {
        XCTAssertThrowsError(try TOTP.parse("")) { XCTAssertEqual($0 as? TOTP.ParseError, .empty) }
        XCTAssertThrowsError(try TOTP.parse("not base32 !!")) { XCTAssertEqual($0 as? TOTP.ParseError, .invalidSecret) }
        XCTAssertThrowsError(try TOTP.parse("otpauth://hotp/x?secret=GEZDGNBV")) { XCTAssertEqual($0 as? TOTP.ParseError, .invalidURL) }
        XCTAssertThrowsError(try TOTP.parse("otpauth://totp/x?secret=GEZDGNBV&digits=12"))
        XCTAssertThrowsError(try TOTP.parse("otpauth://totp/x?secret=GEZDGNBV&algorithm=MD5"))
    }

    func testSecondsRemaining() {
        let totp = TOTP(secret: [1, 2, 3])
        XCTAssertEqual(totp.secondsRemaining(at: Date(timeIntervalSince1970: 0)), 30)
        XCTAssertEqual(totp.secondsRemaining(at: Date(timeIntervalSince1970: 29.9)), 1)
        XCTAssertEqual(totp.secondsRemaining(at: Date(timeIntervalSince1970: 45)), 15)
    }
}

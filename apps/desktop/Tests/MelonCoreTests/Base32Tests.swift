import XCTest
@testable import MelonCore

/// RFC 4648 第 10 节的测试向量。
final class Base32Tests: XCTestCase {
    let vectors: [(String, String)] = [
        ("", ""),
        ("f", "MY======"),
        ("fo", "MZXQ===="),
        ("foo", "MZXW6==="),
        ("foob", "MZXW6YQ="),
        ("fooba", "MZXW6YTB"),
        ("foobar", "MZXW6YTBOI======"),
    ]

    func testRFC4648() throws {
        for (plain, encoded) in vectors {
            XCTAssertEqual(Base32.encode(Array(plain.utf8)), encoded)
            XCTAssertEqual(try Base32.decode(encoded), Array(plain.utf8))
        }
    }

    func testLenientDecoding() throws {
        XCTAssertEqual(try Base32.decode("mzxw 6ytb-oi"), Array("foobar".utf8))
    }

    func testRejectsInvalid() {
        XCTAssertThrowsError(try Base32.decode("MZXW1")) // 1 不在字母表里
        XCTAssertThrowsError(try Base32.decode("M"))     // 长度不合法
    }
}

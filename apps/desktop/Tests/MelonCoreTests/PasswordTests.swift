import XCTest
@testable import MelonCore

final class PasswordGeneratorTests: XCTestCase {
    func testRandomContainsEveryEnabledSet() {
        for _ in 0..<200 {
            let pw = PasswordGenerator.random(.init(length: 8))
            XCTAssertEqual(pw.count, 8)
            XCTAssertTrue(pw.contains { PasswordGenerator.lowercase.contains($0) })
            XCTAssertTrue(pw.contains { PasswordGenerator.uppercase.contains($0) })
            XCTAssertTrue(pw.contains { PasswordGenerator.digitChars.contains($0) })
            XCTAssertTrue(pw.contains { PasswordGenerator.symbolChars.contains($0) })
        }
    }

    func testRandomRespectsOptions() {
        for _ in 0..<200 {
            let pw = PasswordGenerator.random(.init(length: 32, includeDigits: false, includeSymbols: false, excludeAmbiguous: true))
            XCTAssertEqual(pw.count, 32)
            XCTAssertTrue(pw.allSatisfy { $0.isLetter && $0.isASCII })
            XCTAssertTrue(pw.allSatisfy { !PasswordGenerator.ambiguous.contains($0) })
        }
    }

    func testRandomClampsLength() {
        XCTAssertEqual(PasswordGenerator.random(.init(length: 1)).count, 8)
        XCTAssertEqual(PasswordGenerator.random(.init(length: 500)).count, 64)
    }

    func testRandomIsNotRepeating() {
        let set = Set((0..<100).map { _ in PasswordGenerator.random() })
        XCTAssertEqual(set.count, 100)
    }

    func testPin() {
        let pin = PasswordGenerator.pin(length: 6)
        XCTAssertEqual(pin.count, 6)
        XCTAssertTrue(pin.allSatisfy(\.isNumber))
        XCTAssertEqual(PasswordGenerator.pin(length: 2).count, 4)
    }

    func testMemorable() {
        var rng = SystemRandomNumberGenerator()
        let pw = PasswordGenerator.memorable(words: 4, wordlist: ["river", "maple", "orbit"], using: &rng)
        let parts = pw.split(separator: "-")
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts.filter { Int($0) != nil }.count, 1)
        XCTAssertTrue(parts.filter { Int($0) == nil }.allSatisfy { $0.first!.isUppercase })
    }
}

final class PasswordStrengthTests: XCTestCase {
    func testWeakPasswords() {
        for pw in ["", "123456", "admin123", "chenlin1990", "password"] {
            XCTAssertEqual(PasswordStrength.evaluate(pw).level, .weak, pw)
        }
    }

    func testStrongPasswords() {
        XCTAssertGreaterThanOrEqual(PasswordStrength.evaluate("Harbor-Velvet-42-Summit").level, .strong)
        XCTAssertEqual(PasswordStrength.evaluate("v7#Qm2!xLp9@Tz4K").level, .veryStrong) // 16 位 × log2(94) ≈ 105 bits
        XCTAssertEqual(PasswordStrength.evaluate("maple-orbit-77").level, .strong)
        XCTAssertEqual(PasswordStrength.evaluate(PasswordGenerator.random(.init(length: 20))).level, .veryStrong)
    }

    func testAllDigitsUsesDecimalEntropy() {
        XCTAssertEqual(PasswordStrength.evaluate("12345678901234567890").bits, 66)
    }
}

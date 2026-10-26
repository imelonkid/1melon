import Crypto
import Foundation
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

    /// 按骰子编号（11111…66666）把词表还原成 EFF 原文件，校验 SHA-256：词表一个字都没改
    func testEFFWordlistMatchesOriginalFile() {
        let words = EFFWordlist.words
        XCTAssertEqual(words.count, 7776)
        XCTAssertEqual(Set(words).count, 7776, "没有重复的词")
        var lines: [String] = []
        for (i, w) in words.enumerated() {
            var n = i, dice = ""
            for _ in 0..<5 { dice = String(n % 6 + 1) + dice; n /= 6 }
            lines.append("\(dice)\t\(w)\n")
        }
        let digest = SHA256.hash(data: Data(lines.joined().utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e")
    }

    func testMemorableWithEFFWordlist() {
        let known = Set(EFFWordlist.words)
        for _ in 0..<50 {
            let pw = PasswordGenerator.memorable(words: 5, capitalize: false, insertNumber: false)
            // 词表里有 t-shirt 这类带连字符的词，按词表逐个匹配，不能简单按「-」切
            var rest = Substring(pw), count = 0
            while !rest.isEmpty {
                let hit = known.filter { rest.hasPrefix($0) && (rest.count == $0.count || rest.dropFirst($0.count).first == "-") }
                    .max { $0.count < $1.count }
                guard let w = hit else { return XCTFail("不是词表里的词：\(pw)") }
                rest = rest.dropFirst(w.count).drop { $0 == "-" }
                count += 1
            }
            XCTAssertEqual(count, 5, pw)
        }
        XCTAssertEqual(PasswordGenerator.memorable(words: 1).split(separator: "-").filter { Int($0) == nil }.count, 3, "词数不少于 3")
    }

    func testMemorableBits() {
        XCTAssertEqual(PasswordGenerator.memorableBits(words: 4, insertNumber: false), 51) // 4 × 12.92
        XCTAssertEqual(PasswordGenerator.memorableBits(words: 5, insertNumber: false), 64)
        XCTAssertEqual(PasswordGenerator.memorableBits(words: 4, insertNumber: true), 60) // + log2(90) + log2(5)
        XCTAssertEqual(PasswordStrength(bits: 60).level, .fair)
        XCTAssertEqual(PasswordStrength(bits: 77).level, .strong)
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

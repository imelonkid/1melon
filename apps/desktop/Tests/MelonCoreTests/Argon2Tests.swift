import Foundation
import XCTest
@testable import MelonCore

final class Argon2Tests: XCTestCase {
    /// RFC 9106 §5.3 Argon2id 测试向量。
    func testRFC9106Vector() throws {
        let tag = try Argon2id.hash(
            password: [UInt8](repeating: 0x01, count: 32),
            salt: [UInt8](repeating: 0x02, count: 16),
            memoryKiB: 32, iterations: 3, parallelism: 4, length: 32,
            secret: [UInt8](repeating: 0x03, count: 8),
            associatedData: [UInt8](repeating: 0x04, count: 12)
        )
        XCTAssertEqual(hex(tag), "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    /// 解锁耗时基准：`MELON_BENCH=1 swift test -c release --filter Argon2Tests` 才跑。
    func testBenchmarkUnlockParams() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MELON_BENCH"] == "1", "设置 MELON_BENCH=1 才跑基准")
        for (mem, t) in [(65_536, 2), (65_536, 3), (131_072, 3), (262_144, 3)] as [(UInt32, UInt32)] {
            let start = Date()
            _ = try Argon2id.hash(password: Array("bench".utf8), salt: [UInt8](repeating: 7, count: 16),
                                  memoryKiB: mem, iterations: t, parallelism: 1)
            print(String(format: "BENCH m=%d MiB t=%d: %.2f s", mem / 1024, t, Date().timeIntervalSince(start)))
        }
    }

    func testRejectsTooShortSalt() {
        XCTAssertThrowsError(try Argon2id.hash(password: [1], salt: [1, 2, 3], memoryKiB: 64, iterations: 1, parallelism: 1))
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

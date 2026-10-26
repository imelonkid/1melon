import Foundation
import XCTest
@testable import MelonCore

final class ReleaseManifestTests: XCTestCase {
    func testSemVer() {
        XCTAssertTrue(SemVer.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertTrue(SemVer.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(SemVer.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(SemVer.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(SemVer.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(SemVer.isNewer("garbage", than: "0.0.0"))
    }

    func testDecodeManifest() throws {
        let json = #"{"version":"0.1.0","tag":"desktop-v0.1.0","date":"2026-10-26 18:00:00","notes":"首个版本","files":{"arm64":"https://melon-download.oss-cn-beijing.aliyuncs.com/1melon/desktop/1Melon-0.1.0-arm64.dmg"},"sha256":{"arm64":"abc"},"futureField":1}"#
        let m = try JSONDecoder().decode(ReleaseManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.tag, "desktop-v0.1.0")
        XCTAssertEqual(m.downloadURL?.host, "melon-download.oss-cn-beijing.aliyuncs.com")
        let insecure = #"{"version":"0.1.0","tag":"desktop-v0.1.0","files":{"arm64":"http://example.com/a.dmg"}}"#
        XCTAssertNil(try JSONDecoder().decode(ReleaseManifest.self, from: Data(insecure.utf8)).downloadURL)
    }
}

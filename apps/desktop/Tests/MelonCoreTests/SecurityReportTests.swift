import Foundation
import XCTest
@testable import MelonCore

final class SecurityReportTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func login(_ title: String, password: String, url: String = "", totp: String = "", modifiedDaysAgo: Double = 1) -> VaultItem {
        var it = VaultItem.fromTemplate(.login, title: title, now: 0)
        it.sections[0].fields[1].value = password
        it.sections[0].fields[2].value = url
        it.sections[1].fields[0].value = totp
        it.modified = now.addingTimeInterval(-modifiedDaysAgo * 86_400).unixMilliseconds
        return it
    }

    func testFindsEachKindOfIssue() {
        let strong = "v7#Qm2!xLp9@Tz4K"
        let weak = login("路由器", password: "admin123")
        let a = login("淘宝", password: "Same-Pass-2024-xyz")
        let b = login("支付宝", password: "Same-Pass-2024-xyz")
        let no2fa = login("GitHub", password: strong + "1", url: "github.com")
        let has2fa = login("GitLab", password: strong + "2", url: "https://gitlab.com", totp: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let unknownSite = login("某论坛", password: strong + "3", url: "bbs.example.cn")
        let subdomain = login("Google", password: strong + "4", url: "accounts.google.com")
        let old = login("老网站", password: strong + "5", modifiedDaysAgo: 400)
        var note = VaultItem.fromTemplate(.note, title: "笔记", now: 0)
        note.modified = now.addingTimeInterval(-1000 * 86_400).unixMilliseconds

        let r = SecurityReport.analyze([weak, a, b, no2fa, has2fa, unknownSite, subdomain, old, note], now: now)
        XCTAssertEqual(r.issues(for: weak.id).map(\.kind), [.weak])
        XCTAssertEqual(r.issues(for: a.id).map(\.kind), [.reused])
        XCTAssertEqual(r.issues(for: a.id).first?.sharedWith, [b.id])
        XCTAssertEqual(r.issues(for: no2fa.id).map(\.kind), [.no2fa])
        XCTAssertEqual(r.issues(for: subdomain.id).map(\.kind), [.no2fa])
        XCTAssertTrue(r.issues(for: has2fa.id).isEmpty)
        XCTAssertTrue(r.issues(for: unknownSite.id).isEmpty, "不在名单里的网站不提示两步验证")
        XCTAssertEqual(r.issues(for: old.id).map(\.kind), [.old])
        XCTAssertTrue(r.issues(for: note.id).isEmpty, "没有密码的条目不算长期未更新")
        XCTAssertEqual(r.count(.reused), 2)
        XCTAssertEqual(r.score, 100 - 8 - 5 * 2 - 4 * 2 - 2)
    }

    func testCleanVaultScores100AndScoreNeverNegative() {
        XCTAssertEqual(SecurityReport.analyze([login("A", password: "v7#Qm2!xLp9@Tz4K")], now: now).score, 100)
        let many = (0..<30).map { login("弱\($0)", password: "123456", modifiedDaysAgo: 500) }
        XCTAssertEqual(SecurityReport.analyze(many, now: now).score, 0)
    }

    func testPasswordsInEverySectionCount() {
        var it = login("多密码", password: "v7#Qm2!xLp9@Tz4K")
        it.sections.append(ItemSection(title: "旧账号", fields: [ItemField(label: "密码", kind: .password, value: "111111")]))
        XCTAssertEqual(SecurityReport.analyze([it], now: now).issues(for: it.id).map(\.kind), [.weak])
    }
}

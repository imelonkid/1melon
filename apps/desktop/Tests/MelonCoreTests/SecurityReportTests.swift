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

    func testIgnoredIssuesDoNotCountButAreListed() {
        var reusedA = login("淘宝", password: "Same-Pass-2024-xyz", url: "github.com")
        let reusedB = login("支付宝", password: "Same-Pass-2024-xyz")
        reusedA.ignoredIssues = ["reused", "未来的新种类"]
        let r = SecurityReport.analyze([reusedA, reusedB], now: now)
        XCTAssertEqual(r.issues(for: reusedA.id).map(\.kind), [.no2fa], "忽略了的不再提示，别的照旧")
        XCTAssertEqual(r.ignoredIssues(for: reusedA.id).map(\.kind), [.reused])
        XCTAssertEqual(r.issues(for: reusedB.id).map(\.kind), [.reused], "另一个条目没忽略，仍然提示")
        XCTAssertEqual(r.count(.reused), 1)
        XCTAssertEqual(r.score, 100 - 5 - 4, "忽略了的不扣分")
    }

    func testChangingPasswordResetsWeakAndReusedIgnores() throws {
        var vault = try UnlockedVault.create(in: testAccount, meta: VaultMeta(name: "测试", created: 0))
        var item = login("路由器", password: "admin123", url: "github.com")
        item.ignoredIssues = ["weak", "reused", "no2fa"]
        vault.save(item, now: 1)
        var edited = vault.activeItems[0]
        edited.notes = "只改备注"
        vault.save(edited, now: 2)
        XCTAssertEqual(vault.activeItems[0].ignoredIssues, ["weak", "reused", "no2fa"], "密码没变，忽略保留")
        edited = vault.activeItems[0]
        edited.sections[0].fields[1].value = "new-admin-456"
        vault.save(edited, now: 3)
        XCTAssertEqual(vault.activeItems[0].ignoredIssues, ["no2fa"], "密码变了，弱密码和重复使用要重新判断")
        vault.delete(id: item.id, now: 4)
        XCTAssertEqual(vault.items[0].ignoredIssues, [], "墓碑不留忽略记录")
    }

    func testIgnoredIssuesRoundTripAndOmittedWhenEmpty() throws {
        var vault = try UnlockedVault.create(in: testAccount, meta: VaultMeta(name: "测试", created: 0))
        var a = login("A", password: "123456")
        a.ignoredIssues = ["weak", "未来的新种类"]
        let b = login("B", password: "123456")
        vault.save(a, now: 1)
        vault.save(b, now: 1)
        let reopened = try UnlockedVault.open(try vault.serialized(now: 2), account: testAccount)
        XCTAssertEqual(reopened.activeItems.first { $0.id == a.id }?.ignoredIssues, ["weak", "未来的新种类"], "不认识的值原样保留")
        XCTAssertEqual(reopened.activeItems.first { $0.id == b.id }?.ignoredIssues, [])
        let plain = try JSONEncoder().encode(ItemPlaintext(b))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("ignoredIssues"), "没有忽略时不写这个键")
    }

    /// 增量分析：没变的条目不重新分析；改了一个只分析一个；结果和整份重新分析一样
    func testAnalyzerOnlyReanalyzesChangedItems() {
        var items = PerformanceFixtures.items(300, now: now)
        var analyzer = SecurityAnalyzer()
        let first = analyzer.report(for: items, now: now)
        XCTAssertEqual(analyzer.lastAnalyzedCount, 300)
        XCTAssertEqual(analyzer.report(for: items, now: now), first)
        XCTAssertEqual(analyzer.lastAnalyzedCount, 0, "条目没变不重新分析")

        // 改一个密码（rev 加 1）、删一个、加一个
        items[1].sections[0].fields[1].value = items[2].sections[0].fields[1].value
        items[1].rev += 1
        items.remove(at: 10)
        items.append(login("新条目", password: "123456"))
        let next = analyzer.report(for: items, now: now)
        XCTAssertEqual(analyzer.lastAnalyzedCount, 2, "只分析改过的和新加的")
        XCTAssertEqual(next, SecurityReport.analyze(items, now: now), "增量结果和整份重新分析一致")
        XCTAssertTrue(next.issues(for: items[1].id).contains { $0.kind == .reused && $0.sharedWith.contains(items[2].id) })
    }
}

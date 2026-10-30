import Foundation
import XCTest
@testable import MelonCore

/// 性能回归：桌面端切换侧栏菜单时主线程只查 `ItemIndex`，安全报告在后台增量分析。
/// 1000 个条目下，下面每一步都要远低于一帧卡顿的界限（主线程单次阻塞 < 100 ms）。
/// 上限按 CI（Linux、debug 构建）放宽；本机 release 构建实际只有几毫秒，见 PR 里的数字。
final class PerformanceTests: XCTestCase {
    static let count = 1000
    /// 每一步的上限（秒）
    static let budget = 0.1

    func time(_ name: String, _ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        let t = Date().timeIntervalSince(start)
        print(String(format: "性能 %@：%.1f ms", name, t * 1000))
        return t
    }

    func vaults(_ items: [VaultItem]) throws -> [UnlockedVault] {
        var personal = try UnlockedVault.create(in: testAccount, meta: VaultMeta(name: "个人", created: 0))
        var work = try UnlockedVault.create(in: testAccount, meta: VaultMeta(name: "工作", order: 1, created: 1))
        for (i, item) in items.enumerated() {
            if i % 5 == 0 { work.save(item, now: item.modified) } else { personal.save(item, now: item.modified) }
        }
        return [personal, work]
    }

    func testSwitchingSidebarStaysUnderBudget() throws {
        let vs = try vaults(PerformanceFixtures.items(Self.count))
        var index = ItemIndex.empty
        XCTAssertLessThan(time("建索引") { index = ItemIndex(vaults: vs) }, Self.budget)
        XCTAssertEqual(index.entries.count, Self.count)

        var analyzer = SecurityAnalyzer()
        var report = SecurityReport.empty
        // 整份分析在后台跑，不占主线程；也给它一个上限，防止退化成 O(n²)
        XCTAssertLessThan(time("首次安全分析（后台）") { report = analyzer.report(for: index.items) }, Self.budget * 5)
        XCTAssertFalse(report.issues.isEmpty)

        let scopes: [ItemIndex.Scope] = [.all, .favorites, .issues(nil), .issues(.weak), .vault(vs[0].vaultId), .vault(vs[1].vaultId)]
        for scope in scopes {
            var list: [ItemIndex.Entry] = []
            XCTAssertLessThan(time("切到 \(scope)") { list = index.listed(scope: scope, report: report) }, Self.budget)
            XCTAssertLessThan(time("切到 \(scope)，按名称") { _ = index.listed(scope: scope, byTitle: true, report: report) }, Self.budget)
            XCTAssertFalse(list.isEmpty, "\(scope)")
        }
        XCTAssertLessThan(time("搜索") { _ = index.listed(scope: .all, query: "演示条目 99", report: report) }, Self.budget)
        XCTAssertLessThan(time("逐条查问题和条目") {
            for e in index.entries { _ = report.issues(for: e.id); _ = index.entry(e.id) }
        }, Self.budget)
    }

    func testIncrementalAnalysisAfterEditStaysUnderBudget() throws {
        var items = PerformanceFixtures.items(Self.count)
        var analyzer = SecurityAnalyzer()
        _ = analyzer.report(for: items)
        items[0].sections[0].fields[1].value = "changed-\(UUID().uuidString)"
        items[0].rev += 1
        XCTAssertLessThan(time("改一个条目后增量分析") { _ = analyzer.report(for: items) }, Self.budget)
        XCTAssertEqual(analyzer.lastAnalyzedCount, 1)
    }
}

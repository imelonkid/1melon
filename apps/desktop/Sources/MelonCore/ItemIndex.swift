import Foundation

/// 解锁后全部保险库的条目索引：数据变了（保存、删除、搬移、同步合并）才重建一次，界面切换菜单、重绘时只查它，不再逐次遍历保险库。
/// 里面是明文条目，和 `LoadedAccount` 一样只在内存里，锁定时丢掉。
public struct ItemIndex: Sendable {
    /// 列表里的一行：条目 + 它所在的保险库
    public struct Entry: Sendable, Identifiable {
        public let item: VaultItem
        public let vault: VaultMeta
        public let vaultId: String
        public var id: String { item.id }
    }

    /// 侧栏的范围
    public enum Scope: Hashable, Sendable {
        case all, favorites
        case vault(String)
        /// 安全报告：有问题的条目，`kind` 为 nil 时不限种类
        case issues(SecurityReport.Kind?)
    }

    /// 全部保险库里没被删除的条目，按保险库顺序
    public let entries: [Entry]
    /// 条目 id → 标题（安全提示里「和某某用的是同一个密码」）
    public let titles: [String: String]
    /// 用过的全部标签，按名称排序
    public let tags: [String]
    public let favoriteCount: Int
    /// 保险库 id → 条目数
    public let counts: [String: Int]
    /// 条目 id + rev：判断条目有没有增删改（只改保险库名字之类不算）
    public let revisions: [String: Int]
    private let positions: [String: Int]

    public static let empty = ItemIndex(vaults: [])

    public init(vaults: [UnlockedVault]) {
        var entries: [Entry] = []
        var counts: [String: Int] = [:]
        for v in vaults {
            var n = 0
            for item in v.items where !item.deleted {
                entries.append(Entry(item: item, vault: v.meta, vaultId: v.vaultId))
                n += 1
            }
            counts[v.vaultId] = n
        }
        self.entries = entries
        self.counts = counts
        var titles: [String: String] = [:], positions: [String: Int] = [:], revisions: [String: Int] = [:]
        var tags = Set<String>()
        var favorites = 0
        for (i, e) in entries.enumerated() {
            if positions[e.id] == nil { positions[e.id] = i; titles[e.id] = e.item.title }
            revisions[e.id] = e.item.rev
            tags.formUnion(e.item.tags)
            if e.item.favorite { favorites += 1 }
        }
        self.titles = titles
        self.positions = positions
        self.revisions = revisions
        self.tags = tags.sorted()
        favoriteCount = favorites
    }

    public var items: [VaultItem] { entries.map(\.item) }

    public func entry(_ id: String) -> Entry? { positions[id].map { entries[$0] } }

    /// 列表要显示的条目。搜索时搜全部保险库、不看范围；再按类型筛选，最后排序（`byTitle` 为 false 时最近修改的在前）
    public func listed(scope: Scope, query: String = "", type: ItemType? = nil, byTitle: Bool = false,
                       report: SecurityReport = .empty) -> [Entry] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        var out: [Entry]
        if searching {
            out = entries.filter { $0.item.matches(query) }
        } else {
            switch scope {
            case .all: out = entries
            case .favorites: out = entries.filter(\.item.favorite)
            case .vault(let id): out = entries.filter { $0.vaultId == id }
            case .issues(let kind): out = entries.filter { e in report.issues(for: e.id).contains { kind == nil || $0.kind == kind } }
            }
        }
        if let type { out = out.filter { $0.item.type == type } }
        if byTitle {
            out.sort { $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending }
        } else {
            out.sort { $0.item.modified > $1.item.modified }
        }
        return out
    }
}

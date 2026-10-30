import Crypto
import Foundation

/// 安全报告：只在本机根据保险库内容计算，不联网、不查任何泄露数据库。
public struct SecurityReport: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable, Comparable {
        /// 强度估算低于 `PasswordStrength.weakThreshold`
        case weak
        /// 同一个密码出现在两个及以上条目里（跨全部保险库）
        case reused
        /// 网站在「支持两步验证的常见网站」名单里，但条目里没有一次性验证码
        case no2fa
        /// 条目超过一年没有修改过（没有单独记录密码字段的修改时间，按整个条目算）
        case old

        /// 严重程度排序：弱密码最重
        public static func < (a: Kind, b: Kind) -> Bool { a.order < b.order }
        var order: Int { Self.allCases.firstIndex(of: self)! }

        /// 健康分里每个问题扣几分（设计稿的权重）
        var penalty: Int {
            switch self {
            case .weak: 8
            case .reused: 5
            case .no2fa: 4
            case .old: 2
            }
        }
    }

    public struct Issue: Sendable, Equatable, Identifiable {
        public let kind: Kind
        public let itemId: String
        /// 重复使用时，和它共用同一个密码的其他条目
        public let sharedWith: [String]
        public var id: String { "\(kind.rawValue):\(itemId)" }
    }

    /// 需要处理的问题（不含用户忽略了的）
    public let issues: [Issue]
    /// 用户忽略了的问题（条目的 `ignoredIssues`）：不扣分、不计数，安全报告里单独列出来，可以恢复
    public let ignored: [Issue]
    /// 0…100，越高越好；忽略了的问题不扣分
    public let score: Int
    /// 有问题（不含忽略的）的条目
    public let itemsWithIssues: Set<String>

    private let byItem: [String: [Issue]]
    private let ignoredByItem: [String: [Issue]]
    private let counts: [Kind: Int]

    public init(issues: [Issue], ignored: [Issue] = []) {
        self.issues = issues
        self.ignored = ignored
        let penalty = issues.reduce(0) { $0 + $1.kind.penalty }
        score = max(0, min(100, 100 - penalty))
        itemsWithIssues = Set(issues.map(\.itemId))
        byItem = Dictionary(grouping: issues, by: \.itemId).mapValues { $0.sorted { $0.kind < $1.kind } }
        ignoredByItem = Dictionary(grouping: ignored, by: \.itemId).mapValues { $0.sorted { $0.kind < $1.kind } }
        counts = Dictionary(grouping: issues, by: \.kind).mapValues(\.count)
    }

    public static let empty = SecurityReport(issues: [])

    public static func == (a: SecurityReport, b: SecurityReport) -> Bool { a.issues == b.issues && a.ignored == b.ignored }

    public func count(_ kind: Kind) -> Int { counts[kind] ?? 0 }

    /// 条目的问题，按严重程度排序。查表，不扫描
    public func issues(for itemId: String) -> [Issue] { byItem[itemId] ?? [] }

    /// 条目里被忽略了的问题
    public func ignoredIssues(for itemId: String) -> [Issue] { ignoredByItem[itemId] ?? [] }

    public static let oldAfterDays = 365

    /// 分析一组没有被删除的条目（通常是全部保险库的 activeItems）。界面上用 `SecurityAnalyzer` 做增量分析
    public static func analyze(_ items: [VaultItem], now: Date = Date()) -> SecurityReport {
        var analyzer = SecurityAnalyzer()
        return analyzer.report(for: items, now: now)
    }

    /// 条目里任何一个网址属于名单里的网站（含子域名，例如 accounts.google.com）
    static func supportsTwoFactor(_ item: VaultItem) -> Bool {
        item.allFields.filter { $0.kind == .url }.contains { field in
            guard let host = WebsiteIcon.host(forURL: field.value) else { return false }
            return twoFactorSites.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    /// 支持一次性验证码（TOTP，验证器 App 扫码那种）的常见网站。只收确定支持的，宁缺毋滥：不在名单里就不提示。
    /// 不收用自家验证方式的（Apple ID 的设备验证、Steam / 战网的专属验证器、Telegram 的额外密码）。
    static let twoFactorSites: Set<String> = [
        // 开发与云
        "github.com", "gitlab.com", "bitbucket.org", "gitee.com", "npmjs.com", "docker.com", "pypi.org",
        "aws.amazon.com", "amazon.com", "cloudflare.com", "digitalocean.com", "vercel.com", "heroku.com",
        "aliyun.com", "alibabacloud.com", "cloud.tencent.com", "huaweicloud.com", "jdcloud.com", "azure.com",
        "openai.com", "atlassian.com", "slack.com", "notion.so", "figma.com", "linear.app",
        // 账号与通讯
        "google.com", "microsoft.com", "live.com", "outlook.com", "dropbox.com",
        "box.com", "zoom.us", "discord.com", "facebook.com", "instagram.com", "x.com",
        "twitter.com", "linkedin.com", "reddit.com", "twitch.tv", "proton.me", "fastmail.com",
        // 支付与交易
        "paypal.com", "stripe.com", "coinbase.com", "binance.com", "okx.com", "kraken.com",
        // 其他常用
        "1password.com", "bitwarden.com", "lastpass.com", "epicgames.com",
        "nintendo.com", "playstation.com", "xbox.com", "wordpress.com", "shopify.com",
    ]
}

/// 增量的安全分析：每个条目按 `id` + `rev` 记住分析结果（弱密码、该不该有两步验证、密码的 SHA-256），
/// 没变的条目不再估算强度、不再解析网址，只有新增和改过的条目重新分析。
/// 重复使用要看全部条目，但只是按摘要分组，很便宜。缓存里不存密码明文，只存摘要；锁定时整个丢掉。
public struct SecurityAnalyzer: Sendable {
    struct Facts: Sendable {
        let rev: Int
        let weak: Bool
        let needs2FA: Bool
        /// 条目里每个不同的密码的 SHA-256（同一条目里重复的同一个密码只算一次）
        let digests: Set<Data>
        let modified: Int64
        let ignored: Set<String>
    }

    private var cache: [String: Facts] = [:]
    /// 上一次 `report` 里重新分析了几个条目（测试用）
    public private(set) var lastAnalyzedCount = 0

    public init() {}

    public mutating func report(for items: [VaultItem], now: Date = Date()) -> SecurityReport {
        var fresh: [String: Facts] = [:]
        fresh.reserveCapacity(items.count)
        var analyzed = 0
        var owners: [Data: [String]] = [:]
        var facts: [Facts] = []
        facts.reserveCapacity(items.count)
        for item in items {
            let f: Facts
            if let cached = cache[item.id], cached.rev == item.rev, cached.modified == item.modified {
                f = cached
            } else {
                f = Self.analyze(item)
                analyzed += 1
            }
            fresh[item.id] = f
            facts.append(f)
            for d in f.digests { owners[d, default: []].append(item.id) }
        }
        cache = fresh
        lastAnalyzedCount = analyzed

        let oldBefore = now.addingTimeInterval(-Double(SecurityReport.oldAfterDays) * 86_400).unixMilliseconds
        var issues: [SecurityReport.Issue] = []
        var ignored: [SecurityReport.Issue] = []
        for (item, f) in zip(items, facts) {
            func add(_ kind: SecurityReport.Kind, _ shared: [String] = []) {
                let issue = SecurityReport.Issue(kind: kind, itemId: item.id, sharedWith: shared)
                if f.ignored.contains(kind.rawValue) { ignored.append(issue) } else { issues.append(issue) }
            }
            if f.weak { add(.weak) }
            var shared = Set<String>()
            for d in f.digests { for id in owners[d] ?? [] where id != item.id { shared.insert(id) } }
            if !shared.isEmpty { add(.reused, shared.sorted()) }
            if f.needs2FA { add(.no2fa) }
            if !f.digests.isEmpty, f.modified < oldBefore { add(.old) }
        }
        return SecurityReport(issues: issues, ignored: ignored)
    }

    static func analyze(_ item: VaultItem) -> Facts {
        let passwords = item.passwords
        let weak = passwords.contains { PasswordStrength.evaluate($0).bits < PasswordStrength.weakThreshold }
        let needs2FA = item.type == .login && SecurityReport.supportsTwoFactor(item)
            && !item.allFields.contains { $0.kind == .totp && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let digests = Set(passwords.map { Data(SHA256.hash(data: Data($0.utf8))) })
        return Facts(rev: item.rev, weak: weak, needs2FA: needs2FA, digests: digests, modified: item.modified, ignored: Set(item.ignoredIssues))
    }
}

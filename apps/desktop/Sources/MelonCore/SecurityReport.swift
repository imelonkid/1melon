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

    public let issues: [Issue]
    /// 0…100，越高越好
    public let score: Int

    public var itemsWithIssues: Set<String> { Set(issues.map(\.itemId)) }

    public func count(_ kind: Kind) -> Int { issues.filter { $0.kind == kind }.count }

    public func issues(for itemId: String) -> [Issue] { issues.filter { $0.itemId == itemId }.sorted { $0.kind < $1.kind } }

    public static let oldAfterDays = 365

    /// 分析一组没有被删除的条目（通常是全部保险库的 activeItems）
    public static func analyze(_ items: [VaultItem], now: Date = Date()) -> SecurityReport {
        var issues: [Issue] = []

        // 重复使用：按密码分组（同一条目里重复的同一个密码只算一次）
        var owners: [String: [String]] = [:]
        for item in items {
            for pw in Set(item.passwords) { owners[pw, default: []].append(item.id) }
        }

        let oldBefore = now.addingTimeInterval(-Double(oldAfterDays) * 86_400).unixMilliseconds
        for item in items {
            let passwords = item.passwords
            if passwords.contains(where: { PasswordStrength.evaluate($0).bits < PasswordStrength.weakThreshold }) {
                issues.append(Issue(kind: .weak, itemId: item.id, sharedWith: []))
            }
            let shared = Set(passwords.flatMap { owners[$0] ?? [] }).subtracting([item.id])
            if !shared.isEmpty {
                issues.append(Issue(kind: .reused, itemId: item.id, sharedWith: shared.sorted()))
            }
            if item.type == .login, supportsTwoFactor(item), !item.allFields.contains(where: { $0.kind == .totp && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }) {
                issues.append(Issue(kind: .no2fa, itemId: item.id, sharedWith: []))
            }
            if !passwords.isEmpty, item.modified < oldBefore {
                issues.append(Issue(kind: .old, itemId: item.id, sharedWith: []))
            }
        }

        let penalty = issues.reduce(0) { $0 + $1.kind.penalty }
        return SecurityReport(issues: issues, score: max(0, min(100, 100 - penalty)))
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

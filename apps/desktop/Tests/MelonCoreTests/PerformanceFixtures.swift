import Foundation
@testable import MelonCore

/// 性能测试和手动复现用的虚构保险库：登录为主，混着弱密码、重复密码、带验证码的、
/// 超过一年没改的、带附件的，以及各种其他类型。数据全是编的，按序号确定，每次生成都一样。
enum PerformanceFixtures {
    static let sites = [
        "github.com", "gitlab.com", "google.com", "aliyun.com", "cloud.tencent.com", "taobao.com", "jd.com", "bilibili.com",
        "zhihu.com", "douban.com", "example.cn", "bbs.example.org", "mail.example.net", "shop.example.com", "notion.so",
    ]
    static let weakPasswords = ["123456", "admin123", "password", "qwerty12", "11111111"]

    /// `count` 个条目；`iconData` 不为空时登录条目都带这个网站图标
    static func items(_ count: Int, now: Date = Date(), withIcons iconData: Data? = nil) -> [VaultItem] {
        let nowMs = now.unixMilliseconds
        return (0..<count).map { i in
            let types: [ItemType] = [.login, .login, .login, .login, .login, .login, .card, .note, .wifi, .api]
            let type = types[i % types.count]
            var it = VaultItem.fromTemplate(type, title: "演示条目 \(i)", now: nowMs)
            let daysAgo = Double((i * 37) % 900)
            it.modified = now.addingTimeInterval(-daysAgo * 86_400).unixMilliseconds
            it.created = it.modified
            it.favorite = i % 29 == 0
            it.tags = i % 7 == 0 ? ["工作"] : i % 11 == 0 ? ["家庭", "共享"] : []
            switch type {
            case .login:
                it.sections[0].fields[0].value = "user\(i)@example.com"
                it.sections[0].fields[1].value = i % 4 == 0 ? weakPasswords[i % weakPasswords.count]
                    : i % 9 == 0 ? "Shared-Demo-Pass-\(i % 3)" : "Xk7#q\(i)!Lm9@Tz4Kp2$"
                it.sections[0].fields[2].value = "https://" + sites[i % sites.count] + "/login"
                if i % 5 == 0 { it.sections[1].fields[0].value = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" }
                it.iconData = iconData
                it.iconHost = iconData == nil ? nil : sites[i % sites.count]
            case .card:
                it.sections[0].fields[1].value = "6222 0000 0000 \(1000 + i)"
            case .wifi:
                it.sections[0].fields[0].value = "Demo-WiFi-\(i)"
                it.sections[0].fields[1].value = i % 3 == 0 ? "12345678" : "Wifi-Demo-\(i)-pass!"
            case .api:
                it.sections[0].fields[0].value = "演示服务 \(i)"
            default:
                it.notes = "演示笔记 \(i)\n第二行"
            }
            return it
        }
    }

    /// 给条目加一个附件字段（引用 `ref`）
    static func attach(_ ref: AttachmentRef, to item: inout VaultItem) {
        var field = ItemField(label: "附件", kind: .file)
        field.attach(ref, name: "演示附件.txt")
        item.sections.append(ItemSection(title: "附件", fields: [field]))
    }
}

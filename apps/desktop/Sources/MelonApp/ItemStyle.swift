import AppKit
import CoreImage
import MelonCore
import SwiftUI

/// 条目类型在界面上的名字和图标（SF Symbols）。
extension ItemType {
    var label: String {
        switch self {
        case .login: "登录"
        case .card: "银行卡"
        case .note: "安全笔记"
        case .identity: "身份信息"
        case .ssh: "SSH 密钥"
        case .api: "API Token"
        case .wifi: "Wi-Fi"
        default: rawValue
        }
    }

    /// 类型选择窗口的搜索词（除了名称以外）
    var keywords: [String] {
        switch self {
        case .login: ["密码", "账号", "网站", "login", "password"]
        case .card: ["信用卡", "储蓄卡", "银行", "卡号", "card", "credit"]
        case .note: ["笔记", "备忘", "恢复码", "note"]
        case .identity: ["证件", "身份证", "护照", "identity", "passport"]
        case .ssh: ["服务器", "主机", "私钥", "server", "key"]
        case .api: ["token", "key", "密钥", "接口", "api"]
        case .wifi: ["无线", "网络", "wifi", "wlan"]
        default: []
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || ([label, rawValue] + keywords).contains { $0.lowercased().contains(q) }
    }

    var symbol: String {
        switch self {
        case .login: "key"
        case .card: "creditcard"
        case .note: "note.text"
        case .identity: "person.text.rectangle"
        case .ssh: "terminal"
        case .api: "chevron.left.forwardslash.chevron.right"
        case .wifi: "wifi"
        default: "questionmark.square.dashed"
        }
    }
}

/// 条目图标：中性灰圆角方块。有网站图标放网站图标（去色，和类型图标同一个灰调）；登录类没有图标时放标题首字母；其余放类型图标。
struct ItemIcon: View {
    let type: ItemType
    var size: CGFloat = 36
    /// 网站图标（PNG）
    var iconData: Data? = nil
    /// 标题：登录类没有网站图标时取首字母
    var title: String = ""

    private var initial: String? {
        guard type == .login, let ch = title.trimmingCharacters(in: .whitespaces).first else { return nil }
        return String(ch).uppercased()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(Theme.tile)
            .frame(width: size, height: size)
            .overlay {
                if let iconData, let image = ImageCache.shared.websiteIcon(iconData) {
                    // 网站图标保留原来的颜色，只是调淡（像水彩），和灰色底块放在一起不扎眼；处理好的图缓存起来，重绘不再解码
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(width: size * 0.6, height: size * 0.6)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
                        .opacity(0.8)
                } else if let initial {
                    Text(initial).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Theme.tileFg)
                } else {
                    Image(systemName: type.symbol).font(.system(size: size * 0.46)).foregroundStyle(Theme.tileFg)
                }
            }
    }
}

func formatDate(_ ms: Int64) -> String {
    Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .numeric, time: .omitted)
}

/// 字段类型在界面上的名字和图标（「添加字段」菜单、新字段的默认名称）。
extension FieldKind {
    var label: String {
        switch self {
        case .text: "文本"
        case .password: "密码"
        case .secret: "隐藏文本"
        case .url: "网址"
        case .email: "邮箱"
        case .phone: "电话"
        case .date: "日期"
        case .monthYear: "年月"
        case .totp: "一次性验证码"
        case .multiline: "多行文本"
        case .file: "文件附件"
        default: rawValue
        }
    }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .password: "key"
        case .secret: "eye.slash"
        case .url: "link"
        case .email: "envelope"
        case .phone: "phone"
        case .date: "calendar"
        case .monthYear: "calendar.badge.clock"
        case .totp: "clock.arrow.circlepath"
        case .multiline: "text.alignleft"
        case .file: "paperclip"
        default: "questionmark"
        }
    }

    var placeholder: String {
        switch self {
        case .totp: "粘贴密钥或 otpauth:// 链接"
        case .url: "example.com"
        case .email: "name@example.com"
        case .phone: "+86 138 0000 0000"
        case .date: "1990-05-21"
        case .monthYear: "2029-08"
        default: ""
        }
    }

    /// 输入是否符合格式；不符合时编辑器在下面给一行提示（不阻止保存）
    func formatHint(for value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        switch self {
        case .totp: return (try? TOTP.parse(v)) == nil ? "格式不对：要 Base32 密钥或 otpauth:// 链接" : nil
        case .date: return v.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil ? "格式：年-月-日，例如 1990-05-21" : nil
        case .monthYear: return v.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) == nil ? "格式：年-月，例如 2029-08" : nil
        case .email: return v.contains("@") ? nil : "邮箱里要有 @"
        default: return nil
        }
    }
}

/// 保险库图标：spec §5.1 的固定集合映射成 SF Symbols。颜色字段照常保存，但界面不显示（设计稿只有一个强调色）。
enum VaultStyle {
    static func symbol(_ icon: String) -> String {
        switch icon {
        case "person": "person"
        case "briefcase": "briefcase"
        case "house": "house"
        case "heart": "heart"
        case "star": "star"
        case "folder": "folder"
        case "lock": "lock"
        case "server": "server.rack"
        case "cart": "cart"
        case "gamecontroller": "gamecontroller"
        default: "lock"
        }
    }
}

/// 保险库徽标：和条目图标一样的中性灰方块 + 图标（不用颜色，设计稿只有一个强调色）。
struct VaultBadge: View {
    let meta: VaultMeta
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32)
            .fill(Theme.tile)
            .frame(width: size, height: size)
            .overlay(Image(systemName: VaultStyle.symbol(meta.icon)).font(.system(size: size * 0.52, weight: .medium)).foregroundStyle(Theme.tileFg))
    }
}

/// 网站图标解码、调色后的缓存：列表每次重绘都要画几十个图标，不能每次都解 PNG。
/// 图标来自解锁后的条目，锁定时清空（`VaultSession.lock` → 重建索引时）
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSData, NSImage>()
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private init() { cache.countLimit = 2000 }

    func websiteIcon(_ data: Data) -> NSImage? {
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = Self.watercolor(data, context: context) ?? NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func removeAll() { cache.removeAllObjects() }

    /// 水彩感：饱和度降到一半、对比压低、整体提亮一点
    private static func watercolor(_ data: Data, context: CIContext) -> NSImage? {
        guard let input = CIImage(data: data), let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0.5, forKey: kCIInputSaturationKey)
        filter.setValue(0.82, forKey: kCIInputContrastKey)
        filter.setValue(0.06, forKey: kCIInputBrightnessKey)
        guard let output = filter.outputImage, let cg = context.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: input.extent.width, height: input.extent.height))
    }
}

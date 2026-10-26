import MelonCore
import SwiftUI

/// 条目类型在界面上的名字和图标（设计稿用 Phosphor 图标，这里换成对应的 SF Symbols）。
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

/// 条目图标：圆角方块里放类型图标（设计稿列表行和详情头部）。
struct ItemIcon: View {
    let type: ItemType
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27)
            .fill(.background)
            .overlay(RoundedRectangle(cornerRadius: size * 0.27).strokeBorder(.separator, lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay(Image(systemName: type.symbol).font(.system(size: size * 0.5)).foregroundStyle(.secondary))
    }
}

func formatDate(_ ms: Int64) -> String {
    Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .numeric, time: .omitted)
}

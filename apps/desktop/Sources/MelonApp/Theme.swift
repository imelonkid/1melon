import AppKit
import SwiftUI

/// 设计稿 docs/ui/1Melon.html 里的颜色变量，浅色（暖白）/ 深色（纯黑）各一套。
/// 只有一个强调色（橙）：选中、主按钮、一次性密码、链接、成功和提醒都用它；只有错误和删除用红色。
enum Theme {
    static let accent = dynamic(light: 0xF26A1B, dark: 0xFF7A2B)
    /// 选中项、标签页、悬停的淡橙底
    static let accentSoft = dynamic(light: 0xFFF1E6, dark: 0xFF7A2B, darkAlpha: 0.16)
    /// 浅底上的强调文字（比 accent 深一点，读得清）
    static let accentText = dynamic(light: 0xE2560A, dark: 0xFF9A5C)
    static let danger = dynamic(light: 0xD9443B, dark: 0xF07A70)
    /// 提醒、成功都用强调色，不另加颜色
    static let warn = accentText
    static let ok = accent
    /// 密码里的数字用强调色，符号用次要文字色加粗（见 PasswordText）
    static let digit = accentText
    static let symbol = text2

    /// 侧栏
    static let side = dynamic(light: 0xF7F6F4, dark: 0x111111)
    /// 条目列表
    static let list = dynamic(light: 0xFCFBFA, dark: 0x0A0A0A)
    /// 详情、解锁页、首次启动
    static let bg = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// 字段卡片、弹窗
    static let card = dynamic(light: 0xFFFFFF, dark: 0x141414)
    /// 搜索框、输入框
    static let input = dynamic(light: 0xF6F4F2, dark: 0x161616)
    /// 条目 / 保险库图标的底和图标
    static let tile = dynamic(light: 0xF1EFEC, dark: 0x1F1F1F)
    static let tileFg = dynamic(light: 0x57524E, dark: 0xD6D6D6)

    static let text = dynamic(light: 0x1F1D1B, dark: 0xF5F5F5)
    static let text2 = dynamic(light: 0x6F6A66, dark: 0xA3A3A3)
    static let text3 = dynamic(light: 0xA7A19C, dark: 0x666666)
    /// 分隔线 / 卡片描边
    static let line = dynamic(light: 0x28190A, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let line2 = dynamic(light: 0x28190A, lightAlpha: 0.14, dark: 0xFFFFFF, darkAlpha: 0.13)
    static let hover = dynamic(light: 0x28190A, lightAlpha: 0.045, dark: 0xFFFFFF, darkAlpha: 0.06)
    /// 插画的浅色块和描线
    static let illus = dynamic(light: 0xF3F1EE, dark: 0x161616)
    static let illus2 = dynamic(light: 0xE2DDD8, dark: 0x2C2C2C)

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

/// 设计稿里的字号和间距。
enum Typo {
    /// 条目标题
    static let title = Font.system(size: 24, weight: .bold)
    /// 分组标题（字段卡片上方的小字）
    static let sectionTitle = Font.system(size: 12, weight: .semibold)
    /// 字段名称（左列，次要文字色）
    static let fieldLabel = Font.system(size: 13)
    /// 字段的值
    static let fieldValue = Font.system(size: 14.5)
    static let fieldValueMono = Font.system(size: 14, design: .monospaced)
    /// 字段名称那一列的宽度
    static let labelWidth: CGFloat = 96
    /// 一行字段的上下留白
    static let rowVerticalPadding: CGFloat = 12
}

/// 设计稿的圆角卡片：卡片底色 + 细描边，圆角 14。
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line2, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// 卡片里两行之间的细线
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5)
    }
}

/// 字段卡片上方的分组标题
struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Typo.sectionTitle).foregroundStyle(Theme.text3)
            .padding(.leading, 2).padding(.bottom, 8)
    }
}

/// 灰色小胶囊：详情页的类型、保险库，标签
struct Pill<Label: View>: View {
    @ViewBuilder let label: Label

    var body: some View {
        HStack(spacing: 4) { label }
            .font(.system(size: 12))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 9).padding(.vertical, 2.5)
            .background(Capsule().fill(Theme.hover))
    }
}

/// 设计稿的按钮：普通是卡片底 + 细描边；`prominent` 是橙底白字（编辑、保存）。高 32、圆角 9。
struct PaneButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.text))
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(prominent ? Theme.accent : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(prominent ? Color.clear : Theme.line2, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// 只有图标的小按钮（字段行右边的复制、显示，详情顶部的收藏、更多）。`hot` 是淡橙底，给最常用的那个（复制密码）。
struct IconButtonStyle: ButtonStyle {
    var hot = false
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5))
            .foregroundStyle(hot ? Theme.accentText : Theme.text3)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 8).fill(hot ? Theme.accentSoft : configuration.isPressed ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
    }
}

/// 设计稿的输入框：浅灰底、细描边，聚焦时描边变橙。
struct BoxFieldStyle: ViewModifier {
    var focused = false
    var height: CGFloat? = 34
    var radius: CGFloat = 9

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(focused ? Theme.accent : Theme.line2, lineWidth: focused ? 1 : 0.5))
            .background(RoundedRectangle(cornerRadius: radius + 3).fill(focused ? Theme.accentSoft : Color.clear).padding(-3))
    }
}

extension View {
    func boxField(focused: Bool = false, height: CGFloat? = 34, radius: CGFloat = 9) -> some View {
        modifier(BoxFieldStyle(focused: focused, height: height, radius: radius))
    }
}

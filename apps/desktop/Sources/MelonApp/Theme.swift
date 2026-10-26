import AppKit
import SwiftUI

/// 设计稿 docs/ui/Lockbox.dc.html 里的颜色变量（oklch 近似换算成 sRGB），浅色 / 深色各一套。
enum Theme {
    static let accent = dynamic(light: 0x2570CC, dark: 0x4C8DE0)
    static let danger = dynamic(light: 0xC8403F, dark: 0xF07A70)
    static let warn = dynamic(light: 0xC0802A, dark: 0xE8B65A)
    static let ok = dynamic(light: 0x2C9461, dark: 0x5CC48C)
    /// 密码里的数字
    static let digit = dynamic(light: 0x1E62C4, dark: 0x78A9EC)
    /// 密码里的符号
    static let symbol = dynamic(light: 0xC2562E, dark: 0xE9976A)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

/// 条目详情和编辑共用的字号与颜色：名称用强调色、值用正文色，靠颜色而不是变灰来分层级。
enum Typo {
    /// 条目标题
    static let title = Font.system(size: 22, weight: .bold)
    /// 标题下面的类型、保险库
    static let meta = Font.system(size: 12.5)
    /// 分组标题
    static let sectionTitle = Font.system(size: 12, weight: .semibold)
    /// 字段名称（显示成强调色）
    static let fieldLabel = Font.system(size: 13, weight: .medium)
    /// 字段的值
    static let fieldValue = Font.system(size: 15)
    static let fieldValueMono = Font.system(size: 15, design: .monospaced)
    /// 详情 / 编辑内容离窗口顶边的距离（内容延伸进了已清空的工具栏那一条）
    static let detailTopPadding: CGFloat = 26
    /// 一行字段的上下留白
    static let rowVerticalPadding: CGFloat = 12
}

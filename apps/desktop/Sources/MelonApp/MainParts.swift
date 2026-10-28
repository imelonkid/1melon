import MelonCore
import SwiftUI

// 主界面用到的小部件（设计稿「主界面」「空保险库」）

/// 两栏之间的竖线
struct VLine: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 0.5)
    }
}

/// 侧栏的一行：图标 + 名称 + 数量。选中是淡橙底橙字，数量放进橙色小胶囊。
struct SidebarRow: View {
    var symbol: String? = nil
    let title: String
    var count: Int? = nil
    let selected: Bool
    /// 数量用强调色（安全报告有问题时）
    var highlightCount = false
    /// 右边的「›」：点了打开弹窗而不是换范围（密码生成器）
    var chevron = false
    /// 代替图标的徽标（保险库）
    var badge: AnyView? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let badge {
                    badge
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 15))
                        .foregroundStyle(selected ? Theme.accentText : Theme.text2)
                        .frame(width: 22)
                }
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accentText : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    if selected {
                        Text("\(count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 8).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.16)))
                    } else {
                        Text("\(count)").font(.system(size: 12.5, weight: highlightCount && count > 0 ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(highlightCount && count > 0 ? Theme.accentText : Theme.text2)
                    }
                }
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 11).fill(selected ? Theme.accentSoft : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 条目列表的一行：图标 + 标题 / 副标题，收藏的右边一颗橙色星。选中是淡橙底。
struct ItemRow: View {
    let title: String
    let subtitle: String
    let type: ItemType
    let favorite: Bool
    let selected: Bool
    var iconData: Data? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ItemIcon(type: type, size: 36, iconData: iconData, title: title)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if favorite {
                Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.accentSoft : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// 列表上方「全部类型」「按修改时间」两个菜单的样子：小图标 + 文字 + ⌄
struct MenuLabel: View {
    let symbol: String
    let text: String
    var active = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12))
            Text(text).font(.system(size: 12.5))
            Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold))
        }
        .foregroundStyle(active ? Theme.accentText : Theme.text2)
        .contentShape(Rectangle())
    }
}

/// 空状态：插画 + 标题 + 说明。说明里的「＋」画成淡橙小方块。
struct EmptyState: View {
    let illustration: AnyView
    let title: String
    let message: String
    var large = false

    var body: some View {
        VStack(spacing: 0) {
            illustration
            Text(title).font(.system(size: large ? 22 : 17, weight: .semibold)).foregroundStyle(Theme.text)
                .padding(.top, 18).padding(.bottom, 6)
            message.split(separator: "\n").enumerated().reduce(Text("")) { acc, line in
                let (i, s) = line
                return (i > 0 ? acc + Text("\n") : acc) + styled(String(s))
            }
            .font(.system(size: 13)).foregroundStyle(Theme.text2)
            .multilineTextAlignment(.center).lineSpacing(4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「＋」用强调色
    private func styled(_ s: String) -> Text {
        let parts = s.components(separatedBy: "＋")
        return parts.enumerated().reduce(Text("")) { acc, p in
            p.offset == 0 ? acc + Text(p.element) : acc + Text(" ＋ ").foregroundColor(Theme.accentText).bold() + Text(p.element)
        }
    }
}

/// 四格强度条（详情页密码下面）：弱是红色，其余是强调色。`showsLabel` 时后面跟「强 · 85 bits」
struct StrengthMeter: View {
    let strength: PasswordStrength
    var showsLabel = false

    private var filled: Int {
        switch strength.level {
        case .weak: 1
        case .fair: 2
        case .strong: 3
        case .veryStrong: 4
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(i < filled ? color : Theme.line2)
                    .frame(width: 16, height: 4)
            }
            if showsLabel {
                Text("\(label) · \(strength.bits) bits").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    .padding(.leading, 6)
            }
        }
        .help("强度 \(strength.bits) bits")
    }

    private var color: Color { strength.level == .weak ? Theme.danger : Theme.accent }

    private var label: String {
        switch strength.level {
        case .weak: "弱"
        case .fair: "一般"
        case .strong: "强"
        case .veryStrong: "极强"
        }
    }
}

/// 四角星（插画里的点缀）
private struct Sparkle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), w = r.width / 2, h = r.height / 2, k: CGFloat = 0.28
        p.move(to: CGPoint(x: c.x, y: c.y - h))
        p.addLine(to: CGPoint(x: c.x + w * k, y: c.y - h * k))
        p.addLine(to: CGPoint(x: c.x + w, y: c.y))
        p.addLine(to: CGPoint(x: c.x + w * k, y: c.y + h * k))
        p.addLine(to: CGPoint(x: c.x, y: c.y + h))
        p.addLine(to: CGPoint(x: c.x - w * k, y: c.y + h * k))
        p.addLine(to: CGPoint(x: c.x - w, y: c.y))
        p.addLine(to: CGPoint(x: c.x - w * k, y: c.y - h * k))
        p.closeSubpath()
        return p
    }
}

/// 空保险库插画：一张纸 + 右下角橙色锁徽章 + 两颗星
struct EmptyVaultIllustration: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Sparkle().fill(Theme.accent.opacity(0.85)).frame(width: 22, height: 22).offset(x: 28, y: 18)
            Sparkle().stroke(Theme.text3, lineWidth: 1.2).frame(width: 14, height: 14).offset(x: 146, y: 46)
            RoundedRectangle(cornerRadius: 12).fill(Theme.illus)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.illus2, lineWidth: 2))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        Capsule().fill(Theme.illus2).frame(width: 44, height: 6)
                        Capsule().fill(Theme.illus2).frame(width: 36, height: 6)
                        Capsule().fill(Theme.illus2).frame(width: 40, height: 6)
                    }
                    .padding(.top, 20).padding(.leading, 16)
                }
                .frame(width: 76, height: 100)
                .offset(x: 58, y: 22)
            Circle().fill(Theme.list).frame(width: 48, height: 48).offset(x: 106, y: 94)
            Circle().fill(Theme.accent).frame(width: 38, height: 38)
                .overlay(Image(systemName: "lock").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                .offset(x: 111, y: 99)
        }
        .frame(width: 190, height: 150, alignment: .topLeading)
    }
}

/// 未选择条目插画：一张斜放的卡片 + 一把锁 + 三颗星
struct NoSelectionIllustration: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Sparkle().fill(Theme.accent.opacity(0.85)).frame(width: 28, height: 28).offset(x: 56, y: 12)
            Sparkle().stroke(Theme.text3, lineWidth: 1.2).frame(width: 17, height: 17).offset(x: 254, y: 44)
            Sparkle().stroke(Theme.text3, lineWidth: 1.2).frame(width: 14, height: 14).offset(x: 14, y: 146)
            RoundedRectangle(cornerRadius: 16).fill(Theme.illus)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.illus2, lineWidth: 2))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 14) {
                            Circle().fill(Theme.bg).overlay(Circle().strokeBorder(Theme.illus2, lineWidth: 2))
                                .overlay(Image(systemName: "person").font(.system(size: 16)).foregroundStyle(Theme.text3))
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 8) {
                                Capsule().fill(Theme.illus2).frame(width: 80, height: 9)
                                Capsule().fill(Theme.illus2).frame(width: 54, height: 7)
                            }
                        }
                        Capsule().fill(Theme.illus2).frame(width: 140, height: 7).padding(.top, 22)
                        Capsule().fill(Theme.illus2).frame(width: 100, height: 7).padding(.top, 9)
                    }
                    .padding(.top, 22).padding(.leading, 24)
                }
                .frame(width: 190, height: 120)
                .rotationEffect(.degrees(-5))
                .offset(x: 48, y: 40)
            // 锁
            Path { p in
                p.move(to: CGPoint(x: 0, y: 26))
                p.addLine(to: CGPoint(x: 0, y: 21))
                p.addArc(center: CGPoint(x: 21, y: 21), radius: 21, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                p.addLine(to: CGPoint(x: 42, y: 26))
            }
            .stroke(Theme.illus2, lineWidth: 6)
            .frame(width: 42, height: 26)
            .offset(x: 210, y: 86)
            RoundedRectangle(cornerRadius: 14).fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.illus2, lineWidth: 2))
                .overlay {
                    VStack(spacing: 0) {
                        Circle().fill(Theme.accent).frame(width: 14, height: 14)
                        Capsule().fill(Theme.accent).frame(width: 4, height: 14).offset(y: -3)
                    }
                    .offset(y: 4)
                }
                .shadow(color: Theme.accent.opacity(0.22), radius: 10, y: 8)
                .frame(width: 70, height: 80)
                .offset(x: 196, y: 112)
        }
        .frame(width: 300, height: 200, alignment: .topLeading)
    }
}

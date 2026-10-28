import AppKit
import MelonCore
import SwiftUI

/// 条目详情的查看态正文（标题以下）：字段卡片、备注、标签、时间。标题行在 `ItemPane` 里，查看和编辑共用。
struct ItemViewBody: View {
    let item: VaultItem
    let toast: (Toast) -> Void

    @State private var revealed: Set<String> = []

    /// 有内容的分组（空字段不显示，整个分组都空就不显示）
    private var sections: [ItemSection] {
        item.sections.compactMap { s in
            var s = s
            s.fields = s.fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            return s.fields.isEmpty ? nil : s
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { si, section in
                VStack(alignment: .leading, spacing: 0) {
                    if !section.title.isEmpty { SectionHeader(section.title) }
                    Card {
                        ForEach(Array(section.fields.enumerated()), id: \.element.id) { i, field in
                            if i > 0 { RowDivider() }
                            FieldRow(field: field, revealed: revealed.contains(field.id),
                                     toggle: { revealed.formSymmetricDifference([field.id]) },
                                     copy: { copy(field) })
                        }
                    }
                }
                .padding(.top, si == 0 ? 0 : 16)
            }

            if !item.notes.isEmpty || !item.tags.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(item.type == .note ? "内容与标签" : "备注与标签")
                    Card {
                        if !item.notes.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(item.type == .note ? "内容" : "备注").font(Typo.fieldLabel).foregroundStyle(Theme.text2)
                                    .frame(width: Typo.labelWidth, alignment: .leading)
                                Text(item.notes)
                                    .font(item.type == .note ? .system(size: 13.5, design: .monospaced) : Typo.fieldValue)
                                    .foregroundStyle(Theme.text)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button { copyText(item.notes, label: item.type == .note ? "笔记内容" : "备注", secret: item.type == .note) } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(IconButtonStyle())
                                .help("复制")
                            }
                            .padding(.horizontal, 16).padding(.vertical, Typo.rowVerticalPadding)
                        }
                        if !item.notes.isEmpty && !item.tags.isEmpty { RowDivider() }
                        if !item.tags.isEmpty {
                            HStack(alignment: .center, spacing: 12) {
                                Text("标签").font(Typo.fieldLabel).foregroundStyle(Theme.text2)
                                    .frame(width: Typo.labelWidth, alignment: .leading)
                                FlowLayout(spacing: 6) {
                                    ForEach(item.tags, id: \.self) { TagChip(text: $0) }
                                }
                            }
                            .padding(.horizontal, 16).frame(minHeight: 50)
                        }
                    }
                }
                .padding(.top, 16)
            }

            Text("修改于 \(formatDate(item.modified)) · 创建于 \(formatDate(item.created))")
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                .padding(.top, 18)
        }
    }

    private func copy(_ field: ItemField) {
        if field.kind == .totp, let totp = try? TOTP.parse(field.value) {
            copyText(totp.code(), label: "验证码", secret: true)
        } else {
            copyText(field.value, label: field.label, secret: field.kind.isConcealed)
        }
    }

    private func copyText(_ text: String, label: String, secret: Bool) {
        if secret {
            Clipboard.copySecret(text)
            toast(Toast(message: "已复制\(label)", detail: Clipboard.clearHint))
        } else {
            Clipboard.copy(text)
            toast(Toast(message: "已复制\(label)"))
        }
    }
}

/// 一个字段：名称 + 值（按类型显示）。**点整行任何位置都复制**；右侧只留「显示」和「打开」。
struct FieldRow: View {
    let field: ItemField
    let revealed: Bool
    let toggle: () -> Void
    let copy: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(field.label.isEmpty ? field.kind.label : field.label)
                .font(Typo.fieldLabel).foregroundStyle(Theme.text2).lineLimit(2)
                .frame(width: Typo.labelWidth, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                if field.kind.isConcealed {
                    Button(action: toggle) { Image(systemName: revealed ? "eye.slash" : "eye") }
                        .buttonStyle(IconButtonStyle())
                        .help(revealed ? "隐藏" : "显示")
                }
                if let url = openableURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: field.kind == .email ? "envelope" : field.kind == .phone ? "phone" : "globe")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(field.kind == .email ? "写邮件" : field.kind == .phone ? "拨打" : "打开网站")
                }
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle(hot: field.kind == .password))
                    .help("复制")
            }
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 10)
        .frame(minHeight: 50)
        .background(hovering ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .onHover { hovering = $0 }
        .help("点击复制")
    }

    @ViewBuilder private var value: some View {
        switch field.kind {
        case .totp:
            TOTPValue(secret: field.value)
        case .multiline:
            Text(revealed ? field.value : "••••••••••••••••••••••••••••••••••••\n••••••••••••••••••••••••••••••")
                .font(.system(size: 12.5, design: .monospaced)).lineSpacing(2).foregroundStyle(Theme.text)
        case .password, .secret:
            HStack(spacing: 12) {
                if revealed {
                    PasswordText(value: field.value, size: 14)
                } else {
                    Text("••••••••••••").font(Typo.fieldValue).kerning(1.5).foregroundStyle(Theme.text)
                }
                if field.kind == .password {
                    StrengthMeter(strength: PasswordStrength.evaluate(field.value))
                }
            }
        case .url:
            Text(field.value).font(Typo.fieldValue).foregroundStyle(Theme.accentText).lineLimit(1)
        case .email:
            Text(field.value).font(Typo.fieldValue).foregroundStyle(Theme.text)
        case .date, .monthYear:
            Text(formattedDate).font(Typo.fieldValue).foregroundStyle(Theme.text)
        default:
            Text(field.value).font(field.monospace ? Typo.fieldValueMono : Typo.fieldValue).foregroundStyle(Theme.text)
        }
    }

    /// 日期存成 `YYYY-MM-DD` / `YYYY-MM`，显示成本地习惯的写法；格式不对就原样显示
    private var formattedDate: String {
        let parts = field.value.split(separator: "-").compactMap { Int($0) }
        if field.kind == .monthYear, parts.count == 2 { return String(format: "%02d / %02d", parts[1], parts[0] % 100) }
        if field.kind == .date, parts.count == 3 { return "\(parts[0]) 年 \(parts[1]) 月 \(parts[2]) 日" }
        return field.value
    }

    /// 右侧「打开」按钮：网址开浏览器、邮箱开邮件、电话开拨号
    private var openableURL: URL? {
        let v = field.value.trimmingCharacters(in: .whitespaces)
        switch field.kind {
        case .url: return webURL(v)
        case .email: return v.contains("@") ? URL(string: "mailto:" + v) : nil
        case .phone:
            let digits = v.filter { $0.isNumber || $0 == "+" }
            return digits.count >= 3 ? URL(string: "tel:" + digits) : nil
        default: return nil
        }
    }

    /// 只打开 http / https；没写协议的按 https。
    private func webURL(_ s: String) -> URL? {
        let text = s.trimmingCharacters(in: .whitespaces)
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}

/// 当前验证码（强调色）+ 倒计时圆环；最后 5 秒变红。
struct TOTPValue: View {
    let secret: String

    var body: some View {
        if let totp = try? TOTP.parse(secret) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let code = totp.code(at: ctx.date)
                let left = totp.secondsRemaining(at: ctx.date)
                let color = left <= 5 ? Theme.danger : Theme.accent
                HStack(spacing: 10) {
                    Text(code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code)
                        .font(.system(size: 19, weight: .semibold, design: .monospaced)).kerning(2)
                        .foregroundStyle(left <= 5 ? Theme.danger : Theme.accentText)
                    ZStack {
                        Circle().stroke(Theme.line2, lineWidth: 2.5)
                        Circle().trim(from: 0, to: CGFloat(left) / CGFloat(totp.period))
                            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 18, height: 18)
                    Text("\(left) 秒").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
        } else {
            Text("两步验证密钥格式不对").font(.system(size: 12)).foregroundStyle(Theme.danger)
        }
    }
}

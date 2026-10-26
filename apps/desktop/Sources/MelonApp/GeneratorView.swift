import MelonCore
import SwiftUI

/// 密码生成器（设计稿「密码生成器」弹层）：随机 / 易记 / PIN。易记模式用 EFF 长词表（7776 词）。
/// `onUse` 不为空时（编辑条目里点「生成」）主按钮是「使用此密码」，否则是「复制」。
struct GeneratorView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case random = "随机", memorable = "易记", pin = "PIN"
        var id: Self { self }
    }

    @State private var mode: Mode = .random
    @State private var options = PasswordGenerator.RandomOptions()
    @State private var pinLength = 6
    // 默认 5 个词：加一个数字约 73 bits（「强」）；4 个词只有约 60 bits（「一般」）
    @State private var words = 5
    @State private var capitalize = true
    @State private var insertNumber = true
    @State private var value = ""
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var onUse: ((String) -> Void)? = nil
    /// 作为独立弹层打开时显示「完成」按钮
    var inSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("密码生成器").font(.system(size: 15, weight: .semibold))

            HStack(spacing: 10) {
                PasswordText(value: value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Button { regenerate() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("重新生成")
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
            .padding(.top, 14)

            StrengthBar(strength: strength).padding(.top, 10)

            Form {
                Picker("类型", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .random:
                    LabeledContent("长度") {
                        Slider(value: intBinding($options.length), in: range(PasswordGenerator.lengthRange), step: 1)
                            .frame(width: 200)
                        Text("\(options.length)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    }
                    Toggle("包含数字", isOn: $options.includeDigits)
                    Toggle("包含符号", isOn: $options.includeSymbols)
                    Toggle("排除易混淆字符（0 O 1 l I）", isOn: $options.excludeAmbiguous)
                case .memorable:
                    LabeledContent("单词数") {
                        Slider(value: intBinding($words), in: range(PasswordGenerator.wordsRange), step: 1)
                            .frame(width: 200)
                        Text("\(words)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    }
                    Toggle("首字母大写", isOn: $capitalize)
                    Toggle("插入一个数字", isOn: $insertNumber)
                case .pin:
                    LabeledContent("长度") {
                        Slider(value: intBinding($pinLength), in: range(PasswordGenerator.pinRange), step: 1)
                            .frame(width: 200)
                        Text("\(pinLength)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    }
                }
            }
            .toggleStyle(.switch)
            .padding(.top, 18)

            HStack {
                if copied {
                    Label(Clipboard.clearHint.isEmpty ? "已复制" : "已复制，\(Clipboard.clearHint)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.ok)
                }
                Spacer()
                if inSheet {
                    Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if let onUse {
                    Button("使用此密码") { onUse(value) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                } else {
                    Button("复制") { copy() }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            }
            .padding(.top, 16)
        }
        .padding(22)
        .onAppear(perform: regenerate)
        .onChange(of: options) { regenerate() }
        .onChange(of: pinLength) { regenerate() }
        .onChange(of: words) { regenerate() }
        .onChange(of: capitalize) { regenerate() }
        .onChange(of: insertNumber) { regenerate() }
        .onChange(of: mode) { regenerate() }
    }

    private func regenerate() {
        switch mode {
        case .random: value = PasswordGenerator.random(options)
        case .memorable: value = PasswordGenerator.memorable(words: words, capitalize: capitalize, insertNumber: insertNumber)
        case .pin: value = PasswordGenerator.pin(length: pinLength)
        }
        copied = false
    }

    /// 易记密码按真实熵显示（按字符估算会把一串单词算得过强）；其余按字符估算
    private var strength: PasswordStrength {
        mode == .memorable
            ? PasswordStrength(bits: PasswordGenerator.memorableBits(words: words, insertNumber: insertNumber))
            : PasswordStrength.evaluate(value)
    }

    private func copy() {
        Clipboard.copySecret(value)
        copied = true
    }

    private func intBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0.rounded()) })
    }

    private func range(_ r: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(r.lowerBound)...Double(r.upperBound)
    }
}

/// 密码字符着色：数字蓝、符号橙、字母正常色（设计稿「密码字符着色」）。
struct PasswordText: View {
    let value: String
    var size: CGFloat = 17
    @AppStorage(Preferences.Key.colorizePasswords) private var colorize = true

    var body: some View {
        Text(colored).font(.system(size: size, design: .monospaced)).lineSpacing(3)
    }

    private var colored: AttributedString {
        guard colorize else { return AttributedString(value) }
        var out = AttributedString()
        for ch in value {
            var piece = AttributedString(String(ch))
            if ch.isNumber { piece.foregroundColor = Theme.digit }
            else if !ch.isLetter { piece.foregroundColor = Theme.symbol }
            out += piece
        }
        return out
    }
}

struct StrengthBar: View {
    let strength: PasswordStrength
    /// 详情页里的小号样式：短条 + 小字
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * fraction)
                }
            }
            .frame(width: compact ? 96 : nil, height: compact ? 3 : 4)
            Text("\(label) · \(strength.bits) bits")
                .font(.system(size: compact ? 11 : 11.5)).foregroundStyle(color)
                .frame(minWidth: compact ? nil : 84, alignment: compact ? .leading : .trailing)
            if compact { Spacer(minLength: 0) }
        }
    }

    private var fraction: CGFloat { min(1, max(0.06, CGFloat(strength.bits) / 128)) }

    private var label: String {
        switch strength.level {
        case .weak: "弱"
        case .fair: "一般"
        case .strong: "强"
        case .veryStrong: "极强"
        }
    }

    private var color: Color {
        switch strength.level {
        case .weak: Theme.danger
        case .fair: Theme.warn
        case .strong, .veryStrong: Theme.ok
        }
    }
}

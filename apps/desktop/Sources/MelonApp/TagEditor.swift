import SwiftUI

/// 标签小块（查看和编辑共用）：浅底、6pt 圆角。编辑时后面带「×」。
struct TagChip: View {
    let text: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12.5))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除标签")
            }
        }
        .padding(.horizontal, 9).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.7)))
    }
}

/// 编辑态的标签：已有标签块 + 虚线框「＋ 添加标签」。点了原地变成输入框：
/// 回车或逗号确认成标签，输入框留在后面接着输；点别处收起（有内容就先确认）；下面提示保险库里已有的相似标签。
struct TagEditor: View {
    @Binding var tags: [String]
    let suggestions: [String]

    @State private var adding = false
    @State private var input = ""
    /// 键盘选中的提示项（↑↓）；nil 表示回车就用输入的内容
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    private var matches: [String] {
        let q = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return suggestions.filter { s in s.lowercased().contains(q) && !tags.contains(s) && s.lowercased() != q }.prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    TagChip(text: tag) { tags.removeAll { $0 == tag } }
                }
                if adding {
                    TextField("", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($focused)
                        .frame(width: 140)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1))
                        .onSubmit(submit)
                        .onChange(of: input) { _, new in splitOnComma(new) }
                        .onChange(of: focused) { _, isFocused in if !isFocused { finishAdding() } }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { input = ""; finishAdding(); return .handled }
                } else {
                    Button {
                        adding = true
                        Task { @MainActor in focused = true }
                    } label: {
                        Label("添加标签", systemImage: "plus").font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9).frame(height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if adding && !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element) { i, s in
                        Text(s).font(.system(size: 12.5))
                            .foregroundStyle(highlighted == i ? Theme.accent : .primary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 5).fill(highlighted == i ? Theme.accent.opacity(0.1) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { add(s); input = ""; highlighted = nil }
                    }
                }
                .padding(4)
                .frame(width: 180)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
        .onChange(of: input) { highlighted = nil }
    }

    /// 回车：选中了提示就用提示，否则用输入的内容；之后留在输入框里接着输
    private func submit() {
        if let i = highlighted, i < matches.count { add(matches[i]) } else { add(input) }
        input = ""
        highlighted = nil
        focused = true
    }

    /// 输入里出现逗号（中英文都算）：逗号前面的部分确认成标签，后面的留在输入框
    private func splitOnComma(_ text: String) {
        guard text.contains(",") || text.contains("，") else { return }
        var parts = text.split(separator: /[,，]/, omittingEmptySubsequences: false).map(String.init)
        let rest = parts.removeLast()
        parts.forEach(add)
        input = rest
    }

    /// 收起输入框：还有没确认的内容就先确认
    private func finishAdding() {
        add(input)
        input = ""
        highlighted = nil
        adding = false
    }

    /// 加一个标签：去掉首尾空格，空的和重复的忽略
    private func add(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !tags.contains(t) else { return }
        tags.append(t)
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let next = (highlighted ?? (delta > 0 ? -1 : matches.count)) + delta
        highlighted = next < 0 || next >= matches.count ? nil : next
    }
}

/// 从左到右排、放不下就换行（标签用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

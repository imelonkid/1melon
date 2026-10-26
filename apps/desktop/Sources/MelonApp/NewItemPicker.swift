import MelonCore
import SwiftUI

/// 新建条目时先选类型：窗口正中间的弹窗。点弹窗外、点右上角关闭或按 Esc 就收起，不必选。
/// 选好后由调用方进入第三栏的编辑页。
struct NewItemPicker: View {
    let onPick: (ItemType) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var types: [ItemType] { ItemType.allKnown.filter { $0.matches(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("要新建什么？").font(.system(size: 17, weight: .bold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.quaternary.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("关闭（Esc）")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("搜索类型，例如：密码、银行卡、服务器", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($searchFocused)
                    .onSubmit { if let first = types.first { onPick(first) } }
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(searchFocused ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: searchFocused ? 1.5 : 0.5))

            if types.isEmpty {
                Text("没有匹配的类型").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(types, id: \.self) { t in
                        TypeCard(type: t) { onPick(t) }
                    }
                }
            }

            Text("回车选第一个，Esc 关闭").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear { searchFocused = true }
    }
}

/// 类型卡片：和列表里一样的类型图标 + 名称，悬停时描边变成强调色
private struct TypeCard: View {
    let type: ItemType
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ItemIcon(type: type, size: 30)
                Text(type.label).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.accent.opacity(0.05) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: hovering ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

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
                Text("新建条目").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text2)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.hover))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("关闭（Esc）")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.text3)
                TextField("搜索类型，例如：密码、银行卡、服务器", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($searchFocused)
                    .onSubmit { if let first = types.first { onPick(first) } }
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(searchFocused ? Theme.accent : Theme.line2, lineWidth: searchFocused ? 1 : 0.5))

            if types.isEmpty {
                Text("没有匹配的类型").font(.system(size: 13)).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(types, id: \.self) { t in
                        TypeCard(type: t) { onPick(t) }
                    }
                }
            }

            Text("回车选第一个，Esc 关闭").font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .padding(20)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line2, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear { searchFocused = true }
    }
}

/// 类型卡片：和列表里一样的类型图标 + 名称，悬停时淡橙底橙字
private struct TypeCard: View {
    let type: ItemType
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ItemIcon(type: type, size: 32)
                Text(type.label).font(.system(size: 13.5, weight: .medium)).foregroundStyle(hovering ? Theme.accentText : Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 11).fill(hovering ? Theme.accentSoft : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

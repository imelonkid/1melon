import MelonCore
import SwiftUI

/// 第三栏的条目：查看和编辑是**同一个视图**。点「编辑」时只有能编辑的部分原地变成可输入，
/// 图标、信息栏、整体布局和滚动位置都不动，也不重建、不闪。
/// - `draft == nil`：查看态，显示 `item`
/// - `draft != nil`：编辑态，标题原地变成同字号的输入框，正文换成可编辑的分组和字段
struct ItemPane<Accessory: View>: View {
    let item: VaultItem
    var draft: Binding<ItemDraft>?
    /// 保险库里已有的全部标签（编辑时输入新标签用来提示）
    var tagSuggestions: [String] = []
    let toast: (Toast) -> Void
    let onDelete: () -> Void
    /// 信息栏里跟在类型后面的东西：保险库小胶囊、竖线、操作按钮
    @ViewBuilder let accessory: Accessory

    @FocusState private var titleFocused: Bool

    private var type: ItemType { draft?.wrappedValue.item.type ?? item.type }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let draft {
                    ItemEditBody(draft: draft, tagSuggestions: tagSuggestions, onDelete: onDelete)
                } else {
                    ItemViewBody(item: item, toast: toast)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32).padding(.top, Typo.detailTopPadding).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        // 不能让内容伸进窗口标题栏那一条：那里的点击会被系统当成拖动窗口，标题就点不进去了
        .transaction { $0.animation = nil } // 切换查看 / 编辑不做任何过渡动画
        .onAppear { if draft?.wrappedValue.isNew == true { titleFocused = true } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ItemIcon(type: type, size: 52, iconData: draft?.wrappedValue.item.iconData ?? item.iconData)
            VStack(alignment: .leading, spacing: 3) {
                // 标题：编辑时原地换成同字号、同位置的输入框
                if let draft {
                    TextField(type.label, text: draft.item.title)
                        .textFieldStyle(.plain)
                        .font(Typo.title)
                        .focused($titleFocused)
                        // 和字段的编辑方式一致：输入时背后淡淡高亮；用反向边距铺开，文字位置不动
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(titleFocused ? Theme.accent.opacity(0.06) : Color.clear))
                        .padding(.horizontal, -8).padding(.vertical, -3)
                } else {
                    Text(item.title).font(Typo.title).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Label(type.label, systemImage: type.symbol)
                        .font(Typo.meta).foregroundStyle(.secondary)
                    accessory
                }
            }
        }
    }
}

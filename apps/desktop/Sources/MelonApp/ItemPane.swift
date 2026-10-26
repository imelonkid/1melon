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
    /// 查看态顶部的安全问题提示
    var issues: [SecurityReport.Issue] = []
    var itemTitles: [String: String] = [:]
    var onFixIssue: () -> Void = {}
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
                    if !issues.isEmpty {
                        IssueBanners(issues: issues, titles: itemTitles, onFix: onFixIssue).padding(.top, 18)
                    }
                    ItemViewBody(item: item, toast: toast)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32).padding(.top, Typo.detailTopPadding).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        // 不能让内容伸进窗口标题栏那一条：那里的点击会被系统当成拖动窗口，标题就点不进去了
        .transaction { $0.animation = nil } // 切换查看 / 编辑不做任何过渡动画
        .onAppear {
            guard draft?.wrappedValue.isNew == true else { return }
            // 等输入框按标题字号布局好再聚焦：出现的同一刻就聚焦，系统的编辑器会按默认小字号建，
            // 输入框高度跟着变矮，占位文字溢出来压住下面的信息栏
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                titleFocused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ItemIcon(type: type, size: 52, iconData: draft?.wrappedValue.item.iconData ?? item.iconData)
            // 间距留够：编辑时标题背后的高亮往外铺 3pt，不能贴到下面的信息栏；查看和编辑用同一个间距，切换时不跳
            VStack(alignment: .leading, spacing: 8) {
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

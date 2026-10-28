import MelonCore
import SwiftUI

/// 第三栏的条目：查看和编辑是**同一个视图**。点「编辑」时只有能编辑的部分原地变成输入框，
/// 图标、标题行和整体布局都不动，也不重建、不闪。
/// - `draft == nil`：查看态，显示 `item`
/// - `draft != nil`：编辑态，标题变成输入框，正文换成可编辑的分组和字段
///
/// 布局（设计稿「主界面」详情栏）：右上角一排操作按钮；下面是大图标 + 标题 + 类型 / 保险库小胶囊；再下面是字段卡片。
struct ItemPane<Meta: View, Actions: View>: View {
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
    /// 类型胶囊后面的东西（保险库胶囊）
    @ViewBuilder let meta: Meta
    /// 右上角的操作按钮（查看：收藏、更多、编辑；编辑：取消、保存）
    @ViewBuilder let actions: Actions

    @FocusState private var titleFocused: Bool

    private var type: ItemType { draft?.wrappedValue.item.type ?? item.type }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                actions
            }
            .padding(.horizontal, 20).padding(.top, 16)
            .frame(height: 52)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let draft {
                        ItemEditBody(draft: draft, tagSuggestions: tagSuggestions, onDelete: onDelete)
                    } else {
                        if !issues.isEmpty {
                            IssueBanners(issues: issues, titles: itemTitles, onFix: onFixIssue).padding(.bottom, 16)
                        }
                        ItemViewBody(item: item, toast: toast)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 4).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.bg)
        .transaction { $0.animation = nil } // 切换查看 / 编辑不做任何过渡动画
        .onAppear {
            guard draft?.wrappedValue.isNew == true else { return }
            // 等输入框按标题字号布局好再聚焦，不然系统编辑器按默认小字号建，高度跟着变矮
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                titleFocused = true
            }
        }
    }

    private var header: some View {
        let current = draft?.wrappedValue.item ?? item
        return HStack(spacing: 16) {
            ItemIcon(type: type, size: 60, iconData: current.iconData, title: current.title)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                if let draft {
                    TextField(type.label, text: draft.item.title)
                        .font(.system(size: 20, weight: .semibold))
                        .focused($titleFocused)
                        .boxField(focused: titleFocused, height: 40, radius: 10)
                } else {
                    Text(item.title).font(Typo.title).foregroundStyle(Theme.text).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Pill { Text(type.label) }
                    meta
                }
            }
        }
        .padding(.top, 10).padding(.bottom, 22)
    }
}

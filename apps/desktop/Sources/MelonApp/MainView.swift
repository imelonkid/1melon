import MelonCore
import SwiftUI

enum SidebarSelection: Hashable {
    case all, favorites
    case type(ItemType)
}

/// 新建（`item == nil`，先选类型）或编辑条目的请求。
struct EditorRequest: Identifiable {
    let id = UUID()
    var item: VaultItem?
}

/// 解锁后的三栏主界面：侧栏 / 条目列表 / 条目详情。
struct MainView: View {
    @Environment(VaultSession.self) private var session
    let vault: UnlockedVault

    @State private var sidebar: SidebarSelection = .all
    @State private var selectedID: String?
    @State private var query = ""
    @State private var editor: EditorRequest?
    @State private var showGenerator = false
    @State private var toast: Toast?

    private var items: [VaultItem] { vault.activeItems }

    private var listed: [VaultItem] {
        let base: [VaultItem]
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            base = items.filter { $0.matches(query) }
        } else {
            switch sidebar {
            case .all: base = items
            case .favorites: base = items.filter(\.favorite)
            case .type(let t): base = items.filter { $0.type == t }
            }
        }
        return base.sorted { $0.modified > $1.modified }
    }

    private var selected: VaultItem? {
        listed.first { $0.id == selectedID } ?? listed.first
    }

    var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 260)
        } content: {
            itemList
                .navigationSplitViewColumnWidth(min: 260, ideal: 296, max: 360)
        } detail: {
            if let item = selected {
                ItemDetailView(item: item, onEdit: { editor = EditorRequest(item: item) }, toast: show)
                    .id(item.id) // 切换条目时重置「显示密码」等状态
            } else {
                ContentUnavailableView("未选择条目", systemImage: "lock.rectangle.stack")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "搜索")
        .toolbar {
            ToolbarItemGroup {
                Button { editor = EditorRequest(item: nil) } label: { Label("新建条目", systemImage: "plus") }
                    .keyboardShortcut("n")
                    .help("新建条目 ⌘N")
                if let item = selected {
                    Button { session.toggleFavorite(id: item.id) } label: {
                        Label("收藏", systemImage: item.favorite ? "star.fill" : "star")
                    }
                    .help("收藏")
                    Button { editor = EditorRequest(item: item) } label: { Label("编辑", systemImage: "pencil") }
                        .keyboardShortcut("e")
                        .help("编辑 ⌘E")
                }
            }
        }
        .sheet(item: $editor) { req in
            ItemEditorView(request: req) { savedID in
                if let savedID {
                    query = ""
                    if case .type(let t) = sidebar, vault.items.first(where: { $0.id == savedID })?.type != t { sidebar = .all }
                    selectedID = savedID
                }
            }
        }
        .sheet(isPresented: $showGenerator) {
            GeneratorView(inSheet: true).frame(width: 460)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                ToastView(toast: toast).padding(.bottom, 22).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .alert("保存失败", isPresented: Binding(get: { session.saveError != nil }, set: { if !$0 { session.saveError = nil } })) {
            Button("好") { session.saveError = nil }
        } message: {
            Text(session.saveError ?? "")
        }
    }

    // MARK: 侧栏

    private var sidebarList: some View {
        List(selection: Binding(get: { sidebar }, set: { if let s = $0 { sidebar = s; query = "" } })) {
            Section {
                row("全部条目", "square.grid.2x2", items.count).tag(SidebarSelection.all)
                row("收藏", "star", items.filter(\.favorite).count).tag(SidebarSelection.favorites)
            }
            Section("分类") {
                ForEach(ItemType.allKnown, id: \.self) { t in
                    row(t.label, t.symbol, items.filter { $0.type == t }.count).tag(SidebarSelection.type(t))
                }
            }
            Section("工具") {
                Button { showGenerator = true } label: { Label("密码生成器", systemImage: "dice") }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(vault.meta.name).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { session.lock() } label: { Image(systemName: "lock") }
                    .buttonStyle(.borderless)
                    .help("立即锁定 ⌘L")
            }
            .padding(10)
        }
    }

    private func row(_ title: String, _ symbol: String, _ count: Int) -> some View {
        Label(title, systemImage: symbol).badge(count)
    }

    // MARK: 条目列表

    private var listTitle: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "搜索结果" }
        switch sidebar {
        case .all: return "全部条目"
        case .favorites: return "收藏"
        case .type(let t): return t.label
        }
    }

    private var itemList: some View {
        List(selection: Binding(get: { selected?.id }, set: { selectedID = $0 })) {
            ForEach(listed) { item in
                HStack(spacing: 10) {
                    ItemIcon(type: item.type)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if item.favorite {
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
                .tag(item.id)
            }
        }
        .overlay {
            if listed.isEmpty {
                Text(items.isEmpty ? "保险库还是空的，点 ＋ 新建第一个条目" : "没有匹配的条目")
                    .font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding()
            }
        }
        .navigationTitle(listTitle)
        .navigationSubtitle("\(listed.count) 项")
    }

    // MARK: 提示

    private func show(_ t: Toast) {
        withAnimation(.easeOut(duration: 0.2)) { toast = t }
        let shown = t.id
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if toast?.id == shown { withAnimation { toast = nil } }
        }
    }
}

struct Toast: Equatable {
    let id = UUID()
    var message: String
    var detail: String = ""
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
            Text(toast.message)
            if !toast.detail.isEmpty { Text(toast.detail).foregroundStyle(.white.opacity(0.55)) }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12).opacity(0.92)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
    }
}

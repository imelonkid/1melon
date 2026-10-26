import MelonCore
import SwiftUI

enum SidebarSelection: Hashable {
    case all, favorites
    case vault(String)
}

/// 列表里的一行：条目 + 它所在的保险库
struct ListEntry: Identifiable {
    let item: VaultItem
    let vault: VaultMeta
    let vaultId: String
    var id: String { item.id }
}

/// 解锁后的三栏主界面：侧栏（保险库）/ 条目列表（可按类型筛选）/ 条目详情（查看或就地编辑）。
struct MainView: View {
    @Environment(VaultSession.self) private var session
    let loaded: LoadedAccount

    @State private var sidebar: SidebarSelection = .all
    @State private var typeFilter: ItemType?
    @State private var selectedID: String?
    @State private var query = ""
    /// 第三栏正在编辑的条目；nil 时是查看模式
    @State private var draft: ItemDraft?
    /// 有未保存的修改时，用户想做的下一件事（等确认后再做）
    @State private var pending: (() -> Void)?
    @State private var vaultsExpanded = true
    @State private var vaultEditor: VaultEditRequest?
    @State private var vaultToDelete: UnlockedVault?
    @State private var showGenerator = false
    @State private var toast: Toast?
    @State private var itemToDelete: ListEntry?
    @FocusState private var searchFocused: Bool

    // MARK: 数据

    private var entries: [ListEntry] {
        loaded.vaults.flatMap { v in v.activeItems.map { ListEntry(item: $0, vault: v.meta, vaultId: v.vaultId) } }
    }

    private var scoped: [ListEntry] {
        switch sidebar {
        case .all: entries
        case .favorites: entries.filter(\.item.favorite)
        case .vault(let id): entries.filter { $0.vaultId == id }
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var listed: [ListEntry] {
        // 搜索时搜全部保险库；不搜索时按侧栏范围 + 类型筛选
        let base = isSearching ? entries.filter { $0.item.matches(query) } : scoped
        let filtered = typeFilter.map { t in base.filter { $0.item.type == t } } ?? base
        return filtered.sorted { $0.item.modified > $1.item.modified }
    }

    private var selected: ListEntry? {
        listed.first { $0.id == selectedID } ?? listed.first
    }

    /// 新建条目默认放进哪个保险库：侧栏选中的那个，否则第一个
    private var defaultVaultId: String? {
        if case .vault(let id) = sidebar { return id }
        return loaded.vaults.first?.vaultId
    }

    // MARK: 界面

    var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 260)
        } content: {
            itemList
                .navigationSplitViewColumnWidth(min: 260, ideal: 296, max: 360)
        } detail: {
            detail
        }
        .background {
            // 不可见的按钮只为承载快捷键：⌘N 新建登录、⌘F 搜索
            Button("新建登录") { startNew(.login) }
                .keyboardShortcut("n")
                .disabled(draft != nil)
                .opacity(0).frame(width: 0, height: 0)
            Button("搜索") { searchFocused = true }
                .keyboardShortcut("f")
                .opacity(0).frame(width: 0, height: 0)
        }
        .toolbar { toolbar }
        .sheet(item: $vaultEditor) { req in
            VaultEditorSheet(request: req) { name, icon, color in
                if let id = req.vaultId {
                    session.updateVault(id: id, name: name, icon: icon, color: color)
                } else if let id = session.createVault(name: name, icon: icon, color: color) {
                    sidebar = .vault(id)
                }
            }
        }
        .sheet(isPresented: $showGenerator) {
            GeneratorView(inSheet: true).frame(width: 460)
        }
        .confirmationDialog("有未保存的修改", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("保存") { if saveDraft() { runPending() } }
            Button("放弃修改", role: .destructive) { draft = nil; runPending() }
            Button("继续编辑", role: .cancel) { pending = nil }
        }
        .confirmationDialog("删除保险库「\(vaultToDelete?.meta.name ?? "")」？", isPresented: Binding(get: { vaultToDelete != nil }, set: { if !$0 { vaultToDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let v = vaultToDelete {
                    if case .vault(v.vaultId) = sidebar { sidebar = .all }
                    session.deleteVault(id: v.vaultId)
                }
                vaultToDelete = nil
            }
        } message: {
            Text("保险库是空的，删除后不能恢复。")
        }
        .confirmationDialog("删除「\(itemToDelete?.item.title ?? "")」？", isPresented: Binding(get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let e = itemToDelete {
                    session.delete(id: e.id)
                    show(Toast(message: "已删除「\(e.item.title)」"))
                }
                itemToDelete = nil
            }
        } message: {
            Text("删除后无法恢复。")
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

    /// 窗口工具栏只放全局操作：新建条目。条目自己的操作在详情栏顶部的操作栏里。
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                ForEach(ItemType.allKnown, id: \.self) { t in
                    Button { startNew(t) } label: { Label(t.label, systemImage: t.symbol) }
                }
            } label: {
                Label("新建条目", systemImage: "plus")
            } primaryAction: {
                startNew(.login)
            }
            .disabled(draft != nil)
            .help("新建条目（点击新建登录，展开选其他类型）⌘N")
        }
    }

    // MARK: 侧栏

    private var sidebarList: some View {
        List(selection: Binding(get: { sidebar }, set: { s in
            guard let s, s != sidebar else { return }
            guarded { sidebar = s; query = "" }
        })) {
            Section {
                Label("全部条目", systemImage: "square.grid.2x2").badge(entries.count).tag(SidebarSelection.all)
                Label("收藏", systemImage: "star").badge(entries.filter(\.item.favorite).count).tag(SidebarSelection.favorites)
                Button { showGenerator = true } label: { Label("密码生成器", systemImage: "dice") }
                    .buttonStyle(.plain)
            }

            Section(isExpanded: $vaultsExpanded) {
                ForEach(loaded.vaults, id: \.vaultId) { v in
                    Label { Text(v.meta.name) } icon: { VaultBadge(meta: v.meta) }
                        .badge(v.activeItems.count)
                        .tag(SidebarSelection.vault(v.vaultId))
                        .contextMenu {
                            Button("编辑保险库…") { vaultEditor = VaultEditRequest(vault: v.meta, vaultId: v.vaultId) }
                            Button("删除保险库…", role: .destructive) { vaultToDelete = v }
                                .disabled(!v.activeItems.isEmpty || loaded.vaults.count <= 1)
                        }
                }
            } header: {
                HStack {
                    Text("保险库")
                    Spacer()
                    Button { vaultEditor = VaultEditRequest() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("新建保险库")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("1Melon").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { session.lock() } label: { Image(systemName: "lock") }
                    .buttonStyle(.borderless)
                    .help("立即锁定 ⌘L")
            }
            .padding(10)
        }
    }

    // MARK: 条目列表

    private var listTitle: String {
        if isSearching { return "搜索结果" }
        switch sidebar {
        case .all: return "全部条目"
        case .favorites: return "收藏"
        case .vault(let id): return loaded.vaults.first { $0.vaultId == id }?.meta.name ?? "保险库"
        }
    }

    private var itemList: some View {
        List(selection: Binding(get: { draft?.isNew == true ? "new" : selected?.id }, set: { id in
            guard let id, id != "new", id != selected?.id else { return }
            guarded { selectedID = id }
        })) {
            if let d = draft, d.isNew {
                row(title: d.item.title.isEmpty ? "新条目" : d.item.title, subtitle: d.item.type.label, type: d.item.type,
                    favorite: false, vault: nil)
                    .tag("new")
            }
            ForEach(listed) { e in
                row(title: e.item.title, subtitle: e.item.subtitle, type: e.item.type, favorite: e.item.favorite,
                    vault: sidebar == .vault(e.vaultId) || loaded.vaults.count == 1 ? nil : e.vault)
                    .tag(e.id)
                    .contextMenu { rowMenu(e) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if !loaded.failures.isEmpty {
                    Label("\(loaded.failures.count) 个保险库文件打不开（损坏或被篡改），已跳过", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.warn)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.warn.opacity(0.12))
                        .help(loaded.failures.map { "\($0.file)：\($0.error.userMessage)" }.joined(separator: "\n"))
                }
                searchField
                typeFilterBar
            }
        }
        .overlay {
            if listed.isEmpty && draft?.isNew != true {
                Text(entries.isEmpty ? "保险库还是空的，点 ＋ 新建第一个条目" : "没有匹配的条目")
                    .font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding()
            }
        }
        .navigationTitle(listTitle)
        .navigationSubtitle("\(listed.count) 项")
    }

    /// 搜索框：在条目列表上方，搜的是全部保险库（⌘F 聚焦）
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(.secondary)
            TextField("搜索", text: guardedQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
                    .help("清除搜索")
            }
        }
        .padding(.horizontal, 9).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.7)))
        .padding(.horizontal, 12).padding(.top, 6)
    }

    private var typeFilterBar: some View {
        HStack {
            Menu {
                Button { typeFilter = nil } label: { Label("全部类型", systemImage: "square.grid.2x2") }
                Divider()
                ForEach(ItemType.allKnown, id: \.self) { t in
                    let n = (isSearching ? entries.filter { $0.item.matches(query) } : scoped).filter { $0.item.type == t }.count
                    Button { typeFilter = t } label: { Label("\(t.label)（\(n)）", systemImage: t.symbol) }
                }
            } label: {
                Label(typeFilter?.label ?? "全部类型", systemImage: "line.3.horizontal.decrease")
                    .font(.system(size: 11.5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if typeFilter != nil {
                Button { typeFilter = nil } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
                    .help("清除类型筛选")
            }
            Spacer()
            Text("按修改时间").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func row(title: String, subtitle: String, type: ItemType, favorite: Bool, vault: VaultMeta?) -> some View {
        HStack(spacing: 10) {
            ItemIcon(type: type)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if favorite {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let vault {
                Circle().fill(VaultStyle.color(vault.color)).frame(width: 6, height: 6).help(vault.name)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func rowMenu(_ e: ListEntry) -> some View {
        Button("编辑") { guarded { selectedID = e.id; startEditing(e) } }
        Button(e.item.favorite ? "取消收藏" : "收藏") { session.toggleFavorite(id: e.id) }
        if loaded.vaults.count > 1 {
            Menu("移到") {
                ForEach(loaded.vaults.filter { $0.vaultId != e.vaultId }, id: \.vaultId) { v in
                    Button(v.meta.name) {
                        session.move(id: e.id, to: v.vaultId)
                        show(Toast(message: "已移到「\(v.meta.name)」"))
                    }
                }
            }
        }
    }

    // MARK: 详情 / 编辑

    @ViewBuilder
    private var detail: some View {
        if draft != nil {
            VStack(spacing: 0) {
                editBar
                Divider()
                ItemEditPane(draft: Binding(get: { draft! }, set: { draft = $0 }), onDelete: deleteDraftItem)
                    .id(draft!.item.id)
            }
        } else if let e = selected {
            VStack(spacing: 0) {
                viewBar(e)
                Divider()
                ItemDetailView(item: e.item, toast: show)
                    .id(e.id) // 切换条目时重置「显示密码」等状态
            }
        } else {
            ContentUnavailableView("未选择条目", systemImage: "lock.rectangle.stack")
        }
    }

    /// 查看时的操作栏：左边是所在保险库（点开可以换），右边是收藏、编辑、更多
    private func viewBar(_ e: ListEntry) -> some View {
        HStack(spacing: 6) {
            vaultMenu(current: e.vaultId) { target in
                guard target != e.vaultId, let name = loaded.vaults.first(where: { $0.vaultId == target })?.meta.name else { return }
                session.move(id: e.id, to: target)
                selectedID = e.id
                if case .vault = sidebar { sidebar = .vault(target) }
                show(Toast(message: "已移到「\(name)」"))
            }
            Spacer()
            Button { session.toggleFavorite(id: e.id) } label: {
                Image(systemName: e.item.favorite ? "star.fill" : "star")
                    .foregroundStyle(e.item.favorite ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(e.item.favorite ? "取消收藏" : "收藏")
            Button { startEditing(e) } label: { Label("编辑", systemImage: "pencil") }
                .keyboardShortcut("e")
                .help("编辑 ⌘E")
            Menu {
                Button(e.item.favorite ? "取消收藏" : "收藏") { session.toggleFavorite(id: e.id) }
                Button("编辑") { startEditing(e) }
                Divider()
                Button("删除…", role: .destructive) { itemToDelete = e }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
        }
        .padding(.horizontal, 16).frame(height: 44)
    }

    /// 编辑时的操作栏：左边选放进哪个保险库，右边取消、保存
    private var editBar: some View {
        HStack(spacing: 8) {
            if let d = draft {
                vaultMenu(current: d.vaultId) { target in draft?.vaultId = target }
                Text(d.isNew ? "新建 · \(d.item.type.label)" : "编辑中").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") { cancelEditing() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { _ = saveDraft() }
                .keyboardShortcut("s")
                .primaryActionStyle()
        }
        .padding(.horizontal, 16).frame(height: 44)
    }

    /// 保险库徽标 + 名称；有多个保险库时点开可以选别的
    @ViewBuilder
    private func vaultMenu(current: String, onPick: @escaping (String) -> Void) -> some View {
        let meta = loaded.vaults.first { $0.vaultId == current }?.meta
        let label = HStack(spacing: 6) {
            if let meta { VaultBadge(meta: meta, size: 18) }
            Text(meta?.name ?? "保险库").font(.system(size: 13, weight: .medium))
        }
        if loaded.vaults.count > 1 {
            Menu {
                ForEach(loaded.vaults, id: \.vaultId) { v in
                    Button { onPick(v.vaultId) } label: {
                        if v.vaultId == current { Label(v.meta.name, systemImage: "checkmark") } else { Text(v.meta.name) }
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("换到别的保险库")
        } else {
            label
        }
    }

    private func startNew(_ type: ItemType) {
        guard let vid = defaultVaultId else { return }
        guarded {
            query = ""
            draft = .new(type, in: vid)
        }
    }

    private func startEditing(_ e: ListEntry) {
        draft = .editing(e.item, in: e.vaultId)
    }

    private func cancelEditing() {
        guard let d = draft else { return }
        if d.hasChanges { pending = {} } else { draft = nil }
    }

    /// 保存草稿。返回是否成功（写盘失败时留在编辑模式，弹窗提示）
    @discardableResult
    private func saveDraft() -> Bool {
        guard let d = draft else { return true }
        let item = d.finalized()
        session.save(item, in: d.vaultId)
        guard session.saveError == nil else { return false }
        draft = nil
        selectedID = item.id
        // 保存后条目要看得见：被类型筛选或侧栏范围挡住时放开
        if let t = typeFilter, t != item.type { typeFilter = nil }
        if case .vault(let id) = sidebar, id != d.vaultId { sidebar = .vault(d.vaultId) }
        if sidebar == .favorites && !item.favorite { sidebar = .all }
        show(Toast(message: d.isNew ? "已添加「\(item.title)」" : "已保存"))
        return true
    }

    private func deleteDraftItem() {
        guard let d = draft else { return }
        session.delete(id: d.item.id)
        draft = nil
        show(Toast(message: "已删除「\(d.item.title)」"))
    }

    /// 编辑中、有未保存的修改时先确认；否则直接做（顺带退出编辑模式）
    private func guarded(_ action: @escaping () -> Void) {
        if let d = draft, d.hasChanges {
            pending = action
        } else {
            draft = nil
            action()
        }
    }

    private func runPending() {
        let action = pending
        pending = nil
        action?()
    }

    /// 编辑时开始搜索也要先确认
    private var guardedQuery: Binding<String> {
        Binding(get: { query }, set: { q in
            if draft == nil { query = q } else { guarded { query = q } }
        })
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

extension View {
    /// 主操作按钮：实心强调色、白字。macOS 26 的工具栏会把 `.borderedProminent` 渲染成很淡的玻璃，
    /// 所以那里用 `.glassProminent`；发布构建机的 Xcode 16 没有这个样式，用编译器版本隔开。
    @ViewBuilder
    func primaryActionStyle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Theme.accent)
        } else {
            buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        #else
        buttonStyle(.borderedProminent).tint(Theme.accent)
        #endif
    }
}

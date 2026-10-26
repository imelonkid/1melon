import MelonCore
import SwiftUI

enum SidebarSelection: Hashable {
    case all, favorites, security
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
    @State private var showNewPicker = false
    @State private var securityFilter: SecurityReport.Kind?
    @State private var showImport = false
    @FocusState private var searchFocused: Bool

    // MARK: 数据

    private var entries: [ListEntry] {
        loaded.vaults.flatMap { v in v.activeItems.map { ListEntry(item: $0, vault: v.meta, vaultId: v.vaultId) } }
    }

    /// 安全报告：只在本机根据全部保险库的条目计算
    private var report: SecurityReport { SecurityReport.analyze(entries.map(\.item)) }
    private var itemTitles: [String: String] { Dictionary(entries.map { ($0.id, $0.item.title) }, uniquingKeysWith: { a, _ in a }) }

    private var scoped: [ListEntry] {
        switch sidebar {
        case .all: entries
        case .favorites: entries.filter(\.item.favorite)
        case .vault(let id): entries.filter { $0.vaultId == id }
        case .security: entries.filter { e in
            report.issues(for: e.id).contains { securityFilter == nil || $0.kind == securityFilter }
        }
        }
    }

    /// 所有保险库里用过的标签，按名称排序（输入新标签时提示）
    private var allTags: [String] {
        Array(Set(entries.flatMap(\.item.tags))).sorted()
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
            if sidebar == .security && !isSearching {
                SecurityReportColumn(
                    report: report, entries: entries, filter: $securityFilter,
                    selectedID: Binding(get: { selected?.id }, set: { id in
                        guard let id, id != selected?.id else { return }
                        guarded { selectedID = id }
                    })
                )
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 380)
            } else {
                itemList
                    .navigationSplitViewColumnWidth(min: 260, ideal: 296, max: 360)
            }
        } detail: {
            detail
        }
        .background {
            // 不可见的按钮只为承载快捷键：⌘N 新建登录、⌘F 搜索
            Button("新建条目") { requestNew() }
                .keyboardShortcut("n")
                .disabled(draft != nil)
                .opacity(0).frame(width: 0, height: 0)
            Button("搜索") { searchFocused = true }
                .keyboardShortcut("f")
                .opacity(0).frame(width: 0, height: 0)
        }
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
        .sheet(isPresented: $showImport) {
            ImportSheet(defaultVaultId: defaultVaultId) { n in
                if n > 0 { sidebar = .all; selectedID = nil }
            }
        }
        .onChange(of: session.importRequested, initial: true) { _, requested in
            guard requested else { return }
            session.importRequested = false
            guarded { showImport = true }
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
        .overlay {
            // 新建条目的类型选择：窗口正中间，点遮罩（弹窗外）就收起
            if showNewPicker {
                ZStack {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { showNewPicker = false }
                    NewItemPicker(onPick: { type in
                        showNewPicker = false
                        startNew(type)
                    }, onClose: { showNewPicker = false })
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showNewPicker)
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
        List(selection: Binding(get: { sidebar }, set: { s in
            guard let s, s != sidebar else { return }
            guarded { sidebar = s; query = "" }
        })) {
            Section {
                Label("全部条目", systemImage: "square.grid.2x2").badge(entries.count).tag(SidebarSelection.all)
                Label("收藏", systemImage: "star").badge(entries.filter(\.item.favorite).count).tag(SidebarSelection.favorites)
                let troubled = report.itemsWithIssues.count
                Label("安全报告", systemImage: "checkmark.shield")
                    .badge(troubled > 0 ? Text("\(troubled)").foregroundColor(Theme.warn) : nil)
                    .tag(SidebarSelection.security)
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
                // 设计稿：侧栏左下角是「设置」，右边是立即锁定
                SettingsLink {
                    Label("设置", systemImage: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("设置 ⌘,")
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
        case .security: return "安全报告"
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
                    vault: sidebar == .vault(e.vaultId) || loaded.vaults.count == 1 ? nil : e.vault, iconData: e.item.iconData)
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
            // 新建条目：嵌在搜索框最右边
            Button { requestNew() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(draft != nil)
            .help("新建条目 ⌘N")
        }
        .padding(.leading, 9).padding(.trailing, 4).frame(height: 30)
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

    private func row(title: String, subtitle: String, type: ItemType, favorite: Bool, vault: VaultMeta?, iconData: Data? = nil) -> some View {
        HStack(spacing: 10) {
            ItemIcon(type: type, iconData: iconData)
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

    /// 查看和编辑只有这一处调用：编辑已有条目时 id 不变，`ItemPane` 保持同一个实例，原地切换、不闪
    @ViewBuilder
    private var detail: some View {
        if let shown = draft?.item ?? selected?.item {
            ItemPane(
                item: shown,
                draft: draft == nil ? nil : Binding(get: { draft ?? .editing(shown, in: "") }, set: { draft = $0 }),
                tagSuggestions: allTags,
                toast: show,
                onDelete: deleteDraftItem,
                issues: draft == nil ? report.issues(for: shown.id) : [],
                itemTitles: itemTitles,
                onFixIssue: { if let e = selected { startEditing(e) } }
            ) {
                if let d = draft {
                    vaultChip(current: d.vaultId) { target in draft?.vaultId = target }
                    ActionDivider()
                    Button { cancelEditing() } label: { Text("取消") }
                        .buttonStyle(InlineActionStyle())
                        .keyboardShortcut(.cancelAction)
                        .help("取消 Esc")
                    Button { _ = saveDraft() } label: { Text("保存") }
                        .buttonStyle(InlineActionStyle(prominent: true))
                        .keyboardShortcut("s")
                        .help("保存 ⌘S")
                } else if let e = selected {
                    vaultChip(current: e.vaultId) { target in moveEntry(e, to: target) }
                    ActionDivider()
                    itemActions(e)
                }
            }
            .id(shown.id)
        } else {
            ContentUnavailableView("未选择条目", systemImage: "lock.rectangle.stack")
        }
    }

    /// 查看时跟在「类型 · 保险库」后面的操作：收藏、编辑（唯一有底色的）、更多
    @ViewBuilder
    private func itemActions(_ e: ListEntry) -> some View {
        Button { session.toggleFavorite(id: e.id) } label: {
            Image(systemName: e.item.favorite ? "star.fill" : "star")
                .font(.system(size: 13))
                .foregroundStyle(e.item.favorite ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(e.item.favorite ? "取消收藏" : "收藏")
        Button { startEditing(e) } label: { Text("编辑") }
        .buttonStyle(InlineActionStyle())
        .keyboardShortcut("e")
        .help("编辑 ⌘E")
        // 只放外面没有的操作；收藏、编辑已经在外面了
        Menu {
            Button("复制条目") { duplicateEntry(e) }
            if WebsiteIcon.host(forURL: e.item.primaryURL) != nil {
                Button("重新获取网站图标") {
                    session.refreshIcon(for: e.id, force: true)
                    show(Toast(message: "正在获取网站图标"))
                }
            }
            if e.item.iconData != nil {
                Button("使用默认图标") { session.useDefaultIcon(for: e.id) }
            }
            if loaded.vaults.count > 1 {
                Menu("移到") {
                    ForEach(loaded.vaults.filter { $0.vaultId != e.vaultId }, id: \.vaultId) { v in
                        Button(v.meta.name) { moveEntry(e, to: v.vaultId) }
                    }
                }
            }
            Divider()
            Button("删除…", role: .destructive) { itemToDelete = e }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    /// 复制出一个副本：新 id、标题加「副本」，放在同一个保险库，然后选中它
    private func duplicateEntry(_ e: ListEntry) {
        let now = Date().unixMilliseconds
        var copy = e.item
        copy.id = newID()
        copy.rev = 0
        copy.title = e.item.title + " 副本"
        copy.created = now
        copy.sections = copy.sections.map { s in
            var s = s
            s.id = newID()
            s.fields = s.fields.map { f in var f = f; f.id = newID(); return f }
            return s
        }
        session.save(copy, into: e.vaultId)
        guard session.saveError == nil else { return }
        selectedID = copy.id
        show(Toast(message: "已复制为「\(copy.title)」"))
    }

    private func moveEntry(_ e: ListEntry, to target: String) {
        guard target != e.vaultId, let name = loaded.vaults.first(where: { $0.vaultId == target })?.meta.name else { return }
        session.move(id: e.id, to: target)
        selectedID = e.id
        if case .vault = sidebar { sidebar = .vault(target) }
        show(Toast(message: "已移到「\(name)」"))
    }

    /// 标题下面的保险库小胶囊；有多个保险库时点开可以换
    @ViewBuilder
    private func vaultChip(current: String, onPick: @escaping (String) -> Void) -> some View {
        let meta = loaded.vaults.first { $0.vaultId == current }?.meta
        let multiple = loaded.vaults.count > 1
        let chip = HStack(spacing: 5) {
            if let meta { VaultBadge(meta: meta, size: 15) }
            Text(meta?.name ?? "保险库").font(Typo.meta)
            if multiple { Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold)) }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 3).padding(.trailing, multiple ? 8 : 9).padding(.vertical, 2)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        if multiple {
            Menu {
                ForEach(loaded.vaults, id: \.vaultId) { v in
                    Button { onPick(v.vaultId) } label: {
                        if v.vaultId == current { Label(v.meta.name, systemImage: "checkmark") } else { Text(v.meta.name) }
                    }
                }
            } label: {
                chip
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("换到别的保险库")
        } else {
            chip
        }
    }

    /// 「＋」/ ⌘N：先选类型（编辑中有未保存的修改时先确认）
    private func requestNew() {
        guard draft == nil else { return }
        showNewPicker.toggle()
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
        session.refreshIcon(for: item.id) // 网址的主机变了就在后台取网站图标
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

/// 条目信息和操作之间的细竖线
struct ActionDivider: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 14).padding(.horizontal, 2)
    }
}

/// 信息栏里的按钮（编辑 / 取消 / 保存共用一套）：同样的高度、圆角、字号，只有文字。
/// 普通的是浅底；`prominent` 是强调色底白字，只给主操作（保存）用。
struct InlineActionStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary.opacity(0.7))))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

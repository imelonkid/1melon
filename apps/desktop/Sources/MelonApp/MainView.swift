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

/// 列表的排序方式
enum ListSort: Hashable {
    case modified, title
}

/// 解锁后的三栏主界面（设计稿「主界面」）：侧栏（品牌头、范围、保险库，底部设置 / 同步 / 锁定）·
/// 条目列表（搜索 + 新建、类型筛选、排序、按时间分组）· 条目详情（查看或就地编辑）。
/// 三栏宽度固定，不用系统的分栏视图：选中色、底色都按稿来。
struct MainView: View {
    @Environment(VaultSession.self) private var session
    let loaded: LoadedAccount

    @State private var sidebar: SidebarSelection = .all
    @State private var typeFilter: ItemType?
    @State private var sort: ListSort = .modified
    @State private var selectedID: String?
    @State private var query = ""
    /// 第三栏正在编辑的条目；nil 时是查看模式
    @State private var draft: ItemDraft?
    /// 有未保存的修改时，用户想做的下一件事（等确认后再做）
    @State private var pending: (() -> Void)?
    @State private var vaultEditor: VaultEditRequest?
    @State private var vaultToDelete: UnlockedVault?
    @State private var showGenerator = false
    @State private var toast: Toast?
    @State private var itemToDelete: ListEntry?
    @State private var showNewPicker = false
    @State private var securityFilter: SecurityReport.Kind?
    @State private var showImport = false
    @State private var showExport = false
    @FocusState private var searchFocused: Bool

    static let sidebarWidth: CGFloat = 248
    static let listWidth: CGFloat = 340

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
        switch sort {
        case .modified: return filtered.sorted { $0.item.modified > $1.item.modified }
        case .title: return filtered.sorted { $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending }
        }
    }

    /// 按修改时间排序时分成「今天 / 本周 / 更早」；按名称排序时不分组
    private var groups: [(title: String, entries: [ListEntry])] {
        let items = listed
        guard sort == .modified else { return [("", items)] }
        let cal = Calendar.current
        let now = Date()
        func bucket(_ e: ListEntry) -> String {
            let d = Date(timeIntervalSince1970: Double(e.item.modified) / 1000)
            if cal.isDateInToday(d) { return "今天" }
            if cal.isDate(d, equalTo: now, toGranularity: .weekOfYear) { return "本周" }
            return "更早"
        }
        var out: [(String, [ListEntry])] = []
        for e in items {
            let b = bucket(e)
            if out.last?.0 == b { out[out.count - 1].1.append(e) } else { out.append((b, [e])) }
        }
        return out
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
        HStack(spacing: 0) {
            sidebarColumn
                .frame(width: Self.sidebarWidth)
            VLine()
            Group {
                if sidebar == .security && !isSearching {
                    SecurityReportColumn(
                        report: report, entries: entries, filter: $securityFilter,
                        selectedID: Binding(get: { selected?.id }, set: { id in
                            guard let id, id != selected?.id else { return }
                            guarded { selectedID = id }
                        })
                    )
                } else {
                    itemList
                }
            }
            .frame(width: Self.listWidth)
            VLine()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.bg)
        .background {
            // 不可见的按钮只为承载快捷键：⌘N 新建、⌘F 搜索
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
        .sheet(isPresented: $showExport) { ExportSheet() }
        .onChange(of: session.importRequested, initial: true) { _, requested in
            guard requested else { return }
            session.importRequested = false
            guarded { showImport = true }
        }
        .onChange(of: session.exportRequested, initial: true) { _, requested in
            guard requested else { return }
            session.exportRequested = false
            guarded { showExport = true }
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
                    Color.black.opacity(0.18)
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

    private func pick(_ s: SidebarSelection) {
        guard s != sidebar else { return }
        guarded { sidebar = s; query = "" }
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌头：留出左上角红绿灯的位置
            HStack(spacing: 12) {
                AppMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1Melon").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                    Text(syncLine).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            .padding(.horizontal, 22).padding(.top, 56).padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(symbol: "square.grid.2x2", title: "全部条目", count: entries.count, selected: sidebar == .all) { pick(.all) }
                    SidebarRow(symbol: "star", title: "收藏", count: entries.filter(\.item.favorite).count, selected: sidebar == .favorites) { pick(.favorites) }
                    SidebarRow(symbol: "checkmark.shield", title: "安全报告", count: report.itemsWithIssues.count,
                               selected: sidebar == .security, highlightCount: true) { pick(.security) }
                    SidebarRow(symbol: "key", title: "密码生成器", selected: false, chevron: true) { showGenerator = true }

                    HStack {
                        Text("保险库").font(.system(size: 12)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button { vaultEditor = VaultEditRequest() } label: { Image(systemName: "plus") }
                            .buttonStyle(IconButtonStyle(size: 22))
                            .help("新建保险库")
                    }
                    .padding(.leading, 12).padding(.trailing, 6).padding(.top, 16).padding(.bottom, 4)

                    ForEach(loaded.vaults, id: \.vaultId) { v in
                        SidebarRow(title: v.meta.name, count: v.activeItems.count, selected: sidebar == .vault(v.vaultId),
                                   badge: AnyView(VaultBadge(meta: v.meta))) { pick(.vault(v.vaultId)) }
                            .contextMenu {
                                Button("编辑保险库…") { vaultEditor = VaultEditRequest(vault: v.meta, vaultId: v.vaultId) }
                                Button("删除保险库…", role: .destructive) { vaultToDelete = v }
                                    .disabled(!v.activeItems.isEmpty || loaded.vaults.count <= 1)
                            }
                    }
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.never)

            // 底部：设置 · 同步 · 锁定
            HStack(spacing: 4) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape").font(.system(size: 12.5))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6).frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置 ⌘,")
                Spacer()
                if session.isSyncEnabled {
                    Button { session.syncNow() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.pulse, isActive: session.sync.syncing)
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(session.sync.syncing || session.syncClient == nil)
                    .help(session.sync.problem ?? "立即同步")
                }
                Button { session.lock() } label: { Image(systemName: "lock") }
                    .buttonStyle(IconButtonStyle())
                    .help("立即锁定 ⌘L")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .overlay(alignment: .top) { RowDivider() }
        }
        .background(Theme.side)
    }

    /// 品牌头下面那行小字：同步状态
    private var syncLine: String {
        let _ = session.sync
        guard session.isSyncEnabled else { return "只保存在这台 Mac 上" }
        if session.sync.syncing { return "正在同步…" }
        if session.sync.problem != nil { return "同步出了问题" }
        if let t = session.sync.lastSuccess {
            return "已同步 · " + t.formatted(.relative(presentation: .named))
        }
        return "已开启同步"
    }

    // MARK: 条目列表

    private var itemList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    searchField
                    Button { requestNew() } label: {
                        Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent))
                            .shadow(color: Theme.accent.opacity(0.3), radius: 7, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft != nil)
                    .help("新建条目 ⌘N")
                }
                filterBar
            }
            .padding(.horizontal, 18).padding(.top, 42).padding(.bottom, 10)

            if !loaded.failures.isEmpty {
                Label("\(loaded.failures.count) 个保险库文件打不开（损坏或被篡改），已跳过", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.danger)
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(loaded.failures.map { "\($0.file)：\($0.error.userMessage)" }.joined(separator: "\n"))
            }
            RowDivider()

            if entries.isEmpty && draft?.isNew != true {
                EmptyState(illustration: AnyView(EmptyVaultIllustration()), title: "保险库还是空的",
                           message: "点 ＋ 新建第一个条目\n或者从「文件 → 导入…」导入 CSV")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if let d = draft, d.isNew {
                                ItemRow(title: d.item.title.isEmpty ? "新条目" : d.item.title, subtitle: d.item.type.label,
                                        type: d.item.type, favorite: false, selected: true)
                                    .padding(.top, 8)
                            }
                            ForEach(groups, id: \.title) { group in
                                if !group.title.isEmpty {
                                    Text(group.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text3)
                                        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                                }
                                ForEach(group.entries) { e in
                                    ItemRow(title: e.item.title, subtitle: e.item.subtitle, type: e.item.type,
                                            favorite: e.item.favorite, selected: draft?.isNew != true && e.id == selected?.id,
                                            iconData: e.item.iconData)
                                        .id(e.id)
                                        .onTapGesture {
                                            guard e.id != selected?.id else { return }
                                            guarded { selectedID = e.id }
                                        }
                                        .contextMenu { rowMenu(e) }
                                }
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .overlay {
                        if listed.isEmpty && draft?.isNew != true {
                            Text("没有匹配的条目").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { step(1, proxy); return .handled }
                    .onKeyPress(.upArrow) { step(-1, proxy); return .handled }
                }
            }
        }
        .background(Theme.list)
    }

    /// ↑↓ 在列表里换选中的条目
    private func step(_ delta: Int, _ proxy: ScrollViewProxy) {
        let ids = groups.flatMap { $0.entries.map(\.id) }
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex(of: selected?.id ?? "") ?? 0
        let next = ids[max(0, min(ids.count - 1, i + delta))]
        guard next != selected?.id else { return }
        guarded {
            selectedID = next
            proxy.scrollTo(next)
        }
    }

    /// 搜索框：搜的是全部保险库（⌘F 聚焦，Esc 清空）
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.text3)
            TextField("搜索条目、网站或标签…", text: guardedQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.text3)
                    .help("清除搜索")
            }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.input))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(searchFocused ? Theme.accent : Theme.line2, lineWidth: searchFocused ? 1 : 0.5))
    }

    private var filterBar: some View {
        HStack {
            Menu {
                Button { typeFilter = nil } label: { Label("全部类型", systemImage: "square.grid.2x2") }
                Divider()
                ForEach(ItemType.allKnown, id: \.self) { t in
                    let n = (isSearching ? entries.filter { $0.item.matches(query) } : scoped).filter { $0.item.type == t }.count
                    Button { typeFilter = t } label: { Label("\(t.label)（\(n)）", systemImage: t.symbol) }
                }
            } label: {
                MenuLabel(symbol: "line.3.horizontal.decrease", text: typeFilter?.label ?? "全部类型", active: typeFilter != nil)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
            Menu {
                Picker("排序", selection: $sort) {
                    Text("按修改时间").tag(ListSort.modified)
                    Text("按名称").tag(ListSort.title)
                }
                .pickerStyle(.inline)
            } label: {
                MenuLabel(symbol: "arrow.up.arrow.down", text: sort == .modified ? "按修改时间" : "按名称")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
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
        Divider()
        Button("删除…", role: .destructive) { itemToDelete = e }
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
                } else if let e = selected {
                    vaultChip(current: e.vaultId) { target in moveEntry(e, to: target) }
                }
            } actions: {
                if draft != nil {
                    Button("取消") { cancelEditing() }
                        .buttonStyle(PaneButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .help("取消 Esc")
                    Button { _ = saveDraft() } label: { Label("保存", systemImage: "checkmark") }
                        .buttonStyle(PaneButtonStyle(prominent: true))
                        .keyboardShortcut("s")
                        .help("保存 ⌘S")
                } else if let e = selected {
                    itemActions(e)
                }
            }
            .id(shown.id)
        } else {
            EmptyState(illustration: AnyView(NoSelectionIllustration()), title: "未选择条目",
                       message: entries.isEmpty ? "点 ＋ 新建第一个条目" : "从左侧列表选一个条目，或点 ＋ 新建", large: true)
                .background(Theme.bg)
        }
    }

    /// 查看时右上角的操作：收藏、更多、编辑（唯一的橙色按钮）
    @ViewBuilder
    private func itemActions(_ e: ListEntry) -> some View {
        Button { session.toggleFavorite(id: e.id) } label: {
            Image(systemName: e.item.favorite ? "star.fill" : "star")
                .foregroundStyle(e.item.favorite ? Theme.accent : Theme.text2)
        }
        .buttonStyle(IconButtonStyle(size: 32))
        .help(e.item.favorite ? "取消收藏" : "收藏")
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
            Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(Theme.text2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
        Button { startEditing(e) } label: { Label("编辑", systemImage: "pencil") }
            .buttonStyle(PaneButtonStyle(prominent: true))
            .keyboardShortcut("e")
            .help("编辑 ⌘E")
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
        let chip = Pill {
            Text(meta?.name ?? "保险库")
            if multiple { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
        }
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

    /// 编辑时开始搜索也要先确认。内容没变的写入（搜索框有焦点时界面刷新会写回原值）直接忽略，
    /// 否则刚从类型弹窗新建的空草稿会被当成「开始搜索」清掉
    private var guardedQuery: Binding<String> {
        Binding(get: { query }, set: { q in
            guard q != query else { return }
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
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            Text(toast.message)
            if !toast.detail.isEmpty { Text(toast.detail).foregroundStyle(.white.opacity(0.55)) }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(white: 0.12).opacity(0.94)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
    }
}

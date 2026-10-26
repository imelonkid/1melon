import MelonCore
import SwiftUI

/// 正在第三栏里编辑的条目。新建（`original == nil`）和编辑已有条目共用。
struct ItemDraft: Equatable {
    var item: VaultItem
    var vaultId: String
    var tagsText: String
    let original: VaultItem?
    let originalVaultId: String

    static func new(_ type: ItemType, in vaultId: String) -> ItemDraft {
        ItemDraft(item: .fromTemplate(type, now: Date().unixMilliseconds), vaultId: vaultId, tagsText: "",
                  original: nil, originalVaultId: vaultId)
    }

    static func editing(_ item: VaultItem, in vaultId: String) -> ItemDraft {
        ItemDraft(item: item, vaultId: vaultId, tagsText: item.tags.joined(separator: ", "),
                  original: item, originalVaultId: vaultId)
    }

    var isNew: Bool { original == nil }

    /// 有没有需要保存的内容：新建时填过任何东西就算；编辑时和原来不一样就算
    var hasChanges: Bool {
        if let original {
            return item != original || vaultId != originalVaultId || tagsText != original.tags.joined(separator: ", ")
        }
        return !item.title.trimmingCharacters(in: .whitespaces).isEmpty || !item.notes.isEmpty || !tagsText.isEmpty
            || item.allFields.contains { !$0.value.isEmpty }
    }

    /// 保存前整理：标题为空用类型名，标签按中英文逗号拆开
    func finalized() -> VaultItem {
        var it = item
        it.title = it.title.trimmingCharacters(in: .whitespaces)
        if it.title.isEmpty { it.title = it.type.label }
        it.tags = tagsText.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return it
    }
}

/// 第三栏的编辑模式：和详情页同样的布局，配置块和配置项都可以增删、改名、拖动排序。
struct ItemEditPane: View {
    @Binding var draft: ItemDraft
    let vaults: [UnlockedVault]
    let onDelete: () -> Void

    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                ForEach($draft.item.sections) { $section in
                    SectionEditor(
                        section: $section,
                        onDeleteSection: { draft.item.sections.removeAll { $0.id == section.id } },
                        onDrop: moveField
                    )
                    .padding(.top, 18)
                }

                Button {
                    draft.item.sections.append(ItemSection(title: "", fields: [ItemField(label: FieldKind.text.label, kind: .text)]))
                } label: {
                    Label("添加配置块", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .padding(.top, 14)

                labeled(draft.item.type == .note ? "内容" : "备注") {
                    TextEditor(text: $draft.item.notes)
                        .font(draft.item.type == .note ? .system(size: 12, design: .monospaced) : .system(size: 13))
                        .frame(minHeight: draft.item.type == .note ? 200 : 64)
                        .editorBox()
                }
                .padding(.top, 22)

                labeled("标签") {
                    TextField("用逗号分隔，例如：工作, 开发", text: $draft.tagsText).textFieldStyle(.roundedBorder)
                }
                .padding(.top, 12)

                if !draft.isNew {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除条目", systemImage: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 28)
                        .confirmationDialog("删除「\(draft.item.title)」？", isPresented: $confirmDelete) {
                            Button("删除", role: .destructive, action: onDelete)
                        } message: {
                            Text("删除后无法恢复。")
                        }
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if draft.isNew { titleFocused = true } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ItemIcon(type: draft.item.type, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                TextField(draft.item.type.label, text: $draft.item.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .focused($titleFocused)
                HStack(spacing: 8) {
                    Label("\(draft.isNew ? "新建" : "编辑") · \(draft.item.type.label)", systemImage: draft.item.type.symbol)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if vaults.count > 1 {
                        Picker("保险库", selection: $draft.vaultId) {
                            ForEach(vaults, id: \.vaultId) { v in
                                Label(v.meta.name, systemImage: VaultStyle.symbol(v.meta.icon)).tag(v.vaultId)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("放在哪个保险库")
                    }
                }
            }
        }
    }

    /// 把配置项 `id` 挪到 `target` 前面（可以跨配置块）；`target` 为 nil 时放到 `section` 的末尾
    private func moveField(_ id: String, before target: String?, inSection sectionId: String) {
        guard id != target else { return }
        var sections = draft.item.sections
        guard let si = sections.firstIndex(where: { $0.fields.contains { $0.id == id } }),
              let fi = sections[si].fields.firstIndex(where: { $0.id == id }) else { return }
        let field = sections[si].fields.remove(at: fi)
        guard let ti = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let at = target.flatMap { t in sections[ti].fields.firstIndex { $0.id == t } } ?? sections[ti].fields.count
        sections[ti].fields.insert(field, at: at)
        draft.item.sections = sections
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// 一个配置块：标题可改、整块可删；配置项可增删、拖动排序。
struct SectionEditor: View {
    @Binding var section: ItemSection
    let onDeleteSection: () -> Void
    let onDrop: (_ id: String, _ before: String?, _ inSection: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("配置块标题（可选）", text: $section.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Button(action: onDeleteSection) { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("删除这个配置块")
            }
            .padding(.leading, 4)

            Card {
                ForEach(Array(section.fields.enumerated()), id: \.element.id) { i, field in
                    if i > 0 { Divider().padding(.leading, 14) }
                    FieldEditRow(
                        field: Binding(
                            get: { section.fields.first { $0.id == field.id } ?? field },
                            set: { new in if let j = section.fields.firstIndex(where: { $0.id == field.id }) { section.fields[j] = new } }
                        ),
                        onDelete: { section.fields.removeAll { $0.id == field.id } }
                    )
                    .draggable(field.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first else { return false }
                        onDrop(id, field.id, section.id)
                        return true
                    }
                }
                if !section.fields.isEmpty { Divider().padding(.leading, 14) }
                Menu {
                    ForEach(FieldKind.allKnown, id: \.self) { kind in
                        Button {
                            section.fields.append(ItemField(label: kind.label, kind: kind))
                        } label: {
                            Label(kind.label, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("添加配置项", systemImage: "plus").font(.system(size: 12.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 14).padding(.vertical, 9)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    onDrop(id, nil, section.id)
                    return true
                }
            }
        }
    }
}

/// 一个配置项的编辑行：名称可改，值按类型给输入框；密码可调出生成器；悬停时显示删除。
struct FieldEditRow: View {
    @Binding var field: ItemField
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var showGenerator = false

    private var monospaced: Bool { field.monospace || [.password, .secret, .totp].contains(field.kind) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.top, 22)
                .help("拖动排序")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    TextField(field.kind.label, text: $field.label)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Image(systemName: field.kind.symbol).font(.system(size: 9)).foregroundStyle(.tertiary)
                        .help(field.kind.label)
                }
                if field.kind == .multiline {
                    TextEditor(text: $field.value)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(minHeight: 96)
                        .editorBox()
                } else {
                    HStack(spacing: 6) {
                        TextField(field.kind.placeholder, text: $field.value)
                            .textFieldStyle(.roundedBorder)
                            .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
                            .autocorrectionDisabled()
                        if field.kind == .password {
                            Button { showGenerator = true } label: { Label("生成", systemImage: "dice") }
                                .help("生成密码")
                                .popover(isPresented: $showGenerator) {
                                    GeneratorView(onUse: { pw in
                                        field.value = pw
                                        showGenerator = false
                                    })
                                    .frame(width: 460)
                                }
                        }
                    }
                }
                if let hint = field.kind.formatHint(for: field.value) {
                    Text(hint).font(.system(size: 11)).foregroundStyle(Theme.danger)
                }
            }

            Button(action: onDelete) { Image(systemName: "minus.circle.fill").font(.system(size: 14)) }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.danger)
                .opacity(hovering ? 1 : 0)
                .padding(.top, 22)
                .help("删除这个配置项")
        }
        .padding(.leading, 10).padding(.trailing, 10).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Toggle("等宽显示", isOn: $field.monospace)
            Button("删除配置项", role: .destructive, action: onDelete)
        }
    }
}

extension View {
    /// TextEditor 套上和输入框一样的边框
    func editorBox() -> some View {
        scrollContentBackground(.hidden)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
    }
}

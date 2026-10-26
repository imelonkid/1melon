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

/// 条目详情的编辑态正文（标题以下）：和查看态同样的布局，分组和字段都可以增删、改名、拖动排序。
/// 标题行在 `ItemPane` 里，查看和编辑共用，所以切换时标题、图标、信息栏都不动。
struct ItemEditBody: View {
    @Binding var draft: ItemDraft
    let onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
            VStack(alignment: .leading, spacing: 0) {

                ForEach($draft.item.sections) { $section in
                    SectionEditor(
                        section: $section,
                        onDeleteSection: { draft.item.sections.removeAll { $0.id == section.id } },
                        onDrop: moveField
                    )
                    // 和查看态一样：第一个分组离标题 20pt，之后每个 14pt，切换时卡片不跳
                    .padding(.top, section.id == draft.item.sections.first?.id ? 20 : 14)
                }

                Button {
                    draft.item.sections.append(ItemSection(title: "", fields: [ItemField(label: FieldKind.text.label, kind: .text)]))
                } label: {
                    Label("添加分组", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .padding(.top, 14)

                labeled(draft.item.type == .note ? "内容" : "备注") {
                    TextEditor(text: $draft.item.notes)
                        .font(draft.item.type == .note ? .system(size: 13.5, design: .monospaced) : Typo.fieldValue)
                        .frame(minHeight: draft.item.type == .note ? 200 : 64)
                        .editorBox()
                }
                .padding(.top, 22)

                labeled("标签") {
                    TextField("用逗号分隔，例如：工作, 开发", text: $draft.tagsText).textFieldStyle(.roundedBorder).font(.system(size: 13.5))
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
    }

    /// 把字段 `id` 挪到 `target` 前面（可以跨分组）；`target` 为 nil 时放到 `section` 的末尾
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
            Text(label).font(Typo.fieldLabel).foregroundStyle(Theme.accent)
            content()
        }
    }
}

/// 一个分组：标题可改、整个分组可删；字段可增删、拖动排序。
struct SectionEditor: View {
    @Binding var section: ItemSection
    let onDeleteSection: () -> Void
    let onDrop: (_ id: String, _ before: String?, _ inSection: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("分组标题（可选）", text: $section.title)
                    .textFieldStyle(.plain)
                    .font(Typo.sectionTitle)
                    .foregroundStyle(.secondary)
                Button(action: onDeleteSection) { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("删除这个分组")
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
                    Label("添加字段", systemImage: "plus").font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 16).padding(.vertical, 10)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    onDrop(id, nil, section.id)
                    return true
                }
            }
        }
    }
}

/// 一个字段的编辑行：和查看时同样的样子（名称在上、值在下），只是可以直接输入。
/// 不再在卡片里套带边框的输入框；正在输入的那一行背景淡淡高亮。拖动把手和删除按钮悬停时才出现。
struct FieldEditRow: View {
    @Binding var field: ItemField
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var showGenerator = false
    private enum Part { case label, value }
    @FocusState private var focus: Part?
    /// 点了遮住的值、要开始输入：先换成输入框，再把焦点给它
    @State private var editingSecret = false

    /// 密码、隐藏文本、多行文本（私钥）在没有输入焦点时遮住，不明文停留在屏幕上
    private var masked: Bool {
        field.kind.isConcealed && !field.value.isEmpty && focus != .value && !editingSecret
    }

    private var monospaced: Bool { field.monospace || [.password, .secret, .totp].contains(field.kind) }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(field.kind.label, text: $field.label)
                    .textFieldStyle(.plain)
                    .font(Typo.fieldLabel)
                    .foregroundStyle(Theme.accent)
                    .focused($focus, equals: .label)
                if masked {
                    Button {
                        editingSecret = true
                        Task { @MainActor in
                            focus = .value
                            // 兜底：输入框没拿到焦点就恢复遮住，不让明文一直留在屏幕上
                            try? await Task.sleep(for: .milliseconds(300))
                            if focus != .value { editingSecret = false }
                        }
                    } label: {
                        Text(field.kind == .multiline ? "••••••••••••••••••••••••••••••••\n••••••••••••••••••••••••" : "••••••••••••")
                            .font(field.kind == .multiline ? .system(size: 12.5, design: .monospaced) : Typo.fieldValue)
                            .kerning(1.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("点击编辑")
                } else if field.kind == .multiline {
                    TextEditor(text: $field.value)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 96)
                        .focused($focus, equals: .value)
                } else {
                    TextField(field.kind.placeholder.isEmpty ? "未填写" : field.kind.placeholder, text: $field.value)
                        .textFieldStyle(.plain)
                        .font(monospaced ? Typo.fieldValueMono : Typo.fieldValue)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .value)
                }
                if let hint = field.kind.formatHint(for: field.value) {
                    Text(hint).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if field.kind == .password {
                Button { showGenerator = true } label: { Label("生成", systemImage: "dice") }
                    .controlSize(.small)
                    .help("生成密码")
                    .popover(isPresented: $showGenerator) {
                        GeneratorView(onUse: { pw in
                            field.value = pw
                            showGenerator = false
                        })
                        .frame(width: 460)
                    }
            }
            Button(action: onDelete) { Image(systemName: "minus.circle.fill").font(.system(size: 15)) }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.danger)
                .opacity(hovering ? 1 : 0)
                .help("删除这个字段")
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, Typo.rowVerticalPadding)
        .background(focus != nil ? Theme.accent.opacity(0.06) : .clear)
        .overlay(alignment: .leading) {
            // 拖动把手：悬停时才出现，放在左侧留白里
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.leading, 3)
                .opacity(hovering ? 1 : 0)
                .help("拖动排序")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: focus) { _, new in
            // 输入框拿到过焦点后，离开时恢复遮住
            if new == .value { editingSecret = false }
        }
        .contextMenu {
            Toggle("等宽显示", isOn: $field.monospace)
            Button("删除字段", role: .destructive, action: onDelete)
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

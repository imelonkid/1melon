import MelonCore
import SwiftUI

/// 新建 / 编辑条目（设计稿「新建/编辑条目」）。新建时先选类型。
struct ItemEditorView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let request: EditorRequest
    /// 关闭时回调：保存了就是条目 id，取消或删除是 nil
    let onClose: (String?) -> Void

    @State private var draft: VaultItem?
    @State private var tagsText = ""
    @State private var generatorFor: String?
    @State private var confirmDelete = false

    private var isNew: Bool { request.item == nil }

    var body: some View {
        Group {
            if draft != nil {
                form
            } else {
                typePicker
            }
        }
        .frame(width: 540)
        .onAppear {
            if let item = request.item {
                draft = item
                tagsText = item.tags.joined(separator: ", ")
            }
        }
    }

    // MARK: 选类型

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("新建条目").font(.system(size: 15, weight: .semibold))
            Text("选择要保存的内容类型").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ItemType.allKnown, id: \.self) { t in
                    Button {
                        draft = VaultItem.fromTemplate(t, now: Date().unixMilliseconds)
                    } label: {
                        Label(t.label, systemImage: t.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.background))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
                }
            }
            .padding(.top, 16)
            HStack {
                Spacer()
                Button("取消") { close(nil) }.keyboardShortcut(.cancelAction)
            }
            .padding(.top, 18)
        }
        .padding(22)
    }

    // MARK: 表单

    private var form: some View {
        let binding = Binding(get: { draft! }, set: { draft = $0 })
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                ItemIcon(type: binding.wrappedValue.type, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("标题", text: binding.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(isNew ? "新建" : "编辑") · \(binding.wrappedValue.type.label)")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(binding.sections) { $section in
                        VStack(alignment: .leading, spacing: 12) {
                            if !section.title.isEmpty {
                                Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            ForEach($section.fields) { $field in
                                FieldEditor(field: $field, generate: { generatorFor = field.id })
                                    .popover(isPresented: Binding(get: { generatorFor == field.id }, set: { if !$0 { generatorFor = nil } })) {
                                        GeneratorView(onUse: { pw in
                                            field.value = pw
                                            generatorFor = nil
                                        })
                                        .frame(width: 460)
                                    }
                            }
                        }
                    }
                    labeled(binding.wrappedValue.type == .note ? "内容" : "备注") {
                        TextEditor(text: binding.notes)
                            .font(binding.wrappedValue.type == .note ? .system(size: 12, design: .monospaced) : .system(size: 13))
                            .frame(height: binding.wrappedValue.type == .note ? 200 : 64)
                            .editorBox()
                    }
                    labeled("标签") {
                        TextField("用逗号分隔，例如：工作, 开发", text: $tagsText).textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
            }
            .frame(maxHeight: 480)

            Divider()
            HStack(spacing: 8) {
                if !isNew {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                        .foregroundStyle(Theme.danger)
                        .confirmationDialog("删除「\(binding.wrappedValue.title)」？", isPresented: $confirmDelete) {
                            Button("删除", role: .destructive) { deleteItem() }
                        } message: {
                            Text("删除后无法恢复。")
                        }
                }
                Spacer()
                Button("取消") { close(nil) }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        guard var item = draft else { return }
        item.title = item.title.trimmingCharacters(in: .whitespaces)
        if item.title.isEmpty { item.title = item.type.label }
        item.tags = tagsText.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        session.save(item)
        close(session.saveError == nil ? item.id : nil)
    }

    private func deleteItem() {
        guard let id = draft?.id else { return }
        session.delete(id: id)
        close(nil)
    }

    private func close(_ id: String?) {
        onClose(id)
        dismiss()
    }
}

/// 一个字段的输入框：密码字段带「生成」按钮，多行字段用文本框。
struct FieldEditor: View {
    @Binding var field: ItemField
    let generate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            if field.kind == .multiline {
                TextEditor(text: $field.value)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(height: 96)
                    .editorBox()
            } else {
                HStack(spacing: 6) {
                    TextField(placeholder, text: $field.value)
                        .textFieldStyle(.roundedBorder)
                        .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
                        .autocorrectionDisabled()
                    if field.kind == .password {
                        Button(action: generate) { Label("生成", systemImage: "dice") }
                            .help("生成密码")
                    }
                }
                if field.kind == .totp, !field.value.isEmpty, (try? TOTP.parse(field.value)) == nil {
                    Text("格式不对：要 Base32 密钥或 otpauth:// 链接").font(.system(size: 11)).foregroundStyle(Theme.danger)
                }
            }
        }
    }

    private var monospaced: Bool { field.monospace || [.password, .secret, .totp].contains(field.kind) }

    private var placeholder: String {
        switch field.kind {
        case .totp: "粘贴密钥或 otpauth:// 链接（可选）"
        case .url: "example.com"
        case .email: "name@example.com"
        case .date: "1990-05-21"
        case .monthYear: "2029-08"
        default: ""
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

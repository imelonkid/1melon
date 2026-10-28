import MelonCore
import SwiftUI

/// 新建（`vault == nil`）或编辑保险库的请求
struct VaultEditRequest: Identifiable {
    let id = UUID()
    var vault: VaultMeta?
    var vaultId: String?
}

/// 保险库的名字和图标（颜色不再让选：新建用默认值，编辑时保留原来的）。
struct VaultEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: VaultEditRequest
    let onSave: (_ name: String, _ icon: String, _ color: String) -> Void

    @State private var name = ""
    @State private var icon = "folder"
    @State private var color = "blue"

    private var preview: VaultMeta { VaultMeta(name: name, icon: icon, color: color, created: 0) }

    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(request.vault == nil ? "新建保险库" : "编辑保险库")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)

            HStack(spacing: 12) {
                VaultBadge(meta: preview, size: 44)
                TextField("保险库名称", text: $name)
                    .font(.system(size: 14))
                    .focused($nameFocused)
                    .boxField(focused: nameFocused, height: 40, radius: 11)
                    .onSubmit(save)
            }
            .padding(.top, 18)

            Text("图标").font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.top, 20).padding(.bottom, 8)
            // 两行五个：图标格子按宽度平分，不会挤出对话框
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                ForEach(VaultMeta.icons, id: \.self) { i in
                    Button { icon = i } label: {
                        Image(systemName: VaultStyle.symbol(i)).font(.system(size: 16))
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 10).fill(icon == i ? Theme.accentSoft : Theme.hover))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(icon == i ? Theme.accent : .clear, lineWidth: 1))
                            .foregroundStyle(icon == i ? Theme.accentText : Theme.text2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(PaneButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(request.vault == nil ? "新建" : "保存", action: save)
                    .buttonStyle(PaneButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            }
            .padding(.top, 24)
        }
        .padding(28)
        .frame(width: 440)
        .background(Theme.bg)
        .onAppear {
            if let v = request.vault {
                name = v.name
                icon = v.icon
                color = v.color
            }
            nameFocused = true
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onSave(n, icon, color)
        dismiss()
    }
}

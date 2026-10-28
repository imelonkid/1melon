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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.vault == nil ? "新建保险库" : "编辑保险库").font(.system(size: 15, weight: .semibold))

            HStack(spacing: 12) {
                VaultBadge(meta: preview, size: 40)
                TextField("保险库名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .onSubmit(save)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("图标").font(.system(size: 11)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 10), spacing: 8) {
                    ForEach(VaultMeta.icons, id: \.self) { i in
                        Button { icon = i } label: {
                            Image(systemName: VaultStyle.symbol(i)).font(.system(size: 14))
                                .frame(width: 34, height: 30)
                                .background(RoundedRectangle(cornerRadius: 7).fill(icon == i ? Theme.accentSoft : Theme.hover))
                                .foregroundStyle(icon == i ? Theme.accentText : Theme.text2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.vault == nil ? "新建" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            if let v = request.vault {
                name = v.name
                icon = v.icon
                color = v.color
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onSave(n, icon, color)
        dismiss()
    }
}

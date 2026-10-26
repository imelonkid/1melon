import AppKit
import MelonCore
import SwiftUI
import UniformTypeIdentifiers

/// 导出：选保险库 → 再输一次主密码 → 选保存位置 → 写明文 CSV（权限 0600）→ 提醒用完删掉。
struct ExportSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var password = ""
    @State private var error: String?
    @State private var exported: (count: Int, url: URL)?
    @FocusState private var passwordFocused: Bool

    private var count: Int { session.exportEntries(vaultIds: selected).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导出").font(.system(size: 15, weight: .semibold))
            if let exported { doneView(exported.count, exported.url) } else { formView }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { selected = Set(session.vaults.map(\.vaultId)) }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("导出的文件是明文", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warn)
                Text("CSV 里的密码不加密，任何能读到这个文件的人都能看到。只在要换到别的密码管理器时导出，用完马上删掉。日常备份用「设置 → 数据」里的自动备份，那是加密的。")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warn.opacity(0.1)))

            VStack(alignment: .leading, spacing: 6) {
                Text("保险库").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(session.vaults, id: \.vaultId) { v in
                    Toggle(isOn: Binding(get: { selected.contains(v.vaultId) },
                                         set: { if $0 { selected.insert(v.vaultId) } else { selected.remove(v.vaultId) } })) {
                        HStack {
                            Text(v.meta.name)
                            Text("\(v.activeItems.count) 个").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.system(size: 13))
                    }
                }
            }
            Text("格式：CSV，Chrome、Bitwarden 和 1Melon 都能导入。没有专门列的字段（卡号、自定义字段等）写在备注里；网站图标不导出。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("输入主密码确认").font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField("主密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                    .onSubmit(export)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            }

            HStack {
                if session.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出 \(count) 个条目…", action: export)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(count == 0 || password.isEmpty || session.isWorking)
            }
        }
        .onAppear { passwordFocused = true }
    }

    private func export() {
        guard count > 0, !password.isEmpty, !session.isWorking else { return }
        let entered = password
        Task {
            guard await session.verifyPassword(entered) else {
                error = "主密码不对"
                return
            }
            password = ""
            error = nil
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "1Melon 导出 \(Date().formatted(.iso8601.year().month().day())).csv"
            panel.message = "导出的文件是明文，用完请删掉"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let entries = session.exportEntries(vaultIds: selected)
            do {
                // 原子写入，权限 0600；UTF-8 带 BOM，Excel / Numbers 打开中文不乱码
                try VaultStore.write(Data(("\u{FEFF}" + Exporter.csv(entries)).utf8), to: url)
                exported = (entries.count, url)
            } catch {
                self.error = "写入失败：\(error.localizedDescription)"
            }
        }
    }

    private func doneView(_ count: Int, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("已导出 \(count) 个条目", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ok)
            VStack(alignment: .leading, spacing: 6) {
                Label("用完记得删掉", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warn)
                Text("「\(url.lastPathComponent)」里的密码是明文。导入到别处之后，把它移到废纸篓并清倒。")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warn.opacity(0.1)))
            HStack {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }
}

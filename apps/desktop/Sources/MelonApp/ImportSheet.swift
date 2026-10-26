import AppKit
import MelonCore
import SwiftUI
import UniformTypeIdentifiers

/// 导入：选文件 → 预览（几个保险库、多少条目、哪些导入不了）→ 选目标 → 导入 → 提醒删掉明文导出文件。
/// 文件只在内存里解析，不复制、不缓存；导入后原文件留给用户自己删。
struct ImportSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let defaultVaultId: String?
    let onDone: (_ imported: Int) -> Void

    private enum Phase {
        case pick
        case parsing
        case preview(ImportResult, URL)
        case done(VaultSession.ImportOutcome, URL)
    }

    @State private var phase: Phase = .pick
    @State private var error: String?
    /// 1Password 导出里带保险库名：默认按原保险库分别导入
    @State private var byVault = true
    @State private var targetId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入").font(.system(size: 15, weight: .semibold))
            switch phase {
            case .pick, .parsing: pickView
            case .preview(let result, let url): previewView(result, url)
            case .done(let outcome, let url): doneView(outcome, url)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { targetId = defaultVaultId ?? session.vaults.first?.vaultId }
    }

    // MARK: 选文件

    private var pickView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                format("1Password", ".1pux", "1Password 8：文件 → 导出 → 1PUX")
                format("Bitwarden", ".json", "工具 → 导出密码库 → .json（不要选加密）")
                format("浏览器", ".csv", "Chrome、Safari、Firefox、Edge 导出的密码 CSV")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if case .parsing = phase { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("选择文件…", action: pickFile)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled({ if case .parsing = phase { true } else { false } }())
            }
        }
    }

    private func format(_ name: String, _ ext: String, _ hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name).font(.system(size: 13, weight: .medium)).frame(width: 78, alignment: .leading)
            Text(ext).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "1pux") ?? .data, .json, .commaSeparatedText]
        panel.message = "选择导出的文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        phase = .parsing
        Task {
            let parsed = await Task.detached { () -> Result<ImportResult, Error> in
                Result {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= 300 * 1024 * 1024 else { throw ImportError.unrecognized("文件太大（超过 300 MB）") }
                    return try Importer.parse(fileName: url.lastPathComponent, data: Data(contentsOf: url))
                }
            }.value
            switch parsed {
            case .success(let result) where result.itemCount == 0:
                error = "文件里没有可以导入的条目"
                phase = .pick
            case .success(let result):
                byVault = result.vaults.contains { $0.name != nil }
                phase = .preview(result, url)
            case .failure(let e):
                error = Self.describe(e)
                phase = .pick
            }
        }
    }

    private static func describe(_ e: Error) -> String {
        if case ImportError.unrecognized(let why) = e { return why }
        if e is DecodingError { return "读不懂这个文件，确认是上面列出的导出格式" }
        #if canImport(Compression)
        if e is ZipReader.Failure { return ".1pux 文件损坏，或者用了不支持的压缩方式" }
        #endif
        return "读取失败：\(e.localizedDescription)"
    }

    // MARK: 预览

    private func previewView(_ result: ImportResult, _ url: URL) -> some View {
        let named = result.vaults.contains { $0.name != nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("· \(result.source)").foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))

            VStack(spacing: 0) {
                ForEach(Array(result.vaults.enumerated()), id: \.offset) { i, v in
                    if i > 0 { Divider() }
                    HStack {
                        Text(v.name ?? "条目").font(.system(size: 13))
                        Spacer()
                        Text("\(v.items.count) 个").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))

            if !result.skipped.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(result.skipped.enumerated()), id: \.offset) { _, s in
                                Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                } label: {
                    Label("\(result.skipped.count) 项导入不了（附件等）", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.warn)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("导入到").font(.system(size: 11)).foregroundStyle(.secondary)
                if named {
                    Picker("", selection: $byVault) {
                        Text("按原保险库分别导入（没有同名的就新建）").tag(true)
                        Text("全部导入到一个保险库").tag(false)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
                if !named || !byVault {
                    Picker("", selection: $targetId) {
                        ForEach(session.vaults, id: \.vaultId) { v in Text(v.meta.name).tag(Optional(v.vaultId)) }
                    }
                    .labelsHidden().frame(width: 220)
                }
            }
            Text("已有的相同条目（标题、网址、密码都一样）会跳过。")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入 \(result.itemCount) 个条目") { runImport(result, url) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }

    private func runImport(_ result: ImportResult, _ url: URL) {
        var total = VaultSession.ImportOutcome()
        let named = result.vaults.contains { $0.name != nil }
        if named && byVault {
            for v in result.vaults {
                let o = session.importItems(v.items, vaultName: v.name, vaultId: targetId)
                total.imported += o.imported
                total.duplicates += o.duplicates
            }
        } else {
            total = session.importItems(result.vaults.flatMap(\.items), vaultName: nil, vaultId: targetId)
        }
        guard session.saveError == nil else { dismiss(); return }
        onDone(total.imported)
        phase = .done(total, url)
    }

    // MARK: 完成

    private func doneView(_ outcome: VaultSession.ImportOutcome, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(outcome.duplicates > 0 ? "已导入 \(outcome.imported) 个条目，跳过 \(outcome.duplicates) 个重复的"
                  : "已导入 \(outcome.imported) 个条目", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ok)
            VStack(alignment: .leading, spacing: 6) {
                Label("记得删掉导出文件", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warn)
                Text("「\(url.lastPathComponent)」里的密码是明文，任何能读到这个文件的人都能看到。确认导入无误后，把它移到废纸篓并清倒。")
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

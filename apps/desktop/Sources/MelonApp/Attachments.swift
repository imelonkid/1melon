import AppKit
import MelonCore
import SwiftUI

/// 文件附件的读写（spec §5.4）：选文件放进字段、把内容存回磁盘。明文只写到用户在保存面板里选的位置。
@MainActor
enum AttachmentIO {
    /// 打开面板选一个文件，放进字段。超过 1 MiB 返回错误提示
    static func pick(into field: inout ItemField) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选一个文件放进保险库（不超过 1 MB）"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= ItemField.maxAttachmentBytes else { return tooLarge(size) }
            try field.attach(Data(contentsOf: url), name: url.lastPathComponent)
            return nil
        } catch ItemField.AttachmentError.tooLarge(let n) {
            return tooLarge(n)
        } catch {
            return "读不了这个文件：\(error.localizedDescription)"
        }
    }

    /// 存到用户选的位置
    static func save(_ field: ItemField) -> Bool {
        guard let data = field.attachmentData else { return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = field.fileName ?? (field.label.isEmpty ? "附件" : field.label)
        panel.message = "存出来的是明文，用完记得删掉"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    private static func tooLarge(_ n: Int) -> String {
        "文件 \(formatBytes(n))，超过 1 MB 上限"
    }
}

/// 字节数写成「411 字节」「12.3 KB」「1.0 MB」
func formatBytes(_ n: Int) -> String {
    if n < 1024 { return "\(n) 字节" }
    if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
    return String(format: "%.1f MB", Double(n) / 1024 / 1024)
}

/// 附件的样子：回形针 + 文件名 + 大小（查看和编辑共用）
struct AttachmentLabel: View {
    let field: ItemField

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(Theme.text2)
            if let size = field.attachmentSize {
                Text(field.fileName ?? "附件").font(Typo.fieldValue).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(formatBytes(size)).font(.system(size: 12)).foregroundStyle(Theme.text3)
            } else {
                Text("未选择文件").font(Typo.fieldValue).foregroundStyle(Theme.text3)
            }
        }
    }
}

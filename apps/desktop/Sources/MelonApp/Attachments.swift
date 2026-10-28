import AppKit
import MelonCore
import SwiftUI

/// 文件附件的读写（spec §3.5、§5.4）：选文件加密成附件、把内容存回磁盘。明文只写到用户在保存面板里选的位置。
@MainActor
enum AttachmentIO {
    /// 打开面板选一个文件，加密后放进字段（附件文件等条目保存时才写盘）。超过 5 MiB 或读不了返回错误提示
    static func pick(into field: inout ItemField, session: VaultSession) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选一个文件放进保险库（不超过 5 MB）"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= AttachmentFile.maxBytes else { return tooLarge(size) }
            field.attach(try session.newAttachment(Data(contentsOf: url)), name: url.lastPathComponent)
            return nil
        } catch AttachmentFile.AttachmentError.tooLarge(let n) {
            return tooLarge(n)
        } catch {
            return "读不了这个文件：\(error.localizedDescription)"
        }
    }

    /// 解开附件，存到用户选的位置。附件缺失或打不开时返回说明
    static func save(_ field: ItemField, session: VaultSession) -> Result<Bool, AttachmentProblem> {
        guard let ref = field.attachment else { return .success(false) }
        let data: Data
        do {
            guard let d = try session.attachmentData(ref) else { return .failure(.missing) }
            data = d
        } catch {
            return .failure(.broken)
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = field.fileName ?? (field.label.isEmpty ? "附件" : field.label)
        panel.message = "存出来的是明文，用完记得删掉"
        guard panel.runModal() == .OK, let url = panel.url else { return .success(false) }
        return .success((try? data.write(to: url, options: .atomic)) != nil)
    }

    enum AttachmentProblem: Error {
        /// 本机还没有这个附件文件（还没同步下来，或者丢了）
        case missing
        /// 附件文件打不开：损坏或被篡改
        case broken

        var message: String {
            switch self {
            case .missing: "附件还没同步到这台 Mac"
            case .broken: "附件文件损坏，打不开"
            }
        }
    }

    private static func tooLarge(_ n: Int) -> String {
        "文件 \(formatBytes(n))，超过 5 MB 上限"
    }
}

/// 字节数写成「411 字节」「12.3 KB」「1.0 MB」
func formatBytes(_ n: Int) -> String {
    if n < 1024 { return "\(n) 字节" }
    if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
    return String(format: "%.1f MB", Double(n) / 1024 / 1024)
}

/// 附件的样子：回形针 + 文件名 + 大小（查看和编辑共用）。附件文件不在本机时加一句提示
struct AttachmentLabel: View {
    let field: ItemField
    @Environment(VaultSession.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(Theme.text2)
            if let ref = field.attachment {
                Text(field.fileName ?? "附件").font(Typo.fieldValue).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(formatBytes(ref.size)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                if !session.hasAttachment(ref) {
                    Text("还没同步到本机").font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
            } else {
                Text("未选择文件").font(Typo.fieldValue).foregroundStyle(Theme.text3)
            }
        }
    }
}

import Crypto
import Foundation

/// 字段里的附件引用（spec §5.4）：附件文件的 id、解开它的密钥 FK、明文字节数。跟着条目一起被 VK 加密。
public struct AttachmentRef: Codable, Equatable, Sendable {
    public var id: String
    /// FK：32 字节，每个附件一把（spec §3.5）
    public var key: Data
    /// 明文字节数：显示用，打开时核对
    public var size: Int

    public init(id: String, key: Data, size: Int) {
        self.id = id
        self.key = key
        self.size = size
    }
}

/// 附件文件 `attachments/<attachmentId>.1melon`（spec §3.5）：内容不可变，换文件就换一个新的附件。
public enum AttachmentFile {
    static let formatName = "1melon-attachment"
    static let currentVersion = 1
    /// 单个附件明文的上限：5 MiB
    public static let maxBytes = 5_242_880

    public enum AttachmentError: Error, Equatable {
        case tooLarge(Int)
    }

    struct File: Codable {
        var format = AttachmentFile.formatName
        var version = AttachmentFile.currentVersion
        var attachmentId: String
        var accountId: String
        var content: Sealed
    }

    /// 加密一个新附件：新的 id、新的 FK。返回字段里要存的引用和要写盘的文件内容
    public static func seal(_ data: Data, accountId: String) throws -> (ref: AttachmentRef, file: Data) {
        guard data.count <= maxBytes else { throw AttachmentError.tooLarge(data.count) }
        let id = newID()
        let key = SymmetricKey(size: .bits256)
        let content = try MelonCore.seal(data, key: key, aad: AAD.attachment(accountId, id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let file = try encoder.encode(File(attachmentId: id, accountId: accountId, content: content))
        return (AttachmentRef(id: id, key: key.withUnsafeBytes { Data($0) }, size: data.count), file)
    }

    /// 按 spec §4「每个附件文件」的顺序打开：格式和版本、id 和账户、解密、核对大小。
    public static func open(_ data: Data, ref: AttachmentRef, accountId: String) throws -> Data {
        let file = try decode(data)
        guard file.accountId == accountId else { throw VaultError.invalidFormat("这个附件不属于当前账户") }
        guard file.attachmentId == ref.id, ref.key.count == 32 else { throw VaultError.tampered("附件和引用对不上") }
        let plain: Data
        do {
            plain = try unseal(file.content, key: SymmetricKey(data: ref.key), aad: AAD.attachment(accountId, ref.id))
        } catch {
            throw VaultError.tampered("附件无法解密")
        }
        guard plain.count == ref.size else { throw VaultError.tampered("附件大小和引用对不上") }
        return plain
    }

    static func decode(_ data: Data) throws -> File {
        struct Head: Decodable { var format: String?; var version: Int? }
        guard let head = try? JSONDecoder().decode(Head.self, from: data), head.format == formatName, let version = head.version else {
            throw VaultError.invalidFormat("不是 1Melon 附件")
        }
        // 先看版本：新版本的其余结构可能不一样，不往下解析
        guard version <= currentVersion else { throw VaultError.unsupportedVersion(version) }
        guard version >= 1 else { throw VaultError.invalidFormat("格式版本 \(version) 无效") }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { throw VaultError.invalidFormat("附件结构无法解析") }
        guard isLowercaseUUID(file.attachmentId), isLowercaseUUID(file.accountId) else {
            throw VaultError.invalidFormat("attachmentId 或 accountId 不是小写 UUID")
        }
        return file
    }
}

extension UnlockedVault {
    /// 这个保险库里的条目引用的全部附件（墓碑没有字段，不算）
    public var attachmentRefs: [String: AttachmentRef] {
        var out: [String: AttachmentRef] = [:]
        for item in items {
            for f in item.allFields where f.kind == .file {
                if let ref = f.attachment { out[ref.id] = ref }
            }
        }
        return out
    }
}

// MARK: 本机的附件文件

public extension AccountRepository {
    var attachmentsDirectory: URL { root.appendingPathComponent("attachments") }
    func attachmentURL(_ id: String) -> URL { attachmentsDirectory.appendingPathComponent("\(id).1melon") }

    /// 本机所有附件文件的 id
    func localAttachmentIds() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: attachmentsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "1melon" }.map { $0.deletingPathExtension().lastPathComponent }.filter(isLowercaseUUID)
    }

    /// 读附件的明文。本机还没有这个文件（没下载下来、缺失）返回 nil；打不开抛 `VaultError`
    func readAttachment(_ ref: AttachmentRef, accountId: String) throws -> Data? {
        guard let data = try? VaultStore.read(attachmentURL(ref.id)) else { return nil }
        return try AttachmentFile.open(data, ref: ref, accountId: accountId)
    }

    /// 清理本机的孤儿附件（spec §3.5）：没被 `referenced` 引用、修改时间早于 `now` 一小时以上的才删。
    /// 只在全部保险库都打开成功时调用：打不开的保险库里可能还有引用。返回删掉的 id
    @discardableResult
    func sweepOrphanAttachments(referenced: Set<String>, now: Date) -> [String] {
        localAttachmentIds().filter { id in
            guard !referenced.contains(id), Self.isStale(attachmentURL(id), now: now) else { return false }
            return (try? FileManager.default.removeItem(at: attachmentURL(id))) != nil
        }
    }

    /// 孤儿附件留一小时再删：刚写好的附件，引用它的保险库可能还没写盘
    static let orphanGrace: TimeInterval = 3600

    static func isStale(_ url: URL, now: Date) -> Bool {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        return now.timeIntervalSince(modified) > orphanGrace
    }
}

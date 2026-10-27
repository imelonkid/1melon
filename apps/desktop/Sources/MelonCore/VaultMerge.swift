import Crypto
import Foundation

/// 同一个保险库的两份（本机、云端）按条目合并（spec §8）。
///
/// - `id` 只在一边有：保留。
/// - 两边都有：`rev` 大的胜出。
/// - `rev` 相同、内容不同：`modified` 晚的胜出；再相同就比条目密文（nonce ‖ ct）的字节，大的胜出。
///   输的那份另存为冲突副本（墓碑不另存）。
///
/// 结果和合并顺序无关（交换律）：同一个 `id` + `rev` 的密文在各台设备上都一样（没改过的条目沿用原密文），
/// 所以胜负和冲突副本的 `id` 都按密文算，两台设备各自合并会得到同一份副本，不依赖各端 JSON 编码是否一致。
public enum VaultMerge {
    public struct Report: Sendable, Equatable {
        /// 采用了云端版本的条目数（新增或更新）
        public var fromRemote = 0
        /// 新生成的冲突副本
        public var conflicts = 0
    }

    public enum MergeError: Error, Equatable {
        /// 不是同一个保险库，或者两份的保险库密钥不同（不应该发生）
        case differentVault
    }

    /// 冲突副本标题的后缀。各端必须一致，否则两台设备生成的副本对不上
    public static let conflictSuffix = "（冲突副本）"

    public static func merge(local: UnlockedVault, remote: UnlockedVault) throws -> (UnlockedVault, Report) {
        guard local.vaultId == remote.vaultId, local.accountId == remote.accountId,
              local.vaultKey.withUnsafeBytes({ Data($0) }) == remote.vaultKey.withUnsafeBytes({ Data($0) })
        else { throw MergeError.differentVault }

        var report = Report()
        var merged = local
        let remoteById = Dictionary(remote.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var copies: [VaultItem] = []

        for (i, mine) in merged.items.enumerated() {
            guard let theirs = remoteById[mine.id] else { continue }
            let takeRemote: Bool
            if mine.rev != theirs.rev {
                takeRemote = theirs.rev > mine.rev
            } else {
                if canonical(mine) == canonical(theirs) { continue }
                let a = sealedBytes(mine, in: local), b = sealedBytes(theirs, in: remote)
                takeRemote = theirs.modified != mine.modified ? theirs.modified > mine.modified : a.lexicographicallyPrecedes(b)
                let loser = takeRemote ? mine : theirs
                if !loser.deleted { copies.append(conflictCopy(of: loser, sealed: takeRemote ? a : b, vaultId: local.vaultId)) }
            }
            if takeRemote {
                merged.items[i] = theirs
                merged.sealedCache[theirs.id] = remote.sealedCache[theirs.id]
                report.fromRemote += 1
            }
        }
        let localIds = Set(local.items.map(\.id))
        for theirs in remote.items where !localIds.contains(theirs.id) {
            merged.items.append(theirs)
            merged.sealedCache[theirs.id] = remote.sealedCache[theirs.id]
            report.fromRemote += 1
        }
        let existing = Set(merged.items.map(\.id))
        for copy in copies where !existing.contains(copy.id) {
            merged.items.append(copy)
            merged.sealedCache[copy.id] = nil
            report.conflicts += 1
        }

        // 元数据（名称、图标、颜色、排序）没有自己的修订号：取最近写出的那份，同时写出的比字节
        if remote.updated > local.updated
            || (remote.updated == local.updated && canonicalMeta(local.meta).lexicographicallyPrecedes(canonicalMeta(remote.meta))) {
            merged.meta = remote.meta
        }
        merged.updated = max(local.updated, remote.updated)
        return (merged, report)
    }

    /// 条目在文件里的密文 nonce ‖ ct。还没写出过的条目（内存里刚改的）没有密文，退回明文规范字节
    static func sealedBytes(_ item: VaultItem, in vault: UnlockedVault) -> Data {
        guard let s = vault.sealedCache[item.id], s.rev == item.rev else { return canonical(item) }
        return s.nonce + s.ct
    }

    /// 明文的规范字节：排好键的 JSON（只在本机比较「内容是否相同」，不跨端、不落盘）
    static func canonical(_ item: VaultItem) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(ItemPlaintext(item))) ?? Data()
    }

    static func canonicalMeta(_ meta: VaultMeta) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(meta)) ?? Data()
    }

    /// 冲突副本：内容同输掉的那份，标题加后缀，`rev` = 1。
    /// `id` = SHA-256("1melon:v1:conflict:<vaultId>:<id>:<rev>:" ‖ 输的那份的 nonce ‖ ct) 的前 16 字节，
    /// 按 UUID v4 的格式写（版本位、变体位照改，spec §8）
    static func conflictCopy(of loser: VaultItem, sealed: Data, vaultId: String) -> VaultItem {
        var hash = SHA256()
        hash.update(data: Data("1melon:v1:conflict:\(vaultId):\(loser.id):\(loser.rev):".utf8))
        hash.update(data: sealed)
        var b = Array(Data(hash.finalize()).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        let h = b.map { String(format: "%02x", $0) }.joined()
        let parts = [h.prefix(8), h.dropFirst(8).prefix(4), h.dropFirst(12).prefix(4), h.dropFirst(16).prefix(4), h.dropFirst(20)]
        var copy = loser
        copy.id = parts.map(String.init).joined(separator: "-")
        copy.rev = 1
        copy.title = loser.title + conflictSuffix
        return copy
    }
}

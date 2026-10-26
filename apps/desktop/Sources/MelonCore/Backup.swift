import Foundation

/// 本地自动备份：把**加密的**账户文件和保险库文件原样复制一份，不解密、不碰明文。
/// 每次备份是目标目录下的一个文件夹 `1Melon-<yyyyMMdd-HHmmss>/`，里面是 `account.1melon` 和 `vaults/`，
/// 和数据目录的结构一样，恢复时复制回去即可。`device/`（Touch ID）只属于这台 Mac，不备份。
public struct BackupStore: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var url: URL
        public var date: Date
    }

    public enum Failure: Error, Equatable {
        case noAccount
        case alreadyExists
    }

    public static let prefix = "1Melon-"
    public let destination: URL

    public init(destination: URL) { self.destination = destination }

    /// 默认位置：数据目录下的 `backups/`
    public static func defaultDestination(for repo: AccountRepository) -> URL {
        repo.root.appendingPathComponent("backups")
    }

    /// 已有的备份，新的在前
    public func list() -> [Snapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix(Self.prefix), let date = Self.date(from: String(name.dropFirst(Self.prefix.count))) else { return nil }
            return Snapshot(url: destination.appendingPathComponent(name), date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// 备份一次。和最新一份备份内容完全一样时不重复备份，返回 nil。
    /// 先写进同目录的临时文件夹，全部复制完再改名，中途失败不会留下半份备份。
    @discardableResult
    public func backUp(_ repo: AccountRepository, now: Date = Date()) throws -> Snapshot? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: repo.accountURL.path) else { throw Failure.noAccount }
        let files = try Self.files(in: repo.root)
        if let latest = list().first, (try? Self.files(in: latest.url)) == files { return nil }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = Self.prefix + Self.stamp(now)
        let final = destination.appendingPathComponent(name)
        guard !fm.fileExists(atPath: final.path) else { throw Failure.alreadyExists }
        let tmp = destination.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        do {
            for (path, data) in files {
                try VaultStore.write(data, to: tmp.appendingPathComponent(path))
            }
            try fm.moveItem(at: tmp, to: final)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return Snapshot(url: final, date: Self.date(from: Self.stamp(now)) ?? now)
    }

    /// 只留最新的 `keep` 份，其余删掉（只删本类备份文件夹，不碰目录里的别的东西）。返回删掉的。
    @discardableResult
    public func prune(keep: Int) -> [Snapshot] {
        let old = Array(list().dropFirst(max(keep, 1)))
        return old.filter { (try? FileManager.default.removeItem(at: $0.url)) != nil }
    }

    /// 数据目录里要备份的文件：相对路径 → 内容。只认 `account.1melon` 和 `vaults/*.1melon`，临时文件不算。
    static func files(in root: URL) throws -> [String: Data] {
        var out = ["account.1melon": try VaultStore.read(root.appendingPathComponent("account.1melon"))]
        let vaults = root.appendingPathComponent("vaults")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: vaults.path)) ?? []
        where name.hasSuffix(".1melon") && !name.hasPrefix(".") {
            out["vaults/\(name)"] = try VaultStore.read(vaults.appendingPathComponent(name))
        }
        return out
    }

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }

    static func stamp(_ date: Date) -> String { formatter().string(from: date) }
    static func date(from stamp: String) -> Date? { formatter().date(from: stamp) }
}

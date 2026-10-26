import Foundation

/// 本机保险库文件：在哪、有没有、读写。界面层只通过它碰文件。
public struct VaultRepository: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// 默认位置：`~/Library/Application Support/1Melon/vault.1melon`（Linux 上是 `~/.local/share/1Melon/`）。
    /// 开发和测试时可以用环境变量 `MELON_VAULT_PATH` 指到别处，免得碰到自己真正的保险库。
    public static func defaultLocation(environment: [String: String] = ProcessInfo.processInfo.environment) -> VaultRepository {
        if let path = environment["MELON_VAULT_PATH"], !path.isEmpty {
            return VaultRepository(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".1melon")
        return VaultRepository(url: base.appendingPathComponent("1Melon/vault.1melon"))
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 新建并立即写盘。已经有文件时拒绝，不覆盖。
    public func create(password: String, name: String = "个人保险库", now: Int64, kdf: KDFParameters = .defaults()) throws -> UnlockedVault {
        guard !exists else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]) }
        var vault = try UnlockedVault.create(password: password, name: name, now: now, kdf: kdf)
        try save(&vault, now: now)
        return vault
    }

    public func unlock(password: String) throws -> UnlockedVault {
        try UnlockedVault.open(try VaultStore.read(url), password: password)
    }

    public func save(_ vault: inout UnlockedVault, now: Int64) throws {
        try VaultStore.write(try vault.serialized(now: now), to: url)
    }
}

public extension Date {
    /// UTC 毫秒时间戳（保险库里所有时间都用它）
    var unixMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }
}

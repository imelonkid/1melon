import Foundation

/// 本机数据目录（spec §3）：`account.1melon` + `vaults/<vaultId>.1melon`。界面层只通过它碰文件。
public struct AccountRepository: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// 默认位置：`~/Library/Application Support/1Melon/`（Linux 上是 `~/.local/share/1Melon/`）。
    /// 开发和测试时可以用环境变量 `MELON_DATA_DIR` 指到别处，免得碰到自己真正的数据。
    public static func defaultLocation(environment: [String: String] = ProcessInfo.processInfo.environment) -> AccountRepository {
        if let path = environment["MELON_DATA_DIR"], !path.isEmpty {
            return AccountRepository(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".1melon")
        return AccountRepository(root: base.appendingPathComponent("1Melon"))
    }

    public var accountURL: URL { root.appendingPathComponent("account.1melon") }
    public var vaultsDirectory: URL { root.appendingPathComponent("vaults") }
    public func vaultURL(_ vaultId: String) -> URL { vaultsDirectory.appendingPathComponent("\(vaultId).1melon") }

    public var exists: Bool { FileManager.default.fileExists(atPath: accountURL.path) }

    /// 新建账户和一个默认保险库「个人」，并立即写盘。已经有账户时拒绝，不覆盖。
    public func create(password: String, now: Int64, kdf: KDFParameters = .defaults()) throws -> LoadedAccount {
        guard !exists else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: accountURL.path]) }
        let account = try UnlockedAccount.create(password: password, kdf: kdf)
        var personal = try UnlockedVault.create(in: account, meta: VaultMeta(name: "个人", icon: "person", color: "blue", created: now))
        // 先写保险库再写账户：中途失败时不会留下「有账户、没保险库」的半成品
        try save(&personal, now: now)
        try saveAccount(account)
        return LoadedAccount(account: account, vaults: [personal], failures: [])
    }

    /// 用主密码解锁：先开账户（主密码错误在这一步），再逐个开保险库。
    /// 单个保险库打不开（损坏、被篡改、不属于这个账户）不影响其他保险库，记在 `failures` 里。
    public func unlock(password: String) throws -> LoadedAccount {
        let account = try UnlockedAccount.open(try VaultStore.read(accountURL), password: password)
        return loadVaults(account)
    }

    public func loadVaults(_ account: UnlockedAccount) -> LoadedAccount {
        var vaults: [UnlockedVault] = []
        var failures: [VaultLoadFailure] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: vaultsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "1melon" {
            do {
                vaults.append(try UnlockedVault.open(try VaultStore.read(url), account: account))
            } catch let e as VaultError {
                failures.append(VaultLoadFailure(file: url.lastPathComponent, error: e))
            } catch {
                failures.append(VaultLoadFailure(file: url.lastPathComponent, error: .invalidFormat("读取失败")))
            }
        }
        vaults.sort { ($0.meta.order, $0.meta.created) < ($1.meta.order, $1.meta.created) }
        failures.sort { $0.file < $1.file }
        return LoadedAccount(account: account, vaults: vaults, failures: failures)
    }

    /// 新建一个保险库并写盘。
    public func createVault(in account: UnlockedAccount, meta: VaultMeta, now: Int64) throws -> UnlockedVault {
        var vault = try UnlockedVault.create(in: account, meta: meta)
        try save(&vault, now: now)
        return vault
    }

    public func save(_ vault: inout UnlockedVault, now: Int64) throws {
        try VaultStore.write(try vault.serialized(now: now), to: vaultURL(vault.vaultId))
    }

    public func saveAccount(_ account: UnlockedAccount) throws {
        try VaultStore.write(try account.serialized(), to: accountURL)
    }
}

/// 解锁结果：账户 + 打开成功的保险库（按 `order`、创建时间排序）+ 打不开的保险库文件。
public struct LoadedAccount: Sendable {
    public var account: UnlockedAccount
    public var vaults: [UnlockedVault]
    public var failures: [VaultLoadFailure]
}

public struct VaultLoadFailure: Sendable, Equatable {
    public let file: String
    public let error: VaultError
}

public extension Date {
    /// UTC 毫秒时间戳（保险库里所有时间都用它）
    var unixMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }
}

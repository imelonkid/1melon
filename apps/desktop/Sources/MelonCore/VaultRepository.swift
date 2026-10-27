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
    /// `secretKey` 为空时用这台设备上存的 Secret Key（账户不带 Secret Key 时忽略）。
    /// 用手输的 Secret Key 解锁成功后，存进设备目录，下次不用再输。
    public func unlock(password: String, secretKey: SecretKey? = nil) throws -> LoadedAccount {
        let data = try VaultStore.read(accountURL)
        let account = try UnlockedAccount.open(data, password: password, secretKey: secretKey ?? readSecretKey())
        if let secretKey, account.secretKey == secretKey, readSecretKey(accountId: account.accountId) != secretKey {
            try writeSecretKey(secretKey, accountId: account.accountId)
        }
        return loadVaults(account)
    }

    /// 同 `unlock(password:secretKey:)`，账户带 Secret Key 时顺带派生同步登录密钥（Argon2id 只跑一次）
    public func unlockWithLoginKey(password: String, secretKey: SecretKey? = nil) throws -> (LoadedAccount, LoginKey?) {
        let data = try VaultStore.read(accountURL)
        guard try UnlockedAccount.decodeFile(data).requiresSecretKey else { return (try unlock(password: password, secretKey: secretKey), nil) }
        guard let sk = secretKey ?? readSecretKey() else { throw VaultError.secretKeyRequired }
        let (account, loginKey) = try UnlockedAccount.openWithLoginKey(data, password: password, secretKey: sk)
        if let secretKey, account.secretKey == secretKey, readSecretKey(accountId: account.accountId) != secretKey {
            try writeSecretKey(secretKey, accountId: account.accountId)
        }
        return (loadVaults(account), loginKey)
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

    /// 删除保险库文件。只允许删没有条目的保险库（墓碑不算），防止误删数据。
    public func deleteVault(_ vault: UnlockedVault) throws {
        guard vault.activeItems.isEmpty else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "保险库里还有条目，先移走或删除再删保险库"])
        }
        try FileManager.default.removeItem(at: vaultURL(vault.vaultId))
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

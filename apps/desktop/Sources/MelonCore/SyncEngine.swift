import Crypto
import Foundation

// 客户端同步流程（spec/sync-api.md §6）。只处理「文件」这一层：比对、下载、合并、上传、防回退。
// 网络和登录由 `SyncTransport` 负责，测试里换成内存里的假服务端。

// MARK: 同步状态 device/sync.json

/// 这台设备的同步状态（sync-api §6.6）：只属于这台设备，不同步、不备份。
public struct SyncState: Codable, Equatable, Sendable {
    static let formatName = "1melon-device-sync"

    /// 每个文件最后一次同步时的样子
    public struct FileState: Codable, Equatable, Sendable {
        /// 服务端修订号
        public var rev: Int
        /// 当时本机文件（= 云端文件）内容的 SHA-256 hex。本机文件和它不一样，就是本机改过
        public var sha256: String
        /// 保险库索引的 `updated`（账户文件没有）。云端给的比它旧，就拒绝（防回退）
        public var updated: Int64?
        /// 云端已删除
        public var deleted: Bool?
    }

    public var format = formatName
    public var version = 1
    public var server: String
    public var accountId: String
    public var deviceId: String
    public var cursor: String?
    public var files: [String: FileState] = [:]

    public init(server: String, accountId: String, deviceId: String = UUID().uuidString.lowercased()) {
        self.server = server
        self.accountId = accountId
        self.deviceId = deviceId
    }
}

public extension AccountRepository {
    var syncStateURL: URL { deviceDirectory.appendingPathComponent("sync.json") }

    /// 没有或格式不对返回 nil（= 这台设备没开同步）
    func readSyncState() -> SyncState? {
        guard let data = try? VaultStore.read(syncStateURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data),
              state.format == SyncState.formatName, state.version == 1 else { return nil }
        return state
    }

    func writeSyncState(_ state: SyncState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try VaultStore.write(try encoder.encode(state), to: syncStateURL)
    }

    func removeSyncState() {
        try? FileManager.default.removeItem(at: syncStateURL)
    }
}

// MARK: 传输

/// `GET /files` 里的一项（sync-api §5.1）
public struct RemoteFile: Sendable, Equatable {
    public var name: String
    public var rev: Int
    public var sha256: String
    public var deleted: Bool

    public init(name: String, rev: Int, sha256: String, deleted: Bool = false) {
        self.name = name
        self.rev = rev
        self.sha256 = sha256
        self.deleted = deleted
    }
}

/// 上传账户文件时要带的登录公钥和证明（sync-api §5.3）
public struct AccountUploadProof: Sendable, Equatable {
    public var publicKey: Data
    public var proof: Data
}

public enum SyncTransportError: Error, Equatable {
    /// 412：别人先写了。`rev` 是云端当前的修订号
    case conflict(rev: Int?)
    case notFound
}

/// 和服务端打交道的那一层：已经登录好（带会话令牌），只按 sync-api §5 收发文件。
public protocol SyncTransport: Sendable {
    func listFiles(since cursor: String?) async throws -> (files: [RemoteFile], cursor: String)
    func download(_ name: String) async throws -> (data: Data, rev: Int)
    /// `baseRev` 为 nil 时是新建（`If-None-Match: *`），否则是 `If-Match`。返回新的修订号
    func upload(_ name: String, data: Data, baseRev: Int?, proof: AccountUploadProof?) async throws -> Int
    func delete(_ name: String, baseRev: Int) async throws -> Int
}

// MARK: 引擎

public struct SyncResult: Sendable, Equatable {
    /// 本机文件被云端版本替换或合并过的保险库（界面要重新打开）
    public var updatedVaults: Set<String> = []
    /// 云端删除、本机也跟着删掉的保险库
    public var removedVaults: Set<String> = []
    /// 本机账户文件换成了云端的（别的设备改了主密码等）：下次解锁要用新主密码
    public var accountReplaced = false
    /// 本机改过的账户文件被云端先到的那份覆盖了（两台设备都改了主密码，sync-api §6.5）
    public var localAccountChangeDiscarded = false
    public var uploaded = 0
    public var conflicts = 0
    /// 没处理成的文件和原因：云端比本机旧（可能被篡改）、打不开、重试几次仍冲突等。不影响其他文件
    public var failures: [String: SyncFailure] = [:]
}

public enum SyncFailure: Error, Sendable, Equatable {
    /// 云端的文件比本机记住的旧：可能被回退或篡改，拒绝接受
    case rollback
    /// 云端的文件打不开（损坏、篡改、不属于这个账户）
    case invalid(VaultError)
    /// 重试几次都冲突
    case conflictRetriesExhausted
    /// 本机改了账户文件，但没有对应的登录密钥，传不了
    case accountProofMissing
    /// 合并或同步途中本机文件又被改了：这次跳过，下次再同步
    case localChangedDuringSync
}

public struct SyncEngine: Sendable {
    public static let accountFile = "account.1melon"
    static let maxAttempts = 3

    let repository: AccountRepository
    let transport: SyncTransport

    public init(repository: AccountRepository, transport: SyncTransport) {
        self.repository = repository
        self.transport = transport
    }

    /// 同步一轮。`accountUploadKey`：本机账户文件改过（改主密码等）时，和新账户文件对应的登录密钥。
    /// 网络错误直接抛出（状态不变，下次重来）；单个文件的问题记在 `failures` 里，其余照常同步。
    public func sync(account: UnlockedAccount, state: inout SyncState, accountUploadKey: LoginKey? = nil,
                     now: Int64) async throws -> SyncResult {
        var result = SyncResult()
        let (listed, cursor) = try await transport.listFiles(since: state.cursor)
        let remote = Dictionary(listed.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })

        var names = Set(remote.keys).union(state.files.keys).union(localVaultNames())
        names.insert(Self.accountFile)
        // 账户文件放最后：先把保险库同步完
        for name in names.sorted(by: { ($0 == Self.accountFile ? 1 : 0, $0) < ($1 == Self.accountFile ? 1 : 0, $1) }) {
            do {
                if name == Self.accountFile {
                    try await syncAccountFile(remote: remote[name], state: &state, key: accountUploadKey, account: account, result: &result)
                } else {
                    try await syncVault(name, remote: remote[name], account: account, state: &state, now: now, result: &result)
                }
            } catch let failure as SyncFailure {
                result.failures[name] = failure
            }
        }
        // 有文件没同步成就不推进游标，下次还能从云端列表里看到它
        if result.failures.isEmpty { state.cursor = cursor }
        return result
    }

    /// 读 `device/sync.json`、同步一轮、写回。没开同步时抛 `SyncSetup.SetupError.notSyncing`
    public func syncAndSave(account: UnlockedAccount, accountUploadKey: LoginKey? = nil, now: Int64) async throws -> SyncResult {
        guard var state = repository.readSyncState(), state.accountId == account.accountId else { throw SyncSetup.SetupError.notSyncing }
        let result = try await sync(account: account, state: &state, accountUploadKey: accountUploadKey, now: now)
        try repository.writeSyncState(state)
        return result
    }

    // MARK: 保险库

    private func syncVault(_ name: String, remote listed: RemoteFile?, account: UnlockedAccount, state: inout SyncState,
                           now: Int64, result: inout SyncResult) async throws {
        guard let vaultId = Self.vaultId(name) else { return }
        let url = repository.vaultURL(vaultId)
        let local = try? VaultStore.read(url)
        let known = state.files[name]
        // 没出现在增量列表里 = 云端没变
        let remote = listed ?? known.map { RemoteFile(name: name, rev: $0.rev, sha256: $0.sha256, deleted: $0.deleted ?? false) }
        let localChanged = local.map { Self.sha256($0) != known?.sha256 || known?.deleted == true } ?? false
        let remoteChanged = remote != nil && remote?.rev != known?.rev

        if let remote, let known, remote.rev < known.rev { throw SyncFailure.rollback }

        switch (local, remote) {
        case (nil, nil):
            return
        case let (nil, remote?):
            if remote.deleted {
                state.files[name] = .init(rev: remote.rev, sha256: remote.sha256, updated: known?.updated, deleted: true)
            } else if known == nil || remoteChanged || known?.deleted == true {
                // 别的设备新建或改过：下载
                try await accept(name, vaultId: vaultId, expectedLocal: nil, account: account, state: &state, result: &result)
            } else {
                // 本机删掉了（只能删空保险库）：云端也删
                let rev = try await deleteRemote(name, baseRev: remote.rev)
                state.files[name] = .init(rev: rev, sha256: "", updated: known?.updated, deleted: true)
            }
        case let (_?, remote?) where remote.deleted && !localChanged:
            // 别的设备删了，本机没改过：跟着删
            if remoteChanged {
                try? FileManager.default.removeItem(at: url)
                result.removedVaults.insert(vaultId)
            }
            state.files[name] = .init(rev: remote.rev, sha256: remote.sha256, updated: known?.updated, deleted: true)
        case let (local?, remote):
            if remote == nil || remote?.deleted == true {
                // 云端没有（或已删除，但本机改过）：以本机为准新建
                try await upload(name, data: local, baseRev: nil, account: account, state: &state, now: now, result: &result)
            } else if !localChanged && !remoteChanged {
                return
            } else if !localChanged {
                try await accept(name, vaultId: vaultId, expectedLocal: local, account: account, state: &state, result: &result)
            } else if !remoteChanged {
                try await upload(name, data: local, baseRev: remote!.rev, account: account, state: &state, now: now, result: &result)
            } else {
                try await mergeAndUpload(name, local: local, account: account, state: &state, now: now, result: &result)
            }
        }
    }

    /// 上传本机版本；412 就下载合并再传
    private func upload(_ name: String, data: Data, baseRev: Int?, account: UnlockedAccount, state: inout SyncState,
                        now: Int64, result: inout SyncResult) async throws {
        do {
            let rev = try await transport.upload(name, data: data, baseRev: baseRev, proof: nil)
            state.files[name] = .init(rev: rev, sha256: Self.sha256(data), updated: try? UnlockedVault.open(data, account: account).updated)
            result.uploaded += 1
        } catch SyncTransportError.conflict {
            try await mergeAndUpload(name, local: data, account: account, state: &state, now: now, result: &result)
        }
    }

    /// 两边都改过：下载云端、按条目合并、写本机、以云端修订号为基础上传。上传时又冲突就重来
    private func mergeAndUpload(_ name: String, local: Data, account: UnlockedAccount, state: inout SyncState,
                                now: Int64, result: inout SyncResult) async throws {
        guard let vaultId = Self.vaultId(name) else { return }
        var localData = local
        for _ in 0..<Self.maxAttempts {
            let (remoteData, remoteRev) = try await transport.download(name)
            let theirs = try openChecked(remoteData, rev: remoteRev, known: state.files[name], account: account)
            let mine: UnlockedVault
            do { mine = try UnlockedVault.open(localData, account: account) } catch let e as VaultError { throw SyncFailure.invalid(e) }
            var (merged, report) = try VaultMerge.merge(local: mine, remote: theirs)
            let data = try merged.serialized(now: now)
            try writeLocal(data, to: repository.vaultURL(vaultId), expected: localData)
            localData = data
            result.updatedVaults.insert(vaultId)
            result.conflicts += report.conflicts
            do {
                let rev = try await transport.upload(name, data: data, baseRev: remoteRev, proof: nil)
                state.files[name] = .init(rev: rev, sha256: Self.sha256(data), updated: merged.updated)
                result.uploaded += 1
                return
            } catch SyncTransportError.conflict {
                continue
            }
        }
        throw SyncFailure.conflictRetriesExhausted
    }

    /// 本机没改过：下载云端版本，检查后替换本机文件
    private func accept(_ name: String, vaultId: String, expectedLocal: Data?, account: UnlockedAccount, state: inout SyncState,
                        result: inout SyncResult) async throws {
        let (data, rev) = try await transport.download(name)
        let vault = try openChecked(data, rev: rev, known: state.files[name], account: account)
        guard vault.vaultId == vaultId else { throw SyncFailure.invalid(.invalidFormat("vaultId 和文件名不一致")) }
        try writeLocal(data, to: repository.vaultURL(vaultId), expected: expectedLocal)
        state.files[name] = .init(rev: rev, sha256: Self.sha256(data), updated: vault.updated)
        result.updatedVaults.insert(vaultId)
    }

    private func deleteRemote(_ name: String, baseRev: Int) async throws -> Int {
        do {
            return try await transport.delete(name, baseRev: baseRev)
        } catch SyncTransportError.conflict {
            // 删之前别的设备改过：不删，下一轮会把它下载回来
            throw SyncFailure.conflictRetriesExhausted
        }
    }

    /// 打开云端文件并做防回退检查（sync-api §6.4）
    private func openChecked(_ data: Data, rev: Int, known: SyncState.FileState?, account: UnlockedAccount) throws -> UnlockedVault {
        if let known, rev < known.rev { throw SyncFailure.rollback }
        let vault: UnlockedVault
        do { vault = try UnlockedVault.open(data, account: account) } catch let e as VaultError { throw SyncFailure.invalid(e) }
        if let updated = known?.updated, vault.updated < updated { throw SyncFailure.rollback }
        return vault
    }

    // MARK: 账户文件

    private func syncAccountFile(remote listed: RemoteFile?, state: inout SyncState, key: LoginKey?, account: UnlockedAccount,
                                 result: inout SyncResult) async throws {
        let name = Self.accountFile
        guard let local = try? VaultStore.read(repository.accountURL) else { return }
        let known = state.files[name]
        let remote = listed ?? known.map { RemoteFile(name: name, rev: $0.rev, sha256: $0.sha256) }
        // 云端没有账户文件：还没注册，这里不管
        guard let remote else { return }
        if let known, remote.rev < known.rev { throw SyncFailure.rollback }
        let localChanged = Self.sha256(local) != known?.sha256
        let remoteChanged = remote.rev != known?.rev

        if localChanged && !remoteChanged {
            guard let key else { throw SyncFailure.accountProofMissing }
            do {
                let proof = AccountUploadProof(publicKey: key.publicKey, proof: try key.signRotate(accountId: account.accountId, accountFile: local))
                let rev = try await transport.upload(name, data: local, baseRev: remote.rev, proof: proof)
                state.files[name] = .init(rev: rev, sha256: Self.sha256(local))
                result.uploaded += 1
                return
            } catch SyncTransportError.conflict {
                // 别的设备先改了：以先到的为准（sync-api §6.5），往下走下载
            }
        } else if !remoteChanged {
            return
        }

        let (data, rev) = try await transport.download(name)
        if let known, rev < known.rev { throw SyncFailure.rollback }
        let file: AccountFile
        do { file = try UnlockedAccount.decodeFile(data) } catch let e as VaultError { throw SyncFailure.invalid(e) }
        guard file.accountId == account.accountId, file.requiresSecretKey else {
            throw SyncFailure.invalid(.invalidFormat("账户文件不属于当前账户"))
        }
        try writeLocal(data, to: repository.accountURL, expected: local)
        state.files[name] = .init(rev: rev, sha256: Self.sha256(data))
        result.accountReplaced = true
        if localChanged { result.localAccountChangeDiscarded = true }
    }

    // MARK: 工具

    /// 写本机文件前确认它还是读到时的样子：同步途中界面可能又保存过，不能覆盖掉
    private func writeLocal(_ data: Data, to url: URL, expected: Data?) throws {
        let current = try? VaultStore.read(url)
        guard current == expected else { throw SyncFailure.localChangedDuringSync }
        try VaultStore.write(data, to: url)
    }

    private func localVaultNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: repository.vaultsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "1melon" && Self.vaultId("vaults/\($0.lastPathComponent)") != nil }
            .map { "vaults/\($0.lastPathComponent)" }
    }

    /// `vaults/<小写 UUID>.1melon` → vaultId
    static func vaultId(_ name: String) -> String? {
        guard name.hasPrefix("vaults/"), name.hasSuffix(".1melon") else { return nil }
        let id = String(name.dropFirst("vaults/".count).dropLast(".1melon".count))
        return isLowercaseUUID(id) ? id : nil
    }

    static func fileName(vaultId: String) -> String { "vaults/\(vaultId).1melon" }

    static func sha256(_ data: Data) -> String { LoginKey.sha256Hex(data) }
}

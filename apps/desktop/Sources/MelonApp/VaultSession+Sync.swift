import AppKit
import MelonCore

/// 界面上显示的同步状态（设置「同步」页）
struct SyncInfo {
    var syncing = false
    var lastAttempt: Date?
    var lastSuccess: Date?
    /// 最近一次的问题，给人看的一句话；nil = 一切正常
    var problem: String?
}

enum SyncUnavailable: LocalizedError {
    /// 开着同步，但这次解锁没拿到登录密钥（Touch ID 的本机文件是开同步之前登记的）
    case needsLogin
    /// 开着同步时不能停用 Secret Key（sync-api §1）
    case secretKeyInUse

    var errorDescription: String? {
        switch self {
        case .needsLogin: "这次用 Touch ID 解锁，还连不上同步：锁定后用主密码解锁一次，之后 Touch ID 解锁也能同步"
        case .secretKeyInUse: "开着同步时不能停用 Secret Key，要先关掉同步"
        }
    }
}

/// 同步的时机（sync-api §6.1）：解锁后、保存后（等 3 秒合成一次）、每 5 分钟、切回前台时（距上次超过 30 秒）。
/// 同一时刻只跑一轮；跑的时候又有改动，完了再来一轮。网络和加解密都在后台线程，结果回到主线程再换进界面。
extension VaultSession {
    static let syncInterval: Duration = .seconds(300)

    var isSyncEnabled: Bool { syncEnabled }
    var syncState: SyncState? { repository.readSyncState() }

    /// 服务端设备列表里显示的名字
    var deviceName: String { Host.current().localizedName ?? "Mac" }

    /// 新设备加入用的设置码（里面有 Secret Key，只在界面上显示）
    var setupCode: SetupCode? {
        guard let state = repository.readSyncState(), let sk = loaded?.account.secretKey, state.accountId == loaded?.account.accountId
        else { return nil }
        return SetupCode(server: state.server, accountId: state.accountId, secretKey: sk)
    }

    func makeSyncClient() -> SyncClient? {
        guard let key = loginKey, let state = repository.readSyncState(), state.accountId == loaded?.account.accountId else { return nil }
        return try? SyncClient(state: state, deviceName: deviceName, loginKey: key)
    }

    /// 读一次本机的同步状态文件，刷新 `syncEnabled`
    func refreshSyncEnabled() { syncEnabled = repository.readSyncState() != nil }

    // MARK: 时机

    func startSyncTriggers() {
        syncObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let last = self.sync.lastAttempt, Date().timeIntervalSince(last) < 30 { return }
                self.syncNow()
            }
        }
    }

    /// 解锁后：开着同步就连上、马上同步一轮，之后每 5 分钟一轮
    func startSync() {
        refreshSyncEnabled()
        guard isSyncEnabled else { sync = SyncInfo(); return }
        syncClient = makeSyncClient()
        guard syncClient != nil else {
            sync.problem = SyncUnavailable.needsLogin.errorDescription
            return
        }
        syncNow()
        syncLoop?.cancel()
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                guard !Task.isCancelled else { return }
                self?.syncNow()
            }
        }
    }

    /// 锁定时：断开连接，丢掉登录密钥和会话令牌
    func stopSync() {
        syncLoop?.cancel()
        syncDebounce?.cancel()
        syncLoop = nil
        syncDebounce = nil
        syncTask = nil
        syncClient = nil
        loginKey = nil
        syncAgain = false
        sync.syncing = false
    }

    /// 保存后：3 秒内没有新改动再同步（连续编辑合成一次）
    func scheduleSync() {
        guard syncClient != nil else { return }
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    func syncNow() {
        guard let client = syncClient, case .unlocked(let loaded) = state else { return }
        if syncTask != nil || syncHeld {
            syncAgain = true
            return
        }
        syncAgain = false
        sync.syncing = true
        sync.lastAttempt = Date()
        let repo = repository, account = loaded.account, key = loginKey
        syncTask = Task { [weak self] in
            let outcome = await Task.detached { () -> Result<SyncResult, Error> in
                do {
                    return .success(try await SyncEngine(repository: repo, transport: client)
                        .syncAndSave(account: account, accountUploadKey: key, now: Date().unixMilliseconds))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, self.syncClient === client else { return }   // 期间锁定了或换了连接：结果不要了
            self.syncTask = nil
            self.sync.syncing = false
            self.apply(outcome, accountId: account.accountId)
            if self.syncAgain { self.syncNow() }
        }
    }

    /// 把一轮同步的结果换进界面：云端改过的保险库从文件重新打开；账户文件被换了就锁定，要新主密码
    private func apply(_ outcome: Result<SyncResult, Error>, accountId: String) {
        guard case .unlocked(var loaded) = state, loaded.account.accountId == accountId else { return }
        switch outcome {
        case .failure(let error):
            sync.problem = Self.describe(error)
        case .success(let r):
            if r.accountReplaced || r.localAccountChangeDiscarded {
                lockForNewAccountFile()
                return
            }
            if !r.updatedVaults.isEmpty || !r.removedVaults.isEmpty {
                // 留在主线程：放到后台的话，读文件期间界面保存会把同步前的内存写回盘，盖掉刚同步下来的改动
                let fresh = repository.loadVaults(loaded.account)
                loaded.vaults = fresh.vaults
                loaded.failures = fresh.failures
                state = .unlocked(loaded)
            }
            // 同步途中界面又保存过：那个文件这轮跳过了，马上再来一轮
            if r.failures.values.contains(.localChangedDuringSync) { syncAgain = true }
            let problems = r.failures.compactMap { describe($0.value, file: $0.key, in: loaded) }.sorted()
            sync.problem = problems.isEmpty ? nil : problems.joined(separator: "\n")
            if problems.isEmpty { sync.lastSuccess = Date() }
        }
    }

    /// 别的设备改了主密码：本机账户文件已经换成新的，登录密钥（含 Touch ID 里封的那份）作废，要用新主密码解锁
    func lockForNewAccountFile() {
        TouchIDUnlock.disable(repo: repository)
        lock()
        lockMessage = "主密码在别的设备上改过了，请用新主密码解锁"
    }

    // MARK: 开启、加入、关闭

    /// 开启同步：再输一次主密码（确认身份、派生登录密钥），凭邀请码注册，马上同步一轮把保险库传上去
    func enableSync(server: String, inviteCode: String, password: String) async throws {
        guard case .unlocked(let loaded) = state else { return }
        guard let sk = loaded.account.secretKey else { throw SyncSetup.SetupError.secretKeyRequired }
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SyncAPIError.insecureServer }
        _ = try SyncAPI.baseURL(server: url)
        isWorking = true
        defer { isWorking = false }
        let repo = repository, accountId = loaded.account.accountId
        let key = try await Task.detached { () -> LoginKey in
            let (account, key) = try UnlockedAccount.openWithLoginKey(try VaultStore.read(repo.accountURL), password: password, secretKey: sk)
            guard account.accountId == accountId else { throw VaultError.wrongPassword }
            return key
        }.value
        try await SyncSetup.register(server: url, inviteCode: inviteCode, repository: repo, loginKey: key)
        loginKey = key
        TouchIDUnlock.notePasswordEntered()
        enrollTouchIDIfNeeded(loaded.account, force: true)
        noteActivity()
        startSync()
    }

    /// 新设备加入已有账户（首次启动时）：设置码 + 主密码，下载账户文件和全部保险库
    func join(setupCode: SetupCode, password: String) async throws {
        guard let url = setupCode.serverURL else { throw SyncAPIError.insecureServer }
        isWorking = true
        defer { isWorking = false }
        do {
            let joined = try await SyncSetup.join(server: url, accountId: setupCode.accountId, secretKey: setupCode.secretKey,
                                                  password: password, repository: repository, deviceName: deviceName,
                                                  now: Date().unixMilliseconds)
            state = .unlocked(joined.loaded)
            loginKey = joined.loginKey
            lockMessage = nil
            sync.lastSuccess = Date()
            TouchIDUnlock.notePasswordEntered()
            enrollTouchIDIfNeeded(joined.loaded.account)
            noteActivity()
            startSync()
        } catch {
            // 账户文件已经写下来、保险库没下载完（比如断网）：当作已有账户，解锁后接着同步
            if repository.exists {
                state = .locked
                lockMessage = "已经加入账户，保险库还没下载完：解锁后会接着同步"
            }
            throw error
        }
    }

    /// 关掉这台 Mac 的同步：只删本机的同步状态，云端和本机的文件都不动
    func disableSync() {
        stopSync()
        SyncSetup.disconnect(repository: repository)
        refreshSyncEnabled()
        sync = SyncInfo()
        // Touch ID 的本机文件里不再留登录密钥
        if let account = loaded?.account, TouchIDUnlock.enrolled()?.hasLoginKey == true {
            enrollTouchIDIfNeeded(account, force: true)
        }
    }

    // MARK: 文案

    static func describe(_ error: Error) -> String {
        switch error {
        case SyncAPIError.unauthorized: return "服务端拒绝登录：主密码或 Secret Key 不对，或者主密码在别的设备上改过了"
        case SyncAPIError.forbidden: return "被服务端拒绝：邀请码无效、用过或过期，或者账户已被停用"
        case SyncAPIError.exists: return "这个账户已经注册过了：在别的设备上看设置码，用「加入已有账户」"
        case SyncAPIError.tooLarge: return "超过了服务端的空间或文件数上限"
        case SyncAPIError.rateLimited: return "请求太频繁，稍后会自动重试"
        case SyncAPIError.insecureServer: return "同步地址不对：只能用 https:// 开头的地址"
        case SyncAPIError.badRequest: return "同步请求被服务端拒绝，可能要升级 1Melon"
        case SyncAPIError.server, SyncAPIError.invalidResponse: return "同步服务端出了问题，稍后会自动重试"
        case let e as URLError:
            return e.code == .notConnectedToInternet ? "没有网络，连上后会自动同步" : "连不上同步服务端，稍后会自动重试"
        case let e as SyncUnavailable: return e.errorDescription ?? ""
        case SyncSetup.SetupError.secretKeyRequired: return "开启同步要先在「安全」里启用 Secret Key"
        case SyncSetup.SetupError.alreadySyncing: return "这台 Mac 已经开着同步"
        case SyncSetup.SetupError.localAccountExists: return "这台 Mac 上已经有账户了"
        case SyncSetup.SetupError.accountMismatch: return "服务端的账户文件和设置码对不上，请稍后重试"
        case SyncSetup.SetupError.passwordChangeNotUploaded: return "新主密码没能传上同步服务端，已恢复成原来的主密码。请联网后再改"
        case SyncSetup.SetupError.accountChangedElsewhere: return "别的设备刚改过主密码，请用那边的新主密码解锁"
        case SyncSetup.SetupError.notSyncing: return "这台 Mac 没开同步"
        case let e as VaultError: return e.userMessage
        default: return "同步失败：\(error.localizedDescription)"
        }
    }

    private func describe(_ failure: SyncFailure, file: String, in loaded: LoadedAccount) -> String? {
        let name: String
        if file == SyncEngine.accountFile {
            name = "账户文件"
        } else {
            let id = file.replacingOccurrences(of: "vaults/", with: "").replacingOccurrences(of: ".1melon", with: "")
            name = loaded.vaults.first { $0.vaultId == id }.map { "保险库「\($0.meta.name)」" } ?? "一个保险库"
        }
        switch failure {
        case .rollback: return "\(name)：云端的版本比本机旧，可能被回退或篡改，已拒绝"
        case .invalid: return "\(name)：云端的文件打不开（损坏或被篡改），已跳过"
        case .conflictRetriesExhausted: return "\(name)：一直和别的设备冲突，稍后再试"
        case .accountProofMissing: return "\(name)：改过但没法上传，请用主密码解锁一次"
        case .localChangedDuringSync: return nil
        }
    }
}

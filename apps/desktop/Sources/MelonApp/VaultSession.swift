import AppKit
import MelonCore
import Observation

/// 会话：没有账户 → 新建；已锁定 → 解锁；已解锁 → 读写各保险库里的条目。
/// 明文只在 `.unlocked` 里；锁定时整个账户和保险库被丢掉，剪贴板里我们写的内容一并清掉。
@MainActor
@Observable
final class VaultSession {
    enum State {
        case noAccount
        case locked
        case unlocked(LoadedAccount)
    }

    /// 只在 VaultSession 和它的扩展（VaultSession+Sync.swift）里改
    var state: State
    /// 解锁 / 新建时正在派生密钥（约 0.3 秒，debug 构建更久）
    var isWorking = false
    /// 最近一次写盘失败的原因；界面弹窗提示
    var saveError: String?
    /// 菜单「文件 → 导入…」请求打开导入窗口（主界面看到后打开）
    var importRequested = false
    /// 菜单「文件 → 导出…」请求打开导出窗口
    var exportRequested = false
    /// 最近一份备份的时间；`backupError` 是最近一次自动备份失败的原因（设置「数据」页显示）
    private(set) var lastBackup: Date?
    private(set) var backupError: String?
    private(set) var isBackingUp = false
    private var backupTimer: Timer?

    // 同步（逻辑在 VaultSession+Sync.swift）
    /// 界面上显示的同步状态
    var sync = SyncInfo()
    /// 只在解锁时有：同步登录密钥和到服务端的连接（会话令牌在里面）。锁定时丢掉
    var loginKey: LoginKey?
    var syncClient: SyncClient?
    var syncTask: Task<Void, Never>?
    var syncDebounce: Task<Void, Never>?
    var syncLoop: Task<Void, Never>?
    /// 同步进行中又有新改动：这一轮完了再来一轮
    var syncAgain = false
    /// 改主密码时暂停自动同步（它自己同步一轮）
    var syncHeld = false
    var syncObserver: NSObjectProtocol?
    /// 解锁页上的一句提示（比如别的设备改了主密码，要用新主密码）
    var lockMessage: String?

    let repository: AccountRepository
    private var lastActivity = Date()
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var idleTask: Task<Void, Never>?

    init(repository: AccountRepository = .defaultLocation()) {
        self.repository = repository
        state = repository.exists ? .locked : .noAccount
        startAutoLock()
        startAutoBackup()
        startSyncTriggers()
    }

    var loaded: LoadedAccount? {
        if case .unlocked(let l) = state { l } else { nil }
    }

    var vaults: [UnlockedVault] { loaded?.vaults ?? [] }

    /// 条目在哪个保险库
    func vaultId(of itemId: String) -> String? {
        vaults.first { v in v.activeItems.contains { $0.id == itemId } }?.vaultId
    }

    // MARK: 新建、解锁、锁定

    func create(password: String) async throws {
        isWorking = true
        defer { isWorking = false }
        let repo = repository
        let now = Date().unixMilliseconds
        // KDF 很重，放到后台线程，界面不卡
        let loaded = try await Task.detached { try repo.create(password: password, now: now) }.value
        state = .unlocked(loaded)
        TouchIDUnlock.notePasswordEntered()
        enrollTouchIDIfNeeded(loaded.account)
        noteActivity()
    }

    /// 账户带 Secret Key、这台设备上却没有：解锁页要多一个 Secret Key 输入框
    var needsSecretKeyInput: Bool { repository.accountRequiresSecretKey && repository.readSecretKey() == nil }

    func unlock(password: String, secretKey: SecretKey? = nil) async throws {
        isWorking = true
        defer { isWorking = false }
        let repo = repository
        let (loaded, key) = try await Task.detached { try repo.unlockWithLoginKey(password: password, secretKey: secretKey) }.value
        state = .unlocked(loaded)
        loginKey = key
        lockMessage = nil
        TouchIDUnlock.notePasswordEntered()
        enrollTouchIDIfNeeded(loaded.account)
        noteActivity()
        startSync()
    }

    // MARK: 修改主密码

    /// 先用当前主密码重新打开账户文件确认身份，再换成新主密码（只重新包装账户密钥，保险库文件不动）。
    /// 开着同步时新账户文件要马上传上服务端（换登录公钥），传不上就恢复原样并报错（`SyncSetup.changePassword`）；
    /// 登录密钥跟着变，Touch ID 的本机文件重新登记一次
    func changePassword(current: String, new: String) async throws {
        guard case .unlocked(var loaded) = state else { return }
        isWorking = true
        defer { isWorking = false }
        let repo = repository
        let accountId = loaded.account.accountId
        let verify = { @Sendable () throws -> UnlockedAccount in
            let account = try UnlockedAccount.open(try VaultStore.read(repo.accountURL), password: current, secretKey: repo.readSecretKey())
            guard account.accountId == accountId else { throw VaultError.wrongPassword }
            return account
        }
        let updated: UnlockedAccount
        if repository.readSyncState() != nil {
            guard let client = syncClient else { throw SyncUnavailable.needsLogin }
            syncHeld = true
            defer { syncHeld = false; if syncAgain { syncNow() } }
            await syncTask?.value
            let account = try await Task.detached(operation: verify).value
            do {
                let (changed, key) = try await SyncSetup.changePassword(account: account, to: new, repository: repo, client: client,
                                                                        now: Date().unixMilliseconds)
                updated = changed
                loginKey = key
                syncClient = makeSyncClient()
                // 这一轮可能顺带拉下了别的设备的改动
                loaded.vaults = repository.loadVaults(changed).vaults
            } catch SyncSetup.SetupError.accountChangedElsewhere {
                lockForNewAccountFile()
                throw SyncSetup.SetupError.accountChangedElsewhere
            }
        } else {
            updated = try await Task.detached { () -> UnlockedAccount in
                var account = try verify()
                try account.changePassword(to: new)
                try repo.saveAccount(account)
                return account
            }.value
        }
        loaded.account = updated
        state = .unlocked(loaded)
        TouchIDUnlock.notePasswordEntered()
        if loginKey != nil { enrollTouchIDIfNeeded(updated, force: true) }
        noteActivity()
    }

    // MARK: Secret Key

    /// 启用 Secret Key：生成一把新的，先存进本机设备目录，再用主密码重新包装账户文件（变成 v2）。
    /// 顺序很重要：先写 Secret Key 再写账户文件，中途失败时账户文件还是旧的，不会出现「文件要 Secret Key、本机却没有」。
    func enableSecretKey(password: String) async throws -> SecretKey {
        guard case .unlocked(var loaded) = state else { throw VaultError.wrongPassword }
        isWorking = true
        defer { isWorking = false }
        let repo = repository
        let accountId = loaded.account.accountId
        let updated = try await Task.detached { () -> UnlockedAccount in
            var account = try UnlockedAccount.open(try VaultStore.read(repo.accountURL), password: password, secretKey: repo.readSecretKey())
            guard account.accountId == accountId else { throw VaultError.wrongPassword }
            let sk = SecretKey.generate()
            try repo.writeSecretKey(sk, accountId: accountId)
            try account.setSecretKey(sk, password: password)
            try repo.saveAccount(account)
            return account
        }.value
        loaded.account = updated
        state = .unlocked(loaded)
        noteActivity()
        Task { await backUpNow() }
        return updated.secretKey!
    }

    /// 停用 Secret Key：账户文件变回 v1，删掉本机的 Secret Key。云同步开着时不能停用（界面也拦）。
    func disableSecretKey(password: String) async throws {
        guard case .unlocked(var loaded) = state, let current = loaded.account.secretKey else { return }
        guard repository.readSyncState() == nil else { throw SyncUnavailable.secretKeyInUse }
        isWorking = true
        defer { isWorking = false }
        let repo = repository
        let accountId = loaded.account.accountId
        let updated = try await Task.detached { () -> UnlockedAccount in
            var account = try UnlockedAccount.open(try VaultStore.read(repo.accountURL), password: password, secretKey: current)
            guard account.accountId == accountId else { throw VaultError.wrongPassword }
            try account.setSecretKey(nil, password: password)
            try repo.saveAccount(account)
            repo.removeSecretKey()
            return account
        }.value
        loaded.account = updated
        state = .unlocked(loaded)
        noteActivity()
        Task { await backUpNow() }
    }

    // MARK: Touch ID

    /// 本机已登记、可以用 Touch ID 解锁（解锁页据此显示按钮）
    var canUseTouchID: Bool { TouchIDUnlock.isReady(repository) }

    /// 登记过 Touch ID，但按设置这次必须输主密码（解锁页给一句说明）
    var touchIDNeedsPassword: Bool { TouchIDUnlock.needsPassword(repository) }

    /// Touch ID 解锁。取消时静默；指纹变了或本机文件作废时抛出，界面提示改用主密码
    func unlockWithTouchID() async throws {
        let repo = repository
        let (key, login) = try await TouchIDUnlock.keys(repo: repo)
        isWorking = true
        defer { isWorking = false }
        let loaded = try await Task.detached { try repo.unlock(accountKey: key) }.value
        state = .unlocked(loaded)
        loginKey = login
        lockMessage = nil
        noteActivity()
        startSync()
    }

    /// 主密码解锁成功后：设置里开着 Touch ID、本机还没登记（或登记的是别的账户，或者开了同步却没封登录密钥）就登记一次。
    /// `force`：登录密钥变了（改了主密码、刚开同步），重新登记
    func enrollTouchIDIfNeeded(_ account: UnlockedAccount, force: Bool = false) {
        guard TouchIDUnlock.enabledInSettings, TouchIDUnlock.isAvailable else { return }
        let file = repository.readLocalUnlock()
        guard force || file?.accountId != account.accountId || (loginKey != nil && file?.hasLoginKey == false) else { return }
        try? TouchIDUnlock.enroll(account, loginKey: loginKey, repo: repository)
    }

    /// 设置里切换「使用 Touch ID 解锁」：关掉就删本机文件；打开时如果正处于解锁状态，立即登记
    func setTouchIDEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: TouchIDUnlock.settingKey)
        if on {
            if let account = loaded?.account { try? TouchIDUnlock.enroll(account, loginKey: loginKey, repo: repository) }
        } else {
            TouchIDUnlock.disable(repo: repository)
        }
    }

    func lock() {
        guard case .unlocked = state else { return }
        stopSync()
        state = .locked
        Clipboard.clearIfOwned()
    }

    // MARK: 修改（每次改完立即加密写盘）

    /// 保存条目：已有条目存回它所在的保险库；新条目存进 `vaultId`（不传就用第一个保险库）。
    func save(_ item: VaultItem, into vaultId: String? = nil) {
        guard let target = self.vaultId(of: item.id) ?? vaultId ?? vaults.first?.vaultId else { return }
        mutate([target]) { vaults in
            vaults[target]?.save(item.droppingEmptyFields(), now: Date().unixMilliseconds)
        }
    }

    func delete(id: String) {
        guard let vid = vaultId(of: id) else { return }
        mutate([vid]) { $0[vid]?.delete(id: id, now: Date().unixMilliseconds) }
    }

    func toggleFavorite(id: String) {
        guard let vid = vaultId(of: id),
              var item = vaults.first(where: { $0.vaultId == vid })?.activeItems.first(where: { $0.id == id }) else { return }
        item.favorite.toggle()
        save(item)
    }

    /// 把条目搬到另一个保险库：两个文件都要写
    func move(id: String, to targetId: String) {
        guard let sourceId = vaultId(of: id), sourceId != targetId else { return }
        mutate([sourceId, targetId]) { vaults in
            guard var source = vaults[sourceId], var target = vaults[targetId] else { return }
            UnlockedVault.move(id, from: &source, to: &target, now: Date().unixMilliseconds)
            vaults[sourceId] = source
            vaults[targetId] = target
        }
    }

    // MARK: 保险库

    /// 新建保险库，排在最后；返回它的 id
    @discardableResult
    func createVault(name: String, icon: String, color: String) -> String? {
        guard case .unlocked(var loaded) = state else { return nil }
        let order = (loaded.vaults.map(\.meta.order).max() ?? -1) + 1
        let now = Date().unixMilliseconds
        do {
            let vault = try repository.createVault(
                in: loaded.account, meta: VaultMeta(name: name, icon: icon, color: color, order: order, created: now), now: now)
            loaded.vaults.append(vault)
            state = .unlocked(loaded)
            noteActivity()
            scheduleSync()
            return vault.vaultId
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }

    /// 改保险库的名字、图标、颜色
    func updateVault(id: String, name: String, icon: String, color: String) {
        mutate([id]) { vaults in
            vaults[id]?.meta.name = name
            vaults[id]?.meta.icon = icon
            vaults[id]?.meta.color = color
        }
    }

    /// 删除保险库：只允许删空的，而且至少留一个
    func deleteVault(id: String) {
        guard case .unlocked(var loaded) = state, loaded.vaults.count > 1,
              let vault = loaded.vaults.first(where: { $0.vaultId == id }) else { return }
        do {
            try repository.deleteVault(vault)
            loaded.vaults.removeAll { $0.vaultId == id }
            state = .unlocked(loaded)
            scheduleSync()
        } catch {
            saveError = error.localizedDescription
        }
        noteActivity()
    }

    /// 保存条目到指定保险库；条目原来在别的保险库就先保存再搬过去
    func save(_ item: VaultItem, in vaultId: String) {
        let current = self.vaultId(of: item.id)
        save(item, into: vaultId)
        if let current, current != vaultId { move(id: item.id, to: vaultId) }
    }

    // MARK: 导入

    struct ImportOutcome {
        var imported = 0
        var duplicates = 0
    }

    /// 把导入的条目写进保险库：`vaultName` 不为空时找同名保险库、没有就新建；为空时写进 `vaultId`。
    /// 目标保险库里已有相同的条目（标题、第一个网址、密码都一样）就跳过。每个保险库只写一次盘。
    func importItems(_ items: [VaultItem], vaultName: String?, vaultId: String?) -> ImportOutcome {
        var outcome = ImportOutcome()
        let target: String?
        if let vaultName {
            target = vaults.first { $0.meta.name == vaultName }?.vaultId
                ?? createVault(name: vaultName, icon: "folder", color: VaultMeta.colors[vaults.count % VaultMeta.colors.count])
        } else {
            target = vaultId ?? vaults.first?.vaultId
        }
        guard let target, let existing = vaults.first(where: { $0.vaultId == target }) else { return outcome }
        func key(_ i: VaultItem) -> String { [i.title, i.primaryURL ?? "", i.passwords.first ?? ""].joined(separator: "\u{1F}") }
        var seen = Set(existing.activeItems.map(key))
        var fresh: [VaultItem] = []
        for item in items {
            guard seen.insert(key(item)).inserted else { outcome.duplicates += 1; continue }
            fresh.append(item)
        }
        guard !fresh.isEmpty else { return outcome }
        mutate([target]) { vaults in
            guard var v = vaults[target] else { return }
            for item in fresh {
                // 新条目：save 保留 created，修改时间用原来的，不显示成「刚刚修改」
                v.save(item, now: item.modified)
            }
            vaults[target] = v
        }
        if saveError == nil {
            outcome.imported = fresh.count
            if fetchWebsiteIcons { fetchIconsSequentially(fresh.map(\.id)) }
        }
        return outcome
    }

    /// 导入后一个一个地取网站图标（不并发，避免同时向很多网站发请求）
    private func fetchIconsSequentially(_ ids: [String]) {
        Task { [weak self] in
            for id in ids {
                guard let self, let item = self.activeItem(id), let host = WebsiteIcon.host(forURL: item.primaryURL),
                      item.iconHost != host else { continue }
                guard let result = await WebsiteIcon.fetch(forURL: item.primaryURL) else { continue }
                self.applyIcon(result.png, host: result.host, to: id)
            }
        }
    }

    // MARK: 导出

    /// 导出前再输一次主密码：重新打开账户文件确认身份（和修改主密码一样走 KDF，放后台线程）
    func verifyPassword(_ password: String) async -> Bool {
        guard let accountId = loaded?.account.accountId else { return false }
        isWorking = true
        defer { isWorking = false }
        let repo = repository
        let ok = await Task.detached { () -> Bool in
            guard let account = try? UnlockedAccount.open(try VaultStore.read(repo.accountURL), password: password,
                                                          secretKey: repo.readSecretKey()) else { return false }
            return account.accountId == accountId
        }.value
        if ok { TouchIDUnlock.notePasswordEntered() }
        noteActivity()
        return ok
    }

    /// 选中的保险库里的条目，按保险库顺序
    func exportEntries(vaultIds: Set<String>) -> [Exporter.Entry] {
        vaults.filter { vaultIds.contains($0.vaultId) }.flatMap { v in
            v.activeItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { Exporter.Entry(vault: v.meta.name, item: $0) }
        }
    }

    // MARK: 自动备份

    var backupStore: BackupStore {
        BackupStore(destination: Preferences.backupFolder ?? BackupStore.defaultDestination(for: repository))
    }

    /// 启动时看一次，之后每 15 分钟看一次：开着自动备份、距上次备份超过设定的间隔就备份。
    /// 内容和上一份一样时不会重复备份，所以没改动的日子不会多出备份。
    private func startAutoBackup() {
        lastBackup = backupStore.list().first?.date
        backupTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.backUpIfDue() }
        }
        backUpIfDue()
    }

    func backUpIfDue() {
        guard Preferences.backupEnabled, repository.exists else { return }
        if let last = backupStore.list().first?.date,
           Date().timeIntervalSince(last) < Double(Preferences.backupIntervalHours) * 3600 { return }
        Task { await backUpNow() }
    }

    /// 立即备份（复制加密文件，不需要解锁），然后只留最新的 N 份。返回是否新建了一份。
    @discardableResult
    func backUpNow() async -> Bool {
        guard !isBackingUp else { return false }
        isBackingUp = true
        defer { isBackingUp = false }
        let store = backupStore, repo = repository, keep = Preferences.backupKeep
        let result = await Task.detached { () -> Result<Bool, Error> in
            Result {
                let made = try store.backUp(repo) != nil
                store.prune(keep: keep)
                return made
            }
        }.value
        lastBackup = store.list().first?.date
        switch result {
        case .success(let made):
            backupError = nil
            return made
        case .failure(let e):
            backupError = "备份失败：\(e.localizedDescription)"
            return false
        }
    }

    /// 调小保留份数后，马上删掉多出来的旧备份（不新建）
    func pruneBackups() {
        let store = backupStore, keep = Preferences.backupKeep
        Task.detached { store.prune(keep: keep) }
    }

    /// 换了备份位置后刷新显示
    func refreshBackupInfo() { lastBackup = backupStore.list().first?.date }

    // MARK: 网站图标

    /// 设置里的「自动获取网站图标」，默认开启
    static let fetchIconsKey = Preferences.Key.fetchWebsiteIcons
    var fetchWebsiteIcons: Bool { UserDefaults.standard.object(forKey: Self.fetchIconsKey) as? Bool ?? true }

    private func activeItem(_ id: String) -> VaultItem? {
        vaults.lazy.flatMap(\.activeItems).first { $0.id == id }
    }

    /// 条目第一个网址的主机变了就在后台取网站图标（`force`：不管开关和主机，重新取）。
    /// 网址删了或变成内网地址，就恢复成类型图标。取不到就保持原样，下次保存再试。
    func refreshIcon(for itemId: String, force: Bool = false) {
        guard force || fetchWebsiteIcons, let item = activeItem(itemId) else { return }
        guard let host = WebsiteIcon.host(forURL: item.primaryURL) else {
            if item.iconData != nil || item.iconHost != nil {
                var it = item
                it.iconData = nil
                it.iconHost = nil
                save(it)
            }
            return
        }
        guard force || host != item.iconHost else { return }
        let url = item.primaryURL
        Task { [weak self] in
            guard let result = await WebsiteIcon.fetch(forURL: url) else { return }
            self?.applyIcon(result.png, host: result.host, to: itemId)
        }
    }

    /// 取回来时条目可能已经改了网址、被删了或者已经锁定：都对得上才写回
    private func applyIcon(_ png: Data, host: String, to itemId: String) {
        guard var it = activeItem(itemId), WebsiteIcon.host(forURL: it.primaryURL) == host else { return }
        it.iconData = png
        it.iconHost = host
        save(it)
    }

    /// 不要网站图标：清掉图标，但记下主机，之后保存时不会再自动去取
    func useDefaultIcon(for itemId: String) {
        guard var it = activeItem(itemId) else { return }
        it.iconData = nil
        it.iconHost = WebsiteIcon.host(forURL: it.primaryURL)
        save(it)
    }

    /// 改动 `ids` 这几个保险库并写盘。写盘失败就整体不改内存里的状态，界面上看到的始终和文件一致。
    private func mutate(_ ids: [String], _ change: (inout [String: UnlockedVault]) -> Void) {
        guard case .unlocked(var loaded) = state else { return }
        var byId = Dictionary(uniqueKeysWithValues: loaded.vaults.map { ($0.vaultId, $0) })
        change(&byId)
        let now = Date().unixMilliseconds
        do {
            for id in ids {
                guard var v = byId[id] else { continue }
                try repository.save(&v, now: now)
                byId[id] = v
            }
            loaded.vaults = loaded.vaults.map { byId[$0.vaultId] ?? $0 }
            state = .unlocked(loaded)
            scheduleSync()
        } catch {
            saveError = error.localizedDescription
        }
        noteActivity()
    }

    // MARK: 自动锁定

    func noteActivity() { lastActivity = Date() }

    private func startAutoLock() {
        // 键盘、鼠标操作都算活动
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.noteActivity() }
            return event
        }
        // 系统睡眠、锁屏、屏保、切换用户：立即锁定（设置里可以关）
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if Preferences.lockOnSleep { self?.lock() } }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if Preferences.lockOnSleep { self?.lock() } }
        })
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                let minutes = Preferences.autoLockMinutes // 0 = 从不
                if case .unlocked = self.state, minutes > 0,
                   Date().timeIntervalSince(self.lastActivity) >= Double(minutes * 60) {
                    self.lock()
                }
            }
        }
    }
}

extension VaultError {
    /// 给用户看的提示（不带内部细节）
    var userMessage: String {
        switch self {
        case .wrongPassword: "主密码不正确"
        case .unsupportedVersion: "这个保险库是更新版本的 1Melon 创建的，请先升级 1Melon"
        case .unsafeKDFParameters: "保险库文件头的参数不安全，可能被改动过，已拒绝打开"
        case .tampered: "保险库文件已损坏或被篡改，已拒绝打开。请从备份恢复"
        case .invalidFormat: "这不是 1Melon 保险库文件"
        case .secretKeyRequired: "这个账户需要 Secret Key"
        case .wrongSecretKey: "Secret Key 不对，请对照应急资料检查"
        }
    }
}

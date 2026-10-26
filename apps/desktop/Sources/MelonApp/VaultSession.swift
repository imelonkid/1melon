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

    private(set) var state: State
    /// 解锁 / 新建时正在派生密钥（约 0.3 秒，debug 构建更久）
    private(set) var isWorking = false
    /// 最近一次写盘失败的原因；界面弹窗提示
    var saveError: String?

    /// 闲置多久自动锁定（设置页以后可以改）
    var autoLockAfter: Duration = .seconds(5 * 60)

    private let repository: AccountRepository
    private var lastActivity = Date()
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var idleTask: Task<Void, Never>?

    init(repository: AccountRepository = .defaultLocation()) {
        self.repository = repository
        state = repository.exists ? .locked : .noAccount
        startAutoLock()
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
        noteActivity()
    }

    func unlock(password: String) async throws {
        isWorking = true
        defer { isWorking = false }
        let repo = repository
        let loaded = try await Task.detached { try repo.unlock(password: password) }.value
        state = .unlocked(loaded)
        noteActivity()
    }

    func lock() {
        guard case .unlocked = state else { return }
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
        // 系统睡眠、锁屏、屏保：立即锁定
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if case .unlocked = self.state,
                   Date().timeIntervalSince(self.lastActivity) >= Double(self.autoLockAfter.components.seconds) {
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
        }
    }
}

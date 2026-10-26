import AppKit
import MelonCore
import Observation

/// 保险库会话：没有保险库 → 新建；已锁定 → 解锁；已解锁 → 读写条目。
/// 明文只在 `.unlocked` 里；锁定时整个 `UnlockedVault` 被丢掉，剪贴板里我们写的内容一并清掉。
@MainActor
@Observable
final class VaultSession {
    enum State {
        case noVault
        case locked
        case unlocked(UnlockedVault)
    }

    private(set) var state: State
    /// 解锁 / 新建时正在派生密钥（约 0.3 秒，debug 构建更久）
    private(set) var isWorking = false
    /// 最近一次写盘失败的原因；界面弹窗提示
    var saveError: String?

    /// 闲置多久自动锁定（设置页以后可以改）
    var autoLockAfter: Duration = .seconds(5 * 60)

    private let repository: VaultRepository
    private var lastActivity = Date()
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var idleTask: Task<Void, Never>?

    init(repository: VaultRepository = .defaultLocation()) {
        self.repository = repository
        state = repository.exists ? .locked : .noVault
        startAutoLock()
    }

    var vault: UnlockedVault? {
        if case .unlocked(let v) = state { v } else { nil }
    }

    // MARK: 新建、解锁、锁定

    func create(password: String) async throws {
        isWorking = true
        defer { isWorking = false }
        let repo = repository
        let now = Date().unixMilliseconds
        // KDF 很重，放到后台线程，界面不卡
        let vault = try await Task.detached { try repo.create(password: password, now: now) }.value
        state = .unlocked(vault)
        noteActivity()
    }

    func unlock(password: String) async throws {
        isWorking = true
        defer { isWorking = false }
        let repo = repository
        let vault = try await Task.detached { try repo.unlock(password: password) }.value
        state = .unlocked(vault)
        noteActivity()
    }

    func lock() {
        guard case .unlocked = state else { return }
        state = .locked
        Clipboard.clearIfOwned()
    }

    // MARK: 修改（每次改完立即加密写盘）

    func save(_ item: VaultItem) {
        mutate { $0.save(item.droppingEmptyFields(), now: Date().unixMilliseconds) }
    }

    func delete(id: String) {
        mutate { $0.delete(id: id, now: Date().unixMilliseconds) }
    }

    func toggleFavorite(id: String) {
        guard var item = vault?.items.first(where: { $0.id == id }) else { return }
        item.favorite.toggle()
        save(item)
    }

    private func mutate(_ change: (inout UnlockedVault) -> Void) {
        guard case .unlocked(var v) = state else { return }
        let before = v
        change(&v)
        do {
            try repository.save(&v, now: Date().unixMilliseconds)
            state = .unlocked(v)
        } catch {
            // 写盘失败就不改内存里的状态，界面上看到的始终和文件一致
            state = .unlocked(before)
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

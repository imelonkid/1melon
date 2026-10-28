import AppKit
import SwiftUI

@main
struct MelonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = VaultSession()

    var body: some Scene {
        WindowGroup("1Melon") {
            RootView()
                .environment(session)
                .tint(Theme.accent)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1200, height: 760)
        // 设计稿：没有标题栏，内容一直铺到顶，红绿灯压在侧栏上
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("导入…") { session.importRequested = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(session.loaded == nil)
                Button("导出…") { session.exportRequested = true }
                    .disabled(session.loaded == nil)
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { Task { await Updater.shared.check(manual: true) } }
            }
            CommandMenu("保险库") {
                Button("立即锁定") { session.lock() }
                    .keyboardShortcut("l")
                    .disabled(session.loaded == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(session)
                .tint(Theme.accent)
        }
    }
}

/// 按会话状态切换：新建保险库 / 解锁 / 主界面。
struct RootView: View {
    @Environment(VaultSession.self) private var session

    var body: some View {
        switch session.state {
        case .noAccount: FirstLaunchView()
        case .locked: UnlockView()
        case .unlocked(let loaded): MainView(loaded: loaded)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` 直接跑可执行文件（不是 .app）时，也要像普通 App 一样有 Dock 图标和前台窗口
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Preferences.applyAppearance()
        Updater.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Clipboard.clearIfOwned()
    }
}

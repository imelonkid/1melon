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
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 760)
        // 工具栏里已经没有按钮，用紧凑样式让顶部那一条矮一截
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("保险库") {
                Button("立即锁定") { session.lock() }
                    .keyboardShortcut("l")
                    .disabled(session.loaded == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// 按会话状态切换：新建保险库 / 解锁 / 主界面。
struct RootView: View {
    @Environment(VaultSession.self) private var session

    var body: some View {
        switch session.state {
        case .noAccount: CreateVaultView()
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Clipboard.clearIfOwned()
    }
}

/// 设置（⌘,）。完整的设置页在后面的步骤里做，这里先放网站图标的开关。
struct SettingsView: View {
    @AppStorage(VaultSession.fetchIconsKey) private var fetchIcons = true

    var body: some View {
        Form {
            Section {
                Toggle("自动获取网站图标", isOn: $fetchIcons)
                Text("保存条目时，如果网址变了，就直接向这个网站请求一次它的图标，网站会知道有人访问了它的图标。不经过任何第三方服务；IP、localhost、.local 这类内网地址不请求。取到的图标加密存在条目里。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}

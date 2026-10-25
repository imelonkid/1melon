import AppKit
import SwiftUI

@main
struct MelonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("1Melon") {
            GeneratorView()
                .frame(width: 460)
        }
        .windowResizability(.contentSize)
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

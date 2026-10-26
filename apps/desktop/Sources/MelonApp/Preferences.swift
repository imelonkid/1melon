import AppKit
import SwiftUI

/// 本机设置（UserDefaults）。**只放界面和行为偏好，不放任何机密**；不进保险库、不同步。
/// 键名集中在这里，界面用 `@AppStorage(Preferences.Key.xxx)` 读写，行为代码用下面的计算属性读。
enum Preferences {
    enum Key {
        static let fetchWebsiteIcons = "fetchWebsiteIcons"
        static let touchID = "unlock.touchID"
        /// Touch ID 最多连续用多少天，之后要求输一次主密码；0 = 每次启动后第一次都要主密码
        static let requirePasswordDays = "unlock.requirePasswordDays"
        static let lastPasswordUnlock = "unlock.lastPasswordUnlock"
        /// 闲置多少分钟自动锁定；0 = 从不
        static let autoLockMinutes = "lock.autoLockMinutes"
        static let lockOnSleep = "lock.onSleep"
        /// 复制敏感内容后多少秒清剪贴板；0 = 从不
        static let clipboardClearSeconds = "clipboard.clearSeconds"
        static let appearance = "appearance"
        static let colorizePasswords = "appearance.colorizePasswords"
    }

    private static var d: UserDefaults { .standard }
    private static func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }

    static var requirePasswordDays: Int { int(Key.requirePasswordDays, 14) }
    static var autoLockMinutes: Int { int(Key.autoLockMinutes, 5) }
    static var lockOnSleep: Bool { bool(Key.lockOnSleep, true) }
    static var clipboardClearSeconds: Int { int(Key.clipboardClearSeconds, 30) }

    /// 上次用主密码解锁的时间（只是时间，不是机密）
    static var lastPasswordUnlock: Date? {
        get { d.object(forKey: Key.lastPasswordUnlock) as? Date }
        set { d.set(newValue, forKey: Key.lastPasswordUnlock) }
    }

    /// 设置里给用户选的选项
    static let autoLockChoices: [(Int, String)] = [(1, "1 分钟"), (5, "5 分钟"), (15, "15 分钟"), (60, "1 小时"), (0, "从不")]
    static let clipboardChoices: [(Int, String)] = [(15, "15 秒"), (30, "30 秒"), (60, "1 分钟"), (0, "从不")]
    static let requirePasswordChoices: [(Int, String)] = [(0, "每次启动后"), (1, "每天"), (7, "每周"), (14, "每两周"), (30, "每月")]

    /// 外观：浅色 / 深色 / 跟随系统
    enum Appearance: String, CaseIterable {
        case light, dark, system
        var label: String {
            switch self {
            case .light: "浅色"
            case .dark: "深色"
            case .system: "跟随系统"
            }
        }
        var symbol: String {
            switch self {
            case .light: "sun.max"
            case .dark: "moon"
            case .system: "circle.lefthalf.filled"
            }
        }
    }

    @MainActor
    static func applyAppearance() {
        let value = Appearance(rawValue: d.string(forKey: Key.appearance) ?? "") ?? .system
        switch value {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}

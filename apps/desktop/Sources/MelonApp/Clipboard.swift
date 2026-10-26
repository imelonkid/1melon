import AppKit

/// 复制密码等敏感内容：标记为「隐藏」类型（剪贴板管理器约定不记录），到时间后如果剪贴板还是我们写的内容就清空。
@MainActor
enum Clipboard {
    private static var ownedChangeCount: Int?
    private static var clearTask: Task<Void, Never>?

    /// `clearAfter` 默认取设置里的时间；0 = 不自动清除（仍然标记为隐藏类型）
    static func copySecret(_ text: String, clearAfter seconds: Int = Preferences.clipboardClearSeconds) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pb.changeCount
        ownedChangeCount = count

        clearTask?.cancel()
        guard seconds > 0 else { return }
        clearTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            clearIfOwned()
        }
    }

    /// 复制不敏感的内容（用户名、网址）：不标隐藏、不自动清除。
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ownedChangeCount = nil
        clearTask?.cancel()
    }

    /// 复制提示里的后半句，例如「30 秒后自动清除」；设成从不时为空
    static var clearHint: String {
        let s = Preferences.clipboardClearSeconds
        return s == 0 ? "" : (s >= 60 && s % 60 == 0 ? "\(s / 60) 分钟后自动清除" : "\(s) 秒后自动清除")
    }

    /// 剪贴板没被别人改过才清，避免把用户之后自己复制的内容清掉。
    static func clearIfOwned() {
        let pb = NSPasteboard.general
        if let owned = ownedChangeCount, pb.changeCount == owned {
            pb.clearContents()
        }
        ownedChangeCount = nil
    }
}

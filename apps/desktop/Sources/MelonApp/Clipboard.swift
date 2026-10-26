import AppKit

/// 复制密码等敏感内容：标记为「隐藏」类型（剪贴板管理器约定不记录），到时间后如果剪贴板还是我们写的内容就清空。
@MainActor
enum Clipboard {
    private static var ownedChangeCount: Int?
    private static var clearTask: Task<Void, Never>?

    static func copySecret(_ text: String, clearAfter seconds: Int = 30) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pb.changeCount
        ownedChangeCount = count

        clearTask?.cancel()
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

    /// 剪贴板没被别人改过才清，避免把用户之后自己复制的内容清掉。
    static func clearIfOwned() {
        let pb = NSPasteboard.general
        if let owned = ownedChangeCount, pb.changeCount == owned {
            pb.clearContents()
        }
        ownedChangeCount = nil
    }
}

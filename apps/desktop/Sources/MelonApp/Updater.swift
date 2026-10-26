import AppKit
import MelonCore

/// 检查更新（项目基线「桌面应用 · 客户端更新」）：读对象存储上的版本清单 latest.json，有更新的版本就提示下载。
/// - 启动 10 秒后读一次，之后每 6 小时一次，电脑唤醒后也读一次；读失败静默，下次再试
/// - 菜单「检查更新…」手动读一次：没有新版、读失败也给结果，跳过过的版本照样提示
/// - 清单的 version 按语义化版本**大于**自己的版本（构建时注入的 CFBundleShortVersionString）才提示；
///   本机编的开发版（CFBundleVersion 是 dev，或者直接 swift run、没有 Info.plist）不自动查
/// - 提示：每个新版本第一次发现时弹一次，显示更新说明；可以下载（系统浏览器打开安装包地址）、跳过这个版本、以后再说
/// - 没有 Apple 开发者签名，做不了静默安装：下载后拖到「应用程序」覆盖
@MainActor
final class Updater {
    static let shared = Updater()

    private static let manifestURL = URL(string: "https://melon-download.oss-cn-beijing.aliyuncs.com/1melon/desktop/latest.json")!
    private let skipKey = "update.skippedVersion"
    private var prompted: Set<String> = []
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    private var isDevBuild: Bool { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev").hasPrefix("dev") }

    func start() {
        guard !isDevBuild, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in Task { await self?.check() } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        // 唤醒后网络要一会儿才通，晚 30 秒再读
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { Task { await self?.check() } }
        }
    }

    /// 读一次清单；有更新的版本就（每个版本第一次）提示。manual：菜单手动检查，结果一定告诉用户
    func check(manual: Bool = false) async {
        var req = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("1Melon/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(ReleaseManifest.self, from: data) else {
            if manual { notice("检查更新失败", "读不到版本信息，检查一下网络后再试。") }
            return
        }
        guard SemVer.isNewer(rel.version, than: currentVersion) else {
            if manual { notice("已是最新", "当前 v\(currentVersion) 已是最新版本。") }
            return
        }
        if manual || (UserDefaults.standard.string(forKey: skipKey) != rel.version && !prompted.contains(rel.version)) {
            prompted.insert(rel.version)
            prompt(rel)
        }
    }

    private func prompt(_ rel: ReleaseManifest) {
        let alert = NSAlert()
        alert.messageText = "1Melon \(rel.tag) 可以更新了"
        let notes = (rel.notes ?? "").isEmpty ? "" : "更新内容：\n\(rel.notes!)\n\n"
        alert.informativeText = "当前版本 v\(currentVersion)。\n\n" + notes + "下载后打开安装包，把 1Melon 拖到「应用程序」覆盖即可。保险库数据不受影响。"
        alert.addButton(withTitle: "下载")
        alert.addButton(withTitle: "以后再说")
        alert.addButton(withTitle: "跳过这个版本")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = rel.downloadURL { NSWorkspace.shared.open(url) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(rel.version, forKey: skipKey)
        default:
            break
        }
    }

    private func notice(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

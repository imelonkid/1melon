import AppKit
import MelonCore
import ServiceManagement
import SwiftUI

/// 设置（⌘,）：通用 / 安全 / 数据 / 外观。只放已经能用的选项。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            SecuritySettings().tabItem { Label("安全", systemImage: "lock") }
            DataSettings().tabItem { Label("数据", systemImage: "externaldrive") }
            AppearanceSettings().tabItem { Label("外观", systemImage: "paintbrush") }
        }
        .frame(width: 520)
    }
}

/// 设置里的一行说明文字
private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: 通用

private struct GeneralSettings: View {
    @Environment(VaultSession.self) private var session
    @AppStorage(Preferences.Key.fetchWebsiteIcons) private var fetchIcons = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                // 用闭包包一层：直接传方法引用 `set: setLaunchAtLogin` 会让 Swift 6.3 编译器崩溃
                Toggle("登录时启动 1Melon", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginError { Hint(loginError) }
            }
            Section {
                Toggle("自动获取网站图标", isOn: $fetchIcons)
                Hint("保存条目时，如果网址变了，就直接向这个网站请求一次它的图标，网站会知道有人访问了它的图标。不经过任何第三方服务；IP、localhost、.local 这类内网地址不请求。取到的图标加密存在条目里。")
            }
            Section("保险库位置") {
                LabeledContent {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([session.repository.root]) }
                } label: {
                    Text(abbreviated(session.repository.root.path)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                Hint("account.1melon 是账户文件，vaults/ 里每个保险库一个文件，都是加密的；device/ 只属于这台 Mac（Touch ID 用）。")
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "设置失败：要从「应用程序」里的 1Melon 启动才能开启（直接 swift run 的开发版不行）。"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: 数据

private struct DataSettings: View {
    @Environment(VaultSession.self) private var session
    @AppStorage(Preferences.Key.backupEnabled) private var enabled = true
    @AppStorage(Preferences.Key.backupIntervalHours) private var interval = 24
    @AppStorage(Preferences.Key.backupKeep) private var keep = 30
    @AppStorage(Preferences.Key.backupFolder) private var folder = ""
    @State private var backupResult: String?

    private var destination: URL { session.backupStore.destination }

    var body: some View {
        Form {
            Section("导入与导出") {
                LabeledContent {
                    HStack {
                        Button("导入…") { bringMainWindow { session.importRequested = true } }
                        Button("导出…") { bringMainWindow { session.exportRequested = true } }
                    }
                    .disabled(session.loaded == nil)
                } label: {
                    Text("1Password、Bitwarden、浏览器")
                }
                Hint(session.loaded == nil ? "先解锁才能导入导出。" : "导出的 CSV 是明文，只在换到别的密码管理器时用，用完马上删掉。")
            }
            Section("自动备份") {
                Toggle("自动备份", isOn: $enabled)
                    .onChange(of: enabled) { _, on in if on { session.backUpIfDue() } }
                Picker("频率", selection: $interval) {
                    ForEach(Preferences.backupIntervalChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .disabled(!enabled)
                Picker("保留", selection: $keep) {
                    ForEach(Preferences.backupKeepChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .disabled(!enabled)
                LabeledContent {
                    HStack {
                        Button("更改…", action: chooseFolder)
                        if !folder.isEmpty { Button("恢复默认") { folder = ""; session.refreshBackupInfo() } }
                        Button("在访达中显示") { reveal(destination) }
                    }
                } label: {
                    Text(abbreviated(destination.path)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent {
                    Button(session.isBackingUp ? "正在备份…" : "立即备份") {
                        Task {
                            let made = await session.backUpNow()
                            backupResult = session.backupError ?? (made ? "已备份" : "和上一份一样，没有重复备份")
                        }
                    }
                    .disabled(session.isBackingUp || !session.repository.exists)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.lastBackup.map { "上次备份：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "还没有备份")
                        if let msg = backupResult ?? session.backupError {
                            Text(msg).font(.system(size: 12))
                                .foregroundStyle(session.backupError != nil ? Theme.danger : .secondary)
                        }
                    }
                }
                Hint("备份的是加密文件原样复制，不需要解锁；内容没变时不会重复备份。默认放在保险库位置的 backups/ 里，换到外置硬盘或网盘文件夹更安全。恢复：退出 1Melon，把某份备份里的 account.1melon 和 vaults/ 复制回保险库位置。注意要用备份当时的主密码解锁。")
            }
        }
        .formStyle(.grouped)
        .onChange(of: keep) { _, _ in session.pruneBackups() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择存放备份的文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
        session.refreshBackupInfo()
        if enabled { session.backUpIfDue() }
    }

    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    /// 导入导出的窗口在主窗口里打开：先把主窗口叫到前面
    private func bringMainWindow(_ request: () -> Void) {
        request()
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible && !($0.identifier?.rawValue.contains("Settings") ?? false) }?
            .makeKeyAndOrderFront(nil)
    }
}

private func abbreviated(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: 安全

private struct SecuritySettings: View {
    @Environment(VaultSession.self) private var session
    @AppStorage(Preferences.Key.touchID) private var touchID = true
    @AppStorage(Preferences.Key.requirePasswordDays) private var requireDays = 14
    @AppStorage(Preferences.Key.autoLockMinutes) private var autoLock = 5
    @AppStorage(Preferences.Key.lockOnSleep) private var lockOnSleep = true
    @AppStorage(Preferences.Key.clipboardClearSeconds) private var clipboard = 30
    @State private var changingPassword = false
    @State private var secretKeyAction: SecretKeySheet.Action?
    @State private var revealSecretKey = false

    var body: some View {
        Form {
            Section("解锁") {
                Toggle("使用 Touch ID 解锁", isOn: Binding(get: { touchID }, set: { session.setTouchIDEnabled($0) }))
                    .disabled(!TouchIDUnlock.isAvailable)
                Picker("要求输入主密码", selection: $requireDays) {
                    ForEach(Preferences.requirePasswordChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .disabled(!touchID || !TouchIDUnlock.isAvailable)
                Hint(TouchIDUnlock.isAvailable
                     ? "账户密钥用这台 Mac 安全隔区里的一把密钥加密，每次解锁都要验证指纹，指纹有增删时自动失效。隔一段时间要求输一次主密码，免得忘了它。"
                     : "这台 Mac 不支持 Touch ID，或者还没有登记指纹。")
            }
            Section("自动锁定") {
                Picker("闲置后自动锁定", selection: $autoLock) {
                    ForEach(Preferences.autoLockChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("系统睡眠、锁屏或切换用户时锁定", isOn: $lockOnSleep)
            }
            Section("剪贴板") {
                Picker("复制密码后自动清除剪贴板", selection: $clipboard) {
                    ForEach(Preferences.clipboardChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Hint("只清除 1Melon 自己复制进去的内容；这期间你又复制了别的东西，就不动。")
            }
            Section("主密码") {
                LabeledContent("主密码") {
                    Button("修改主密码…") { changingPassword = true }
                        .disabled(session.loaded == nil)
                }
                Hint(session.loaded == nil ? "解锁后才能修改。" : "只重新加密账户密钥，保险库不用重新加密；Touch ID 继续可用。")
            }
            Section("Secret Key") {
                if let sk = session.loaded?.account.secretKey {
                    LabeledContent {
                        HStack {
                            Button(revealSecretKey ? "隐藏" : "显示") { revealSecretKey.toggle() }
                            Button("复制") { Clipboard.copySecret(sk.text) }
                            Button("停用…") { secretKeyAction = .disable }
                        }
                    } label: {
                        Text(revealSecretKey ? sk.text : "M1-•••••••-•••••••-•••••••-•••••••")
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    Hint("已启用。解锁要主密码和 Secret Key 两样；Secret Key 只存在这台 Mac 上，不进备份。请把它抄下来，和主密码分开保存：换 Mac 或从备份恢复时要用。")
                } else {
                    LabeledContent("未启用") {
                        Button("启用…") { secretKeyAction = .enable }
                            .disabled(session.loaded == nil)
                    }
                    Hint("一把只存在设备上的 128 位随机密钥，和主密码一起才能解开账户。开启云同步时必须启用：这样就算云上的文件被人拿到，没有它也没法暴力破解主密码。")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
        .sheet(item: $secretKeyAction) { SecretKeySheet(action: $0) }
    }
}

/// 启用 / 停用 Secret Key：都要输主密码。启用后显示新 Secret Key，确认抄好了才关。
private struct SecretKeySheet: View {
    enum Action: String, Identifiable {
        case enable, disable
        var id: String { rawValue }
    }

    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let action: Action
    @State private var password = ""
    @State private var error: String?
    @State private var created: SecretKey?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(action == .enable ? "启用 Secret Key" : "停用 Secret Key").font(.system(size: 15, weight: .semibold))
            if let created { createdView(created) } else { confirmView }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 420)
    }

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // LocalizedStringKey 才会渲染 **加粗**
            Text(LocalizedStringKey(action == .enable
                 ? "会生成一把新的 Secret Key，存在这台 Mac 上。之后在别的 Mac 上、或者从备份恢复时，要同时输入主密码和 Secret Key 才能解锁。**主密码和 Secret Key 丢了任何一样，又没有一台 Mac 还登录着，数据就再也找不回来。**"
                 : "账户会变回只用主密码解锁，这台 Mac 上的 Secret Key 会删掉。以后再启用会换一把新的。"))
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("主密码", text: $password).onSubmit(run)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: run) {
                    if session.isWorking { ProgressView().controlSize(.small) } else { Text(action == .enable ? "启用" : "停用") }
                }
                .buttonStyle(.borderedProminent).tint(action == .enable ? Theme.accent : Theme.danger)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || session.isWorking)
            }
        }
    }

    private func createdView(_ sk: SecretKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这是你的 Secret Key。现在就抄下来，和主密码分开保存（比如写在纸上锁起来）：")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(sk.text)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            HStack {
                Button("复制") { Clipboard.copySecret(sk.text) }
                Spacer()
            }
            Toggle("我已经把 Secret Key 保存好了", isOn: $saved).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!saved)
            }
        }
        .interactiveDismissDisabled(!saved)
    }

    private func run() {
        guard !password.isEmpty, !session.isWorking else { return }
        let pw = password
        Task {
            do {
                if action == .enable {
                    created = try await session.enableSecretKey(password: pw)
                } else {
                    try await session.disableSecretKey(password: pw)
                    dismiss()
                }
                password = ""
            } catch let e as VaultError {
                error = e == .wrongPassword ? "主密码不正确" : e.userMessage
            } catch {
                self.error = "操作失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 修改主密码：当前密码 + 新密码（强度至少「一般」、两次一致）
private struct ChangePasswordSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?

    private var strength: PasswordStrength { PasswordStrength.evaluate(new) }
    private var canSave: Bool {
        !current.isEmpty && !new.isEmpty && new == confirm && strength.level >= .fair && new != current && !session.isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修改主密码").font(.system(size: 15, weight: .semibold))
            SecureField("当前主密码", text: $current)
            SecureField("新主密码", text: $new)
            SecureField("再输入一次新主密码", text: $confirm).onSubmit(save)
            StrengthBar(strength: strength).opacity(new.isEmpty ? 0 : 1)
            if !confirm.isEmpty && confirm != new {
                Text("两次输入不一致").font(.system(size: 12)).foregroundStyle(Theme.danger)
            } else if !new.isEmpty && strength.level < .fair {
                Text("新主密码太弱。建议用 4 个以上随机单词，或 14 位以上混合字符").font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            Text("主密码不会保存在任何地方，忘记新主密码就无法找回保险库里的数据。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: save) {
                    if session.isWorking { ProgressView().controlSize(.small) } else { Text("修改") }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 380)
    }

    private func save() {
        guard canSave else { return }
        let (c, n) = (current, new)
        Task {
            do {
                try await session.changePassword(current: c, new: n)
                dismiss()
            } catch let e as VaultError {
                error = e == .wrongPassword ? "当前主密码不正确" : e.userMessage
            } catch {
                self.error = "修改失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: 外观

private struct AppearanceSettings: View {
    @AppStorage(Preferences.Key.appearance) private var appearance = Preferences.Appearance.system.rawValue
    @AppStorage(Preferences.Key.colorizePasswords) private var colorize = true

    var body: some View {
        Form {
            Section {
                Picker("外观", selection: $appearance) {
                    ForEach(Preferences.Appearance.allCases, id: \.rawValue) { a in
                        Label(a.label, systemImage: a.symbol).tag(a.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { Preferences.applyAppearance() }
            }
            Section {
                Toggle("密码字符着色", isOn: $colorize)
                HStack {
                    Hint("数字和符号用不同颜色，便于辨认，例如：")
                    PasswordText(value: "v7#Qm2!xLp", size: 13)
                }
            }
        }
        .formStyle(.grouped)
    }
}

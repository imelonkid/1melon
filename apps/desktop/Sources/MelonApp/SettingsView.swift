import AppKit
import MelonCore
import ServiceManagement
import SwiftUI

/// 设置（⌘,）：通用 / 安全 / 外观。只放已经能用的选项；导入导出、自动备份做好后再加「数据」页。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            SecuritySettings().tabItem { Label("安全", systemImage: "lock") }
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

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
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
        }
        .formStyle(.grouped)
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
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

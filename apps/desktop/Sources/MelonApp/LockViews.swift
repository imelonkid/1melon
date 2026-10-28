import AppKit
import MelonCore
import SwiftUI

/// 品牌标志：橙色圆角方块 + 白色图标（侧栏品牌头、解锁页、首次启动）。
struct AppMark: View {
    var size: CGFloat = 80
    var symbol = "checkmark.shield"

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(Theme.accent)
            .frame(width: size, height: size)
            .shadow(color: Theme.accent.opacity(0.32), radius: size * 0.18, y: size * 0.1)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(.white))
    }
}

/// 解锁页、首次启动的大按钮：整宽、橙底白字
struct CTAButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent))
            .shadow(color: Theme.accent.opacity(isEnabled ? 0.28 : 0), radius: 7, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

/// 左上角的「‹ 返回」（首次启动的子页面）
struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("返回", systemImage: "chevron.left").font(.system(size: 13)).foregroundStyle(Theme.text2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }
}

/// 解锁页（设计稿「解锁页」）：主密码，或者 Touch ID（本机登记过时出现，进入解锁页时自动弹一次）。
struct UnlockView: View {
    @Environment(VaultSession.self) private var session
    @State private var password = ""
    /// 账户带 Secret Key、这台设备上没有时才显示（比如从备份恢复到新 Mac）
    @State private var needsSecretKey = false
    @State private var secretKeyText = ""
    @FocusState private var secretKeyFocused: Bool
    @State private var error: String?
    @State private var shakes = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            AppMark(symbol: "lock")
            Text("1Melon").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text).padding(.top, 20)
            Text("个人保险库已锁定").foregroundStyle(Theme.text2).padding(.top, 4)
            if let message = session.lockMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center).frame(width: 320).padding(.top, 10)
            }

            if needsSecretKey {
                VStack(spacing: 6) {
                    TextField("Secret Key（M1-…）", text: $secretKeyText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($secretKeyFocused)
                        .onSubmit { focused = true }
                        .onChange(of: secretKeyText) { error = nil }
                        .padding(.horizontal, 14)
                        .frame(width: 320, height: 44)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.line2, lineWidth: 0.5))
                    Text("这台 Mac 上没有这个账户的 Secret Key，请照应急资料输入，只需输一次")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .multilineTextAlignment(.center).frame(width: 320)
                }
                .padding(.top, 28)
            }

            HStack(spacing: 6) {
                SecureField("输入主密码", text: $password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(unlock)
                    .onChange(of: password) { error = nil }
                if session.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: unlock) {
                        Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
                    .foregroundStyle(.white)
                    .disabled(password.isEmpty)
                }
            }
            .padding(.leading, 14).padding(.trailing, 5)
            .frame(width: 320, height: 44)
            .background(RoundedRectangle(cornerRadius: 13).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(error == nil ? Theme.line2 : Theme.danger, lineWidth: error == nil ? 0.5 : 1))
            .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
            .modifier(Shake(count: shakes))
            .padding(.top, needsSecretKey ? 12 : 28)

            Text(error ?? " ").font(.system(size: 12)).foregroundStyle(Theme.danger).frame(height: 18).padding(.top, 8)

            if touchIDNeedsPassword {
                Text(Preferences.requirePasswordDays == 0
                     ? "启动后第一次解锁需要输入主密码，之后可以用 Touch ID"
                     : "已经有一段时间没有输入主密码了，这次请输入主密码，之后可以继续用 Touch ID")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center).frame(width: 320)
                    .padding(.top, 6)
            }
            if touchIDReady {
                Button(action: unlockWithTouchID) {
                    Label("使用 Touch ID 解锁", systemImage: "touchid").font(.system(size: 13.5))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentText)
                .disabled(session.isWorking)
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onAppear {
            needsSecretKey = session.needsSecretKeyInput
            if needsSecretKey { secretKeyFocused = true } else { focused = true }
            touchIDReady = session.canUseTouchID
            touchIDNeedsPassword = session.touchIDNeedsPassword
            autoPromptTouchID()
        }
        // 刚启动或从别的 App 切回来时窗口才变成活动状态：那时再弹
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            autoPromptTouchID()
        }
    }

    @State private var touchIDReady = false
    @State private var touchIDNeedsPassword = false
    @State private var autoPrompted = false

    /// 每次进入解锁页只自动弹一次 Touch ID（取消了就留在主密码输入框，不再打扰）
    private func autoPromptTouchID() {
        guard touchIDReady, !autoPrompted, NSApp.isActive else { return }
        autoPrompted = true
        unlockWithTouchID()
    }

    private func unlockWithTouchID() {
        guard !session.isWorking else { return }
        Task {
            do {
                try await session.unlockWithTouchID()
            } catch TouchIDUnlock.Failure.cancelled {
                focused = true
            } catch {
                touchIDReady = false
                self.error = "Touch ID 已失效，请输入主密码（解锁后会重新登记）"
                focused = true
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty, !session.isWorking else { return }
        let attempt = password
        var secretKey: SecretKey?
        if needsSecretKey {
            guard let sk = try? SecretKey(text: secretKeyText) else {
                error = secretKeyText.isEmpty ? "请先输入 Secret Key" : "Secret Key 的写法不对，请检查有没有抄错"
                withAnimation(.default) { shakes += 1 }
                secretKeyFocused = true
                return
            }
            secretKey = sk
        }
        Task {
            do {
                try await session.unlock(password: attempt, secretKey: secretKey)
                password = ""
                secretKeyText = ""
            } catch let e as VaultError where e == .wrongSecretKey || e == .secretKeyRequired {
                error = e.userMessage
                withAnimation(.default) { shakes += 1 }
                secretKeyFocused = true
            } catch let e as VaultError {
                fail(e.userMessage)
            } catch {
                fail("无法读取保险库：\(error.localizedDescription)")
            }
        }
    }

    private func fail(_ message: String) {
        error = message
        password = ""
        withAnimation(.default) { shakes += 1 }
        focused = true
    }
}

/// 首次启动 → 新建账户：设置主密码，新建保险库。
struct CreateVaultView: View {
    @Environment(VaultSession.self) private var session
    var onBack: (() -> Void)? = nil
    @State private var password = ""
    @State private var confirm = ""
    @State private var understood = false
    @State private var error: String?
    private enum Field { case password, confirm }
    @FocusState private var focus: Field?

    private var strength: PasswordStrength { PasswordStrength.evaluate(password) }
    private var canCreate: Bool {
        !password.isEmpty && password == confirm && strength.level >= .fair && understood && !session.isWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            AppMark()
            Text("新建账户").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text).padding(.top, 20)
            Text("设置主密码，新建你的个人保险库").foregroundStyle(Theme.text2).padding(.top, 4)

            VStack(alignment: .leading, spacing: 10) {
                SecureField("主密码", text: $password)
                    .font(.system(size: 14))
                    .focused($focus, equals: .password)
                    .boxField(focused: focus == .password, height: 40, radius: 11)
                StrengthBar(strength: strength).opacity(password.isEmpty ? 0 : 1)
                SecureField("再输入一次", text: $confirm)
                    .font(.system(size: 14))
                    .focused($focus, equals: .confirm)
                    .boxField(focused: focus == .confirm, height: 40, radius: 11)
                    .onSubmit(create)
                if !confirm.isEmpty && confirm != password {
                    Text("两次输入不一致").font(.system(size: 12)).foregroundStyle(Theme.danger)
                } else if !password.isEmpty && strength.level < .fair {
                    Text("主密码太弱。建议用 4 个以上随机单词，或 14 位以上混合字符").font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
                Toggle(isOn: $understood) {
                    Text("我明白：主密码不会保存在任何地方，**忘记就无法找回**保险库里的数据")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                }
                .toggleStyle(.checkbox)
                .padding(.top, 4)
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                Button(action: create) {
                    if session.isWorking { ProgressView().controlSize(.small) } else { Text("新建保险库") }
                }
                .buttonStyle(CTAButtonStyle())
                .disabled(!canCreate)
                .padding(.top, 8)
            }
            .frame(width: 340)
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if let onBack { BackButton(action: onBack).padding(.top, 52).padding(.leading, 24) }
        }
        .onAppear { focus = .password }
    }

    private func create() {
        guard canCreate else { return }
        let pw = password
        Task {
            do {
                try await session.create(password: pw)
            } catch {
                self.error = "新建失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 输错密码时左右抖一下（设计稿 shake 动画）。
struct Shake: GeometryEffect {
    var animatableData: CGFloat

    init(count: Int) { animatableData = CGFloat(count) }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 4), y: 0))
    }
}

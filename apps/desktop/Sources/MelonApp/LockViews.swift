import MelonCore
import SwiftUI

/// 应用图标：蓝色圆角方块 + 锁（设计稿解锁页）。
struct AppMark: View {
    var size: CGFloat = 76

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(Theme.accent)
            .frame(width: size, height: size)
            .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 8)
            .overlay(Image(systemName: "lock.fill").font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
    }
}

/// 解锁页（设计稿「解锁页」）。Touch ID 下一个 PR 再接。
struct UnlockView: View {
    @Environment(VaultSession.self) private var session
    @State private var password = ""
    @State private var error: String?
    @State private var shakes = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            AppMark()
            Text("1Melon").font(.system(size: 20, weight: .semibold)).padding(.top, 18)
            Text("个人保险库已锁定").foregroundStyle(.secondary).padding(.top, 4)

            HStack(spacing: 6) {
                SecureField("输入主密码", text: $password)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(unlock)
                    .onChange(of: password) { error = nil }
                if session.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: unlock) {
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                    .foregroundStyle(.white)
                    .disabled(password.isEmpty)
                }
            }
            .padding(.leading, 12).padding(.trailing, 4)
            .frame(width: 280, height: 32)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(error == nil ? AnyShapeStyle(.separator) : AnyShapeStyle(Theme.danger), lineWidth: 0.5))
            .modifier(Shake(count: shakes))
            .padding(.top, 26)

            Text(error ?? " ").font(.system(size: 12)).foregroundStyle(Theme.danger).frame(height: 18).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !password.isEmpty, !session.isWorking else { return }
        let attempt = password
        Task {
            do {
                try await session.unlock(password: attempt)
                password = ""
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

/// 首次启动：设置主密码，新建保险库。
struct CreateVaultView: View {
    @Environment(VaultSession.self) private var session
    @State private var password = ""
    @State private var confirm = ""
    @State private var understood = false
    @State private var error: String?

    private var strength: PasswordStrength { PasswordStrength.evaluate(password) }
    private var canCreate: Bool {
        !password.isEmpty && password == confirm && strength.level >= .fair && understood && !session.isWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            AppMark(size: 64)
            Text("欢迎使用 1Melon").font(.system(size: 20, weight: .semibold)).padding(.top, 16)
            Text("设置主密码，新建你的个人保险库").foregroundStyle(.secondary).padding(.top, 4)

            VStack(alignment: .leading, spacing: 10) {
                SecureField("主密码", text: $password)
                SecureField("再输入一次", text: $confirm).onSubmit(create)
                StrengthBar(strength: strength).opacity(password.isEmpty ? 0 : 1)
                if !confirm.isEmpty && confirm != password {
                    Text("两次输入不一致").font(.system(size: 12)).foregroundStyle(Theme.danger)
                } else if !password.isEmpty && strength.level < .fair {
                    Text("主密码太弱。建议用 4 个以上随机单词，或 14 位以上混合字符").font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
                Toggle(isOn: $understood) {
                    Text("我明白：主密码不会保存在任何地方，**忘记就无法找回**保险库里的数据")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 4)
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 320)
            .padding(.top, 24)

            Button(action: create) {
                if session.isWorking { ProgressView().controlSize(.small) } else { Text("新建保险库") }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(!canCreate)
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

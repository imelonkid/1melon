import AppKit
import CoreImage.CIFilterBuiltins
import MelonCore
import SwiftUI

// 同步的界面：设置「同步」页、开启同步、设置码、首次启动「加入已有账户」（sync-api §4.1、§7）

/// 默认的同步服务端
let defaultSyncServer = "https://1melon.melonkid.cn"

// MARK: 设置「同步」页

struct SyncSettings: View {
    @Environment(VaultSession.self) private var session
    @State private var enabling = false
    @State private var showingCode = false
    @State private var confirmingOff = false

    var body: some View {
        // 同步状态存在文件里，界面靠 `session.sync` 的变化刷新
        let _ = session.sync
        Form {
            if let state = session.syncState {
                Section("同步") {
                    LabeledContent("服务端") {
                        Text(state.server).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    LabeledContent {
                        Button(session.sync.syncing ? "正在同步…" : "立即同步") { session.syncNow() }
                            .disabled(session.sync.syncing || session.syncClient == nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusLine)
                            if let problem = session.sync.problem {
                                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Hint("解锁后、每次保存后、每 5 分钟、切回 1Melon 时自动同步。服务端只保存加密后的文件，没有主密码和 Secret Key 解不开；两台设备都改过时按条目合并，同一条都改了会留一份「冲突副本」。")
                }
                Section("加入别的设备") {
                    LabeledContent("设置码") {
                        Button("显示设置码…") { showingCode = true }.disabled(session.setupCode == nil)
                    }
                    Hint(session.loaded == nil
                         ? "解锁后才能查看。"
                         : "新设备首次启动时选「加入已有账户」，粘贴设置码或扫二维码，再输主密码。设置码里有 Secret Key，和主密码一样要保密。")
                }
                Section {
                    LabeledContent("这台 Mac") {
                        Button("关闭同步…", role: .destructive) { confirmingOff = true }
                    }
                    Hint("只是这台 Mac 不再同步，云端和本机的数据都保留；以后可以用设置码重新加入。")
                }
            } else {
                Section("同步") {
                    LabeledContent("未开启") {
                        Button("开启同步…") { enabling = true }
                            .disabled(session.loaded?.account.secretKey == nil)
                    }
                    Hint(enableHint)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $enabling) { EnableSyncSheet() }
        .sheet(isPresented: $showingCode) { SetupCodeSheet() }
        .confirmationDialog("关闭这台 Mac 的同步？", isPresented: $confirmingOff) {
            Button("关闭同步", role: .destructive) { session.disableSync() }
        } message: {
            Text("云端和本机的数据都不会删除。")
        }
    }

    private var statusLine: String {
        if session.loaded == nil { return "解锁后自动同步" }
        if session.sync.syncing { return "正在同步…" }
        if let last = session.sync.lastSuccess { return "上次同步：\(last.formatted(date: .omitted, time: .shortened))" }
        return session.sync.problem == nil ? "等待同步" : "同步没有成功"
    }

    private var enableHint: String {
        if session.loaded == nil { return "解锁后才能开启。" }
        if session.loaded?.account.secretKey == nil { return "开启同步要先在「安全」里启用 Secret Key：这样就算云上的文件被人拿到，也没法暴力破解主密码。" }
        return "要管理员发的邀请码。开启后保险库会加密上传到同步服务端，其他设备用设置码和主密码加入。"
    }
}

/// 开启同步：服务端地址、邀请码，再输一次主密码
private struct EnableSyncSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var server = defaultSyncServer
    @State private var invite = ""
    @State private var password = ""
    @State private var error: String?

    private var canSubmit: Bool {
        !server.isEmpty && !invite.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !session.isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开启同步").font(.system(size: 15, weight: .semibold))
            Text("用管理员发的邀请码把这个账户注册到同步服务端。邀请码只能用一次。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("服务端地址", text: $server).font(.system(size: 12, design: .monospaced))
            TextField("邀请码", text: $invite).font(.system(size: 12, design: .monospaced))
            SecureField("主密码", text: $password).onSubmit(submit)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: submit) {
                    if session.isWorking { ProgressView().controlSize(.small) } else { Text("开启") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 420)
        .onChange(of: password) { error = nil }
        .onChange(of: invite) { error = nil }
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            do {
                try await session.enableSync(server: server, inviteCode: invite, password: password)
                dismiss()
            } catch {
                password = ""
                self.error = VaultSession.describe(error)
            }
        }
    }
}

/// 设置码：文字和二维码，默认遮住；复制走「自动清除剪贴板」
private struct SetupCodeSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置码").font(.system(size: 15, weight: .semibold))
            Text("在新设备上首次启动 1Melon，选「加入已有账户」，粘贴这段设置码，再输主密码。**设置码里有 Secret Key，和主密码一样要保密**：不要发到聊天软件或邮件里。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let code = session.setupCode?.text {
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if let image = qrImage(code) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 140, height: 140)
                        }
                    }
                    .blur(radius: revealed ? 0 : 8)
                    .overlay { if !revealed { Image(systemName: "eye.slash").font(.system(size: 22)).foregroundStyle(.secondary) } }
                    Text(revealed ? code : String(repeating: "•", count: 48))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(revealed ? "隐藏" : "显示") { revealed.toggle() }
                    Button("复制") { Clipboard.copySecret(code) }
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("解锁后才能查看。").foregroundStyle(.secondary)
                HStack { Spacer(); Button("完成") { dismiss() } }
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    /// 本机生成二维码（CoreImage），不经过任何网络服务
    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: 首次启动

/// 首次启动：新建账户，或者用设置码加入已有账户
struct FirstLaunchView: View {
    @State private var joining = false

    var body: some View {
        VStack(spacing: 0) {
            if joining { JoinAccountView() } else { CreateVaultView() }
            Button(joining ? "新建账户" : "已经在别的设备上用 1Melon？加入已有账户") { joining.toggle() }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .padding(.bottom, 24)
        }
    }
}

/// 加入已有账户：设置码 + 主密码 → 登录、下载账户文件和全部保险库
struct JoinAccountView: View {
    @Environment(VaultSession.self) private var session
    @State private var codeText = ""
    @State private var password = ""
    @State private var error: String?

    private var canJoin: Bool { !codeText.isEmpty && !password.isEmpty && !session.isWorking }

    var body: some View {
        VStack(spacing: 0) {
            AppMark(size: 64)
            Text("加入已有账户").font(.system(size: 20, weight: .semibold)).padding(.top, 16)
            Text("在已登录的设备上打开「设置 → 同步 → 显示设置码」").foregroundStyle(.secondary).padding(.top, 4)

            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $codeText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                    .overlay(alignment: .topLeading) {
                        if codeText.isEmpty {
                            Text("粘贴设置码（1MELON-SETUP1:…）").font(.system(size: 12)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                SecureField("主密码", text: $password).textFieldStyle(.roundedBorder).onSubmit(join)
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 320)
            .padding(.top, 24)
            .onChange(of: codeText) { error = nil }
            .onChange(of: password) { error = nil }

            Button(action: join) {
                if session.isWorking { ProgressView().controlSize(.small) } else { Text("加入") }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(!canJoin)
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func join() {
        guard canJoin else { return }
        let code: SetupCode
        do {
            code = try SetupCode(text: codeText)
        } catch let e as SetupCode.ParseError {
            error = switch e {
            case .malformed: "设置码不完整，请重新复制"
            case .invalidServer: "设置码里的服务端地址不对"
            case .invalidAccountId: "设置码里的账户 id 不对"
            case .invalidSecretKey: "设置码里的 Secret Key 校验不对，可能抄错了"
            }
            return
        } catch {
            return
        }
        let pw = password
        Task {
            do {
                try await session.join(setupCode: code, password: pw)
                codeText = ""
                password = ""
            } catch SyncAPIError.unauthorized {
                password = ""
                self.error = "主密码不对，或者设置码已经过时（别的设备换过 Secret Key）"
            } catch {
                self.error = VaultSession.describe(error)
            }
        }
    }
}

# 1Melon

自用的本地密码管理器：登录、银行卡、安全笔记、身份信息、SSH 密钥、API Token、Wi-Fi 七类条目，带密码生成器、TOTP 两步验证码和安全报告。保险库是本机的一个加密文件，不依赖任何云服务。

先做 macOS 桌面端；鸿蒙客户端已预留（同一个仓库、同一种保险库文件格式），暂不开发。

> 状态：设计阶段，还没有代码。UI 设计稿在 [`docs/ui/`](docs/ui/)（用浏览器打开 `Lockbox.dc.html`；稿里的产品名还叫 Lockbox，实现时统一改成 1Melon）。

## 目录

| 目录 | 内容 | 状态 |
|---|---|---|
| `spec/` | **跨端契约**：保险库文件格式（[`spec/vault-format.md`](spec/vault-format.md)）和测试向量。各端的加解密、TOTP 都必须通过同一份测试向量 | 草案 |
| `apps/desktop/` | macOS 客户端（Swift）：`Core/` 是不依赖界面的 Swift Package（保险库、加解密、TOTP、生成器、安全报告），`App/` 是 SwiftUI 界面与系统集成 | 待建 |
| `apps/harmony/` | 鸿蒙客户端（ArkTS） | 预留，暂不建 |
| `docs/ui/` | 桌面端 UI 设计稿 | 已有 |

## 技术选型例外

基线（v3）规定桌面端默认用 Electron + Vue 3。本项目桌面端改用**原生 Swift**：

- **用什么**：Swift 6 + SwiftUI，最低 macOS 14，先只做 arm64；加密用 CryptoKit（AES-256-GCM）和 libsodium（Argon2id），Touch ID 用 LocalAuthentication 和钥匙串。
- **为什么**：这是密码管理器。原生栈只依赖系统框架和 libsodium，没有 Chromium 和几百个 npm 包带来的供应链风险；能把解锁密钥绑定到 Secure Enclave 和生物识别；内存里的密钥能自己清零；设计稿本身就是 macOS 原生风格。
- **代价与对策**：PR 检查跑在 Linux 上，编译不了 SwiftUI。所以核心逻辑放在 `apps/desktop/Core`，它是纯 Swift Package，在 Linux 上 `swift test`（用 swift-crypto 替代 CryptoKit）；界面在发布流水线的 macOS 构建机上编译。打包按基线「桌面应用」的 `scripts/package-desktop.sh` 约定。
- **谁同意的**：melonkid，2026-10-25。

鸿蒙端按基线默认用 ArkTS，不算例外。

## 发布

各端独立打 tag、独立发布（基线「多端」）：

| 端 | tag | 渠道 |
|---|---|---|
| 桌面 | `desktop-vX.Y.Z` | 门户发布（melon-ci `desktop-release`）：从 tag 构建，安装包和 `latest.json` 传到对象存储 `<桶>/1melon/desktop/`，GitHub Release 存档 |
| 鸿蒙 | `harmony-vX.Y.Z` | 预留 |

发布流水线等有了能跑的版本再接。

## 安全说明

- 设计稿 `docs/ui/` 里的条目（账号、卡号、证件号、密钥）全部是**虚构的演示数据**，不是真实凭据。
- 真实的保险库文件（`*.1melon`）和任何密钥永远不进 git，见 `.gitignore`。

## 已知限制

- 没有 Apple 开发者签名，做不了静默自动更新；有新版时只提示下载。
- 暂不做多设备同步。保险库格式已经为以后的同步留好了位置（见 `spec/vault-format.md`「为同步预留」）。

# 1Melon

自用的本地密码管理器，给 melonkid 自己用，保险库是本机的一个加密文件。先做 macOS 桌面端（原生 Swift），鸿蒙客户端（ArkTS）已预留、暂不开发。

## 边界（强制）

Claude 在本项目里只做下面「负责」的事；越界的需求先停下来和用户确认，不要顺手改到别的项目里。

- **本项目负责**：
  - `spec/`：跨端契约，包括保险库文件格式和测试向量；
  - `apps/desktop/`：macOS 客户端，包括保险库的加解密与读写、条目增删改查、密码生成器、TOTP、安全报告、Touch ID 解锁、自动锁定、剪贴板自动清除、导入导出、本地自动备份；
  - `apps/harmony/`：鸿蒙客户端。**目前只预留**，用户说开工之前不建这个目录、不写鸿蒙代码。
- **本项目不负责**：
  - 云同步、多设备共享、账号体系、服务端：当前不做，要做先停下来确认（会引入服务端，项目类型就变了）。
  - 浏览器自动填充扩展：不在本仓库，要做先确认。
  - 发布流水线本体在 `imelonkid/melon-ci`，门户登记在运维仓库 `portal/config.json`，对象存储子账号和桶由用户本人在控制台建。
- **与其他项目的关系**：发布依赖 `imelonkid/melon-ci` 的 `desktop-release`（固定 `@v2`）；没有服务端，不依赖其他服务的接口，也不被别的项目依赖。

## 跨端约定（为鸿蒙预留，强制）

- **保险库文件格式以 `spec/vault-format.md` 为准**，它是各端之间唯一的契约。任何改动先改 spec、升格式版本、补测试向量，再改代码；不能只在某一端的代码里改格式。
- **各端代码不共享**（Swift 和 ArkTS 不同语言），靠同一份测试向量 `spec/test-vectors/` 对齐：加解密、密钥派生、TOTP、条目序列化，各端的测试都必须读这份向量并全部通过。
- **只用两端都能实现的原语**：Argon2id v1.3 用官方参考实现的 C 源码（`apps/desktop/Sources/CArgon2`，原样拷贝、不要改，鸿蒙可以用 NDK 编译同一份）；AES-256-GCM（CryptoKit 与鸿蒙 cryptoFramework 都有）；SHA-1/SHA-256 HMAC（TOTP 用）。引入新原语前先确认鸿蒙上能实现。
- **平台特有的东西不进保险库文件**：Touch ID 和钥匙串（macOS）、鸿蒙的生物识别与 HUKS 都只放在各端本地，不影响文件格式。
- 条目类型、字段名、标签这些数据模型定义在 spec 里，界面文案可以各端不同。

## 安全约束（密码管理器特有，强制）

- **主密码和明文条目永远不落盘、不写日志、不进崩溃报告**；保险库只以加密形式写文件，并且原子写入（先写临时文件再 rename）。
- 加密只用成熟的标准原语，不自己发明算法；KDF 参数写进文件头，以后能升级。
- 密钥和明文用完尽快清零（Swift 用自己管理的缓冲区，不要长期留在 `String` 里）。
- 不加载远程内容；图标等资源打包进应用，不从 CDN 拉。
- 不发起任何网络请求，唯一例外是读对象存储上的 `latest.json` 检查更新。
- 测试和示例只用虚构数据；`docs/ui/` 里的演示数据也都是假的。

## 桌面端（`apps/desktop/`）

- Swift 6 + SwiftUI，最低 macOS 14，arm64。属于技术选型例外，理由见 README。
- 一个 Swift Package（`apps/desktop/Package.swift`），两个模块：
- `Sources/MelonCore`：不 import SwiftUI/AppKit，加密统一 `import Crypto`（swift-crypto：Apple 平台上转发 CryptoKit，Linux 上用 BoringSSL），在 Linux 上能 `swift test`。业务逻辑尽量都放这里。
- `Sources/MelonApp`：SwiftUI 界面和系统集成（LocalAuthentication、钥匙串、菜单栏、全局快捷键、睡眠锁定、登录启动），只做界面和平台胶水。
- 本地数据（保险库、备份）只在 `~/Library/Application Support/1Melon/`，不在仓库里。
- 界面按 `docs/ui/Lockbox.dc.html` 实现，颜色取稿里的 CSS 变量（浅色和深色两套）。
- 稿里的 `totp()` 是假实现；真实现在 `MelonCore/TOTP.swift`，通过 `spec/test-vectors/totp.json`。
- 依赖钉版本：`Package.resolved` 进 git，加新依赖先确认它在 Linux 上能编译（CI 跑在 Linux 上）。
- 保险库代码在 `MelonCore/Vault.swift`（加解密、校验）和 `VaultStore.swift`（原子写入）。改格式相关的代码要同时过 `SpecVectorTests`，并用 `python3 spec/tools/verify-vectors.py` 交叉验证。
- 本机项目目录里的 `.build/build.db` 会间歇性报 `disk I/O error`（在 Claude 的命令沙箱里必现，沙箱外也偶尔出现，根因未查明）。Claude 跑 `swift build/test` 要加 `--scratch-path` 指到临时目录；验证打包时把 `git ls-files` 导出到临时目录再跑 `scripts/package-desktop.sh`。发布流水线在干净目录里构建，不受影响。
- 手动试界面时用 `MELON_VAULT_PATH` 指到临时文件，**不要碰用户真实的保险库**（`~/Library/Application Support/1Melon/`）。

## 运行

```bash
swift test --package-path apps/desktop                              # Core 单测
swift run --package-path apps/desktop MelonApp                      # 直接运行
scripts/package-desktop.sh 0.0.0 dev dist && open dist/1Melon.app   # 打成 .app
bash scripts/ci-test.sh                                             # 与 PR 检查相同
```

## 运维约定（melonkid 多云运维规范，原文在 `$OPS_REPO/docs/01-standard.md`）

- 类型：客户端应用，没有自己的服务端，不部署到服务器，不登记 `registry/services/`。
- 各端独立打 tag：桌面 `desktop-vX.Y.Z`，鸿蒙 `harmony-vX.Y.Z`；只在门户上点发布；版本号构建时注入（桌面写进 `Info.plist`：`CFBundleShortVersionString` = 版本号，`CFBundleVersion` = tag），源码里不写死版本号。
- 安装包与 `latest.json` 放对象存储 `<桶>/1melon/desktop/`；子账号只能写这个前缀，没有删除权限。
- PR 一律以 `main` 为目标，不开叠加 PR；提交信息 `<类型>(<范围>): <中文描述>`，范围用 `spec` / `desktop` / `harmony` / `docs`。

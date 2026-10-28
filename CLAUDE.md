# 1Melon

自用的密码管理器：保险库是本机的加密文件，可以经 1Melon 服务端在多台设备之间同步（服务端只见密文）。先做 macOS 桌面端（原生 Swift），鸿蒙客户端（ArkTS）已预留、暂不开发。

## 边界（强制）

Claude 在本项目里只做下面「负责」的事；越界的需求先停下来和用户确认，不要顺手改到别的项目里。

- **本项目负责**：
  - `spec/`：跨端契约，包括保险库文件格式和测试向量；
  - `apps/desktop/`：macOS 客户端，包括保险库的加解密与读写、条目增删改查、密码生成器、TOTP、安全报告、Touch ID 解锁、自动锁定、剪贴板自动清除、导入导出、本地自动备份；
  - `apps/server/`：同步服务端（Go + SQLite），协议见 `spec/sync-api.md`：邀请注册、设备登录、保存各账户上传的**密文**文件、「谁先写谁赢」、限流配额、管理命令行。**服务端永远不解密、不拿任何能解密的密钥**；
  - `apps/harmony/`：鸿蒙客户端。**目前只预留**，用户说开工之前不建这个目录、不写鸿蒙代码。
- **本项目不负责**：
  - 多人共享保险库（一个保险库给几个账户共用）：当前不做，要做先停下来确认。账户之间只做隔离，各管各的。
  - 自助注册、找回主密码：不做。只能凭管理员发的邀请码注册；主密码或 Secret Key 丢了，数据就找不回来，这是设计上的取舍。
  - 浏览器自动填充扩展：不在本仓库，要做先确认。
  - 发布流水线本体在 `imelonkid/melon-ci`，门户登记在运维仓库 `portal/config.json`，对象存储子账号和桶由用户本人在控制台建。
- **与其他项目的关系**：发布依赖 `imelonkid/melon-ci` 的 `desktop-release` 和 `server-release`（固定 `@v2`）；服务端部署在 tx 站，由运维仓库登记和监控；不依赖其他服务的接口，也不被别的项目依赖。

## 跨端约定（为鸿蒙预留，强制）

- **保险库文件格式以 `spec/vault-format.md` 为准**，它是各端之间唯一的契约。任何改动先改 spec、升格式版本、补测试向量，再改代码；不能只在某一端的代码里改格式。
- **各端代码不共享**（Swift 和 ArkTS 不同语言），靠同一份测试向量 `spec/test-vectors/` 对齐：加解密、密钥派生、TOTP、条目序列化，各端的测试都必须读这份向量并全部通过。
- **只用两端都能实现的原语**：Argon2id v1.3 用官方参考实现的 C 源码（`apps/desktop/Sources/CArgon2`，原样拷贝、不要改，鸿蒙可以用 NDK 编译同一份）；AES-256-GCM（CryptoKit 与鸿蒙 cryptoFramework 都有）；SHA-1/SHA-256 HMAC（TOTP 用）；HKDF-SHA256；Ed25519（同步登录签名，鸿蒙 cryptoFramework 有）。引入新原语前先确认鸿蒙上能实现。
- **平台特有的东西不进保险库文件**：Touch ID 和钥匙串（macOS）、鸿蒙的生物识别与 HUKS 都只放在各端本地，不影响文件格式。
- 条目类型、字段名、标签这些数据模型定义在 spec 里，界面文案可以各端不同。

## 安全约束（密码管理器特有，强制）

- **主密码和明文条目永远不落盘、不写日志、不进崩溃报告**；保险库只以加密形式写文件，并且原子写入（先写临时文件再 rename）。
- 加密只用成熟的标准原语，不自己发明算法；KDF 参数写进文件头，以后能升级。
- 密钥和明文用完尽快清零（Swift 用自己管理的缓冲区，不要长期留在 `String` 里）。
- 不加载远程内容；图标等资源打包进应用，不从 CDN 拉。
- 网络请求只有三种，别的一律不发：
  - 读对象存储上的 `latest.json` 检查更新；
  - 和 1Melon 服务端同步（地址来自设置码，`spec/sync-api.md`）：只传加密后的文件和登录签名，不传主密码、Secret Key、明文；
  - 取网站图标（`MelonCore/WebsiteIcon.swift`，设置里可关，默认开）：只在保存条目、网址的主机变了时，直接向**该网站本身**请求，绝不用第三方图标服务；IP、localhost、`.local` 等内网地址不请求；只走 https、不带 cookie、不用缓存、有大小上限和超时，重定向也要过同样的检查；取回后重画成 64×64 PNG 再存。改这里的规则先和用户确认。
- 测试和示例只用虚构数据；`docs/ui/` 里的演示数据也都是假的。
- 服务端日志不记请求体、令牌和文件内容（都是密文也不记），只记方法、路径、状态、耗时和账户 id。

## 桌面端（`apps/desktop/`）

- Swift 6 + SwiftUI，最低 macOS 14，arm64。属于技术选型例外，理由见 README。
- 一个 Swift Package（`apps/desktop/Package.swift`），两个模块：
- `Sources/MelonCore`：不 import SwiftUI/AppKit，加密统一 `import Crypto`（swift-crypto：Apple 平台上转发 CryptoKit，Linux 上用 BoringSSL），在 Linux 上能 `swift test`。业务逻辑尽量都放这里。
- `Sources/MelonApp`：SwiftUI 界面和系统集成（Touch ID、菜单栏、全局快捷键、睡眠锁定、登录启动），只做界面和平台胶水。
- Touch ID 解锁（`MelonApp/TouchIDUnlock.swift` + `MelonCore/LocalUnlock.swift`）把账户密钥（开着同步时连同步登录密钥的种子）存进**数据保护钥匙串**：条目要求每次读都过 Touch ID、只在这台设备，访问组 `<TeamID>.cn.melonkid.1melon` 让别的程序读不到。这要求正式签名：Apple 开发者证书 + 带钥匙串访问组的描述文件（`scripts/package-desktop.sh` 的 `SIGN_IDENTITY`、`PROVISIONING_PROFILE`）。ad-hoc 签名和 `swift run` 的包没有钥匙串权限，不提供 Touch ID，只能输主密码。`device/`（Secret Key、同步状态）只属于这台设备，不同步、不备份。
- 签名：本机自测用 Apple Development 证书（描述文件由 Xcode 生成）；正式发布用 Developer ID Application 证书和 Developer ID 描述文件（有效期到 2044 年），由发布流水线签名并公证（melon-ci `desktop-release` 的 `sign: true`：流水线导入证书、经 `SIGN_IDENTITY` / `PROVISIONING_PROFILE` 交给打包脚本，签 dmg、公证、钉票据都在流水线里；`latest.json` 的 sha256 在 publish 时算）。本机有多张「Apple Development」证书时 `SIGN_IDENTITY` 要写全名，否则 codesign 报不明确。证书、描述文件、公证密钥都由用户本人处理，Claude 不经手。
- 本地数据只在 `~/Library/Application Support/1Melon/`，不在仓库里。自动备份（`MelonCore/Backup.swift`）只复制加密文件，默认放在其中的 `backups/`，用户可在设置里换到别的文件夹；导出的明文 CSV 只写到用户在保存面板里选的位置。
- 界面按 `docs/ui/Lockbox.dc.html` 实现，颜色取稿里的 CSS 变量（浅色和深色两套）。
- 稿里的 `totp()` 是假实现；真实现在 `MelonCore/TOTP.swift`，通过 `spec/test-vectors/totp.json`。
- 依赖钉版本：`Package.resolved` 进 git，加新依赖先确认它在 Linux 上能编译（CI 跑在 Linux 上）。
- 数据层在 `MelonCore`：`Account.swift`（账户文件、主密码 → AK）、`Vault.swift`（保险库文件、加解密、校验、搬移）、`VaultItem.swift`（条目 / 分组 / 字段）、`ItemTemplates.swift`（类型模板，与 spec 附录 A 一致）、`VaultRepository.swift`（数据目录）、`VaultStore.swift`（原子写入）。改格式相关的代码要同时过 `SpecVectorTests`，并用 `python3 spec/tools/verify-vectors.py` 交叉验证。
- 本机项目目录里的 `.build/build.db` 会间歇性报 `disk I/O error`（在 Claude 的命令沙箱里必现，沙箱外也偶尔出现，根因未查明）。Claude 跑 `swift build/test` 要加 `--scratch-path` 指到临时目录；验证打包时把 `git ls-files` 导出到临时目录再跑 `scripts/package-desktop.sh`。发布流水线在干净目录里构建，不受影响。
- 手动试界面时用 `MELON_DATA_DIR` 指到临时目录，**不要碰用户真实的数据**（`~/Library/Application Support/1Melon/`）。

## 服务端（`apps/server/`）

- Go（单个静态二进制）+ SQLite（WAL），技术选型例外，理由见 README。纯 Go 的 SQLite 驱动 `modernc.org/sqlite`，不用 cgo；依赖钉在 `go.sum`，加新依赖先确认必要。
- 结构：`cmd/1melon-server`（入口和管理命令行）、`internal/config`（环境变量）、`internal/logging`（一行一条 JSON）、`internal/store`（SQLite 与迁移）、`internal/httpapi`（接口）。
- 接口只按 `spec/sync-api.md` 实现；改接口先改 spec。数据库迁移只增不改，保证回滚到上一个 tag 还能跑。
- 镜像 `deploy/Dockerfile`（构建上下文是仓库根目录），线上 compose `deploy/docker-compose.prod.yml`，配置 `.env.example`；端口 8790，只绑 127.0.0.1。
- 本机 Docker 拉 Docker Hub 的基础镜像会超时，镜像构建以 CI 的「镜像构建」检查为准。

## 运行

```bash
swift test --package-path apps/desktop                              # Core 单测
swift run --package-path apps/desktop MelonApp                      # 直接运行
scripts/package-desktop.sh 0.0.0 dev dist && open dist/1Melon.app   # 打成 .app（ad-hoc 签名，没有 Touch ID）
SIGN_IDENTITY="Apple Development: <证书名>" scripts/package-desktop.sh 0.0.0 dev dist   # 用开发证书签（有 Touch ID）；security find-identity -v -p codesigning 看证书名
(cd apps/server && go test ./...)                                   # 服务端单测
(cd apps/server && DATA_DIR=/tmp/1melon-server APP_VERSION=dev go run ./cmd/1melon-server)   # 本机起服务端，curl localhost:8790/health
bash scripts/ci-test.sh                                             # 与 PR 检查相同
```

## 运维约定（melonkid 多云运维规范，原文在 `$OPS_REPO/docs/01-standard.md`）

- 类型：**多端项目**（服务端 + 桌面端，鸿蒙预留）。服务端登记在运维仓库 `registry/services/1melon.yaml`：T0 / L2，主站点 tx，备 jd，裁判 ali；SQLite 用 Litestream 持续复制到异云。
- 各端独立打 tag：服务端 `server-vX.Y.Z`（门户「发布」，melon-ci `server-release`，`/health` 的 `version` = tag 才算上线），桌面 `desktop-vX.Y.Z`，鸿蒙 `harmony-vX.Y.Z`；只在门户上点发布；版本号构建时注入（桌面写进 `Info.plist`：`CFBundleShortVersionString` = 版本号，`CFBundleVersion` = tag），源码里不写死版本号。
- 安装包与 `latest.json` 放对象存储 `<桶>/1melon/desktop/`；子账号只能写这个前缀，没有删除权限。
- PR 一律以 `main` 为目标，不开叠加 PR；提交信息 `<类型>(<范围>): <中文描述>`，范围用 `spec` / `server` / `desktop` / `harmony` / `docs`。

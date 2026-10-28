# 1Melon

自用的本地密码管理器：登录、银行卡、安全笔记、身份信息、SSH 密钥、API Token、Wi-Fi 七类条目，带密码生成器、TOTP 两步验证码和安全报告。保险库是本机的一个加密文件，不依赖任何云服务。

先做 macOS 桌面端；鸿蒙客户端已预留（同一个仓库、同一种保险库文件格式），暂不开发。

> 状态：桌面端开发中。已能用：首次设置主密码、解锁、闲置 5 分钟或睡眠锁屏时自动锁定；多个保险库（新建、改名换图标、删除空保险库、条目在保险库之间搬移）；三栏主界面（按保险库浏览、按类型筛选、搜索）；在第三栏直接新建和编辑条目，分组和字段可增删、改名、拖动排序；TOTP 验证码、密码生成器（随机、易记、PIN）、网站图标（可在设置里关闭）、Touch ID 解锁、检查更新、Secret Key（设置 → 安全，为云同步准备）。设置（⌘,）：登录时启动、自动锁定时间、剪贴板清除时间、睡眠锁屏时锁定、多久要求输一次主密码、修改主密码、外观。安全报告：弱密码、重复使用、未开启两步验证、长期未更新，只在本机计算。导入（文件 → 导入…，⇧⌘I）：1Password（.1pux）、Bitwarden（未加密的 .json）、浏览器导出的密码 CSV，导入前可预览，已有的相同条目会跳过。导出（文件 → 导出…）：明文 CSV，要再输一次主密码。自动备份（设置 → 数据）：定时把加密文件原样复制一份，内容没变不重复备份，保留最新 N 份，位置可改。UI 设计稿在 [`docs/ui/`](docs/ui/)（用浏览器打开 `Lockbox.dc.html`；稿里的产品名还叫 Lockbox，实现时统一改成 1Melon）。

## 目录

| 目录 | 内容 | 状态 |
|---|---|---|
| `spec/` | **跨端契约**：保险库文件格式（[`spec/vault-format.md`](spec/vault-format.md)）和测试向量。各端的加解密、TOTP 都必须通过同一份测试向量 | 草案 |
| `apps/desktop/` | macOS 客户端（Swift Package）：`Sources/MelonCore` 是不依赖界面的核心逻辑（保险库、加解密、TOTP、生成器、安全报告），Linux 上也能测；`Sources/MelonApp` 是 SwiftUI 界面与系统集成，只在 macOS 上编译 | 骨架 |
| `apps/server/` | 同步服务端（Go + SQLite）：只保存各账户上传的密文，协议见 [`spec/sync-api.md`](spec/sync-api.md) | 接口已实现，未上线；桌面端还没接 |
| `apps/harmony/` | 鸿蒙客户端（ArkTS） | 预留，暂不建 |
| `docs/ui/` | 桌面端 UI 设计稿 | 已有 |

## 技术选型例外

基线（v3）规定桌面端默认用 Electron + Vue 3。本项目桌面端改用**原生 Swift**：

- **用什么**：Swift 6 + SwiftUI，最低 macOS 14，先只做 arm64；加密用 CryptoKit（AES-256-GCM）和 Argon2id 官方参考实现（C 源码直接放在仓库里，CC0 许可），Touch ID 用 LocalAuthentication 和数据保护钥匙串（要 Apple 开发者证书签名，见下文「签名」）。
- **为什么**：这是密码管理器。原生栈只依赖系统框架、swift-crypto 和一份可以审计的 Argon2 C 源码，没有 Chromium 和几百个 npm 包带来的供应链风险；能把解锁密钥绑定到 Secure Enclave 和生物识别；内存里的密钥能自己清零；设计稿本身就是 macOS 原生风格。
- **第三方数据**：易记密码用的词表是 [EFF 长词表](https://www.eff.org/dice)（7776 个词，CC BY 3.0，作者 Electronic Frontier Foundation），原样内置在 `MelonCore/EFFWordlist.swift`，测试校验它和原文件的 SHA-256 一致。
- **代价与对策**：PR 检查跑在 Linux 上，编译不了 SwiftUI。所以核心逻辑放在 `MelonCore`，它不依赖界面，在 Linux 上 `swift test`（用 swift-crypto 替代 CryptoKit）；界面在发布流水线的 macOS 构建机上编译。打包按基线「桌面应用」的 `scripts/package-desktop.sh` 约定。
- **谁同意的**：melonkid，2026-10-25。

鸿蒙端按基线默认用 ArkTS，不算例外。

**服务端**：基线默认是 NestJS + Prisma + MySQL 8 + Redis 7。本项目服务端改用 **Go + SQLite（WAL）+ Litestream**：

- **用什么**：Go 标准库（`net/http`、`log/slog`、Ed25519）+ 纯 Go 的 SQLite 驱动 `modernc.org/sqlite`，编译成一个静态二进制；数据是一个 SQLite 文件，Litestream 持续复制到另一朵云的对象存储；不用 Redis（单实例，限流计数放进程内存，登录挑战自带签名不用存）。
- **为什么**：服务端只做「邀请注册、设备登录、按账户存取密文、谁先写谁赢」，数据量极小（每个账户几 MB），全是单机读写。一个容器常驻约 20–30 MB 内存，基线方案是三个容器约 600 MB（tx-1 是 2C / 3.6G）；密码管理器的服务端依赖越少越好，Go 标准库几乎够用，没有几百个 npm 包。
- **代价与对策**：仓库里多一种语言（服务端代码预计一两千行）；不用 MySQL，备份链路按 SQLite + Litestream 写注册表（同 mchat）；部署、健康检查、日志格式、发布流水线照基线来，和语言无关。
- **密文存在 SQLite 里，不放对象存储**：基线规定「用户上传的文件一律放对象存储，不存 `./data/`」，那是为头像、图片这类媒体定的。这里上传的是保险库密文：每个账户几 MB，全部加起来几十 MB；放在同一个库里，「谁先写谁赢」一个事务就能做到，灾备也只有一条 Litestream 链路，恢复到任意时间点都一致。拆成「对象存储放内容、库里只放记录」要两步提交、清理孤儿对象、库和桶分别跨云复制并对齐恢复时间点，在这个规模下得不偿失。
  - **满足任意一条再拆**：库超过 1 GB；单个保险库文件经常超过 10 MB；要保留每个文件的历史版本；要让客户端用预签名地址直传，不经过服务端。文件读写都在 `apps/server/internal/store/files.go`，拆的时候接口和客户端都不用变。
  - 文件变大时先考虑缩小同步的单位：网站图标单独存，或者改成按条目同步。每次保存都要重传整个保险库文件，这比存在哪更影响流量。
- **谁同意的**：melonkid，2026-10-27。

## 本地运行

要 Xcode 16 或更高版本（Swift 6）。也可以直接用 Xcode 打开 `apps/desktop/Package.swift`。

```bash
swift test --package-path apps/desktop                                # Core 单测（含 spec/test-vectors）
swift run --package-path apps/desktop MelonApp                        # 直接运行（不打包），用的是真实数据
MELON_DATA_DIR=/tmp/1melon-test swift run --package-path apps/desktop MelonApp    # 用临时数据目录试，不碰真实数据
scripts/package-desktop.sh 0.0.0 dev dist && open dist/1Melon.app     # 打成 .app 运行（ad-hoc 签名，没有 Touch ID）
SIGN_IDENTITY="Apple Development: <证书名>" scripts/package-desktop.sh 0.0.0 dev dist   # 用开发证书签，有 Touch ID
(cd apps/server && go test ./...)                                     # 服务端单测
(cd apps/server && BIND_ADDR=127.0.0.1 DATA_DIR=/tmp/1melon-server APP_VERSION=dev go run ./cmd/1melon-server)   # 本机起服务端，只监听 127.0.0.1：curl localhost:8790/health
bash scripts/ci-test.sh                                               # 和 PR 检查跑同一套
```

本机项目目录里的 `apps/desktop/.build` 偶尔会报 `disk I/O error`，这时 SwiftPM 会跳过重新编译、跑旧版本。遇到时把编译目录指到项目外：

```bash
MELON_DATA_DIR=/tmp/1melon-test swift run --package-path apps/desktop --scratch-path /tmp/1melon-build MelonApp
```

真实数据在 `~/Library/Application Support/1Melon/`：`account.1melon`（账户）和 `vaults/*.1melon`（每个保险库一个文件），格式见 [`spec/vault-format.md`](spec/vault-format.md)。

## 发布

各端独立打 tag、独立发布（基线「多端」）：

| 端 | tag | 渠道 |
|---|---|---|
| 服务端 | `server-vX.Y.Z` | 门户发布（melon-ci `server-release`，表单 `.github/workflows/release.yml`）：从 tag 构建镜像 → 推镜像仓库 → tx-1 部署入口上线 → `/health` 版本 = tag 且健康才算完成，不过自动切回；回滚 `rollback.yml`，秒级。**还没上线**，上线清单见运维仓库注册表 |
| 桌面 | `desktop-vX.Y.Z` | 门户发布（melon-ci `desktop-release`）：从 tag 构建，安装包和 `latest.json` 传到对象存储 `<桶>/1melon/desktop/`，GitHub Release 存档 |
| 鸿蒙 | `harmony-vX.Y.Z` | 预留 |

桌面端发布：门户上点「发布」（兜底：GitHub Actions →「发布」，即 `.github/workflows/release-desktop.yml`）。流水线依次是门禁（08–23 点、main 的 CI 全绿）、打 tag、macOS 构建机上 `scripts/release-desktop.sh build`（内部调 `scripts/package-desktop.sh`）、上传对象存储（先传安装包，最后传 `latest.json`）、建 GitHub Release。

装到电脑上的版本收不回来，所以没有「回滚」：新版有问题就修好后发 patch。

## GitHub production 环境

发布流水线只在 production 环境里拿得到下面这些值（环境只允许 `main`）。GitHub 上的变量和 Secret 没有备注，**用途和对应关系只记在这里**：增删改任何一项都同步改这张表。

| 名字 | 类型 | 值 / 用途 | 对应运维侧 | 谁写入 | 状态 |
|---|---|---|---|---|---|
| `OSS_BUCKET` | 变量 | `melon-download`（下载站桶，北京） | 运维仓库 `registry/sites.yaml` 的 `downloads` | 接入时配置 | 已配（2026-10-26） |
| `OSS_ENDPOINT` | 变量 | `oss-cn-beijing.aliyuncs.com` | 同上 | 接入时配置 | 已配（2026-10-26） |
| `OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET` | Secret | RAM 子账号 `oss-1melon`：只能写 `1melon/desktop/*`，没有删除权限；值存 1Password `ops/1melon/prod` | 运维仓库 `docs/10-env.md` 的 1melon 一节 | 用户本人 | 已配（2026-10-26） |
| `MACOS_CERT_P12_BASE64`、`MACOS_CERT_P12_PASSWORD` | Secret | Developer ID Application 证书连私钥导出的 p12（base64）和导出密码；p12 和密码存 1Password | 同一张证书能签同一开发者账号下的所有 Mac 应用 | 用户本人 | 已配（2026-10-28） |
| `MACOS_PROVISION_PROFILE_BASE64` | Secret | Developer ID 描述文件「1Melon Developer ID」（base64）：App ID `cn.melonkid.1melon`，带钥匙串访问组，有效期到 2044 年 | 只属于 1Melon | 用户本人 | 已配（2026-10-28） |
| `NOTARY_KEY_P8_BASE64`、`NOTARY_KEY_ID`、`NOTARY_ISSUER_ID` | Secret | App Store Connect API 密钥（公证用）：p8（base64）、Key ID、Issuer ID；p8 存 1Password | 团队共用 | 用户本人 | 已配（2026-10-28） |

对象存储侧：`oss-1melon` 的 RAM 自定义策略只给 `PutObject`；桶的「Bucket 授权策略」给匿名用户 `1melon/desktop/*` 的只读（不含列举）。`bash scripts/release-desktop.sh oss-test` 已验证能上传、公网能读。客户端从 `https://melon-download.oss-cn-beijing.aliyuncs.com/1melon/desktop/latest.json` 检查更新（`apps/desktop/Sources/MelonApp/Updater.swift`）。

查看：仓库 Settings → Environments → production，或 `gh variable list --env production` / `gh secret list --env production`（只有名字）。

## 签名

桌面端的 Touch ID 解锁把账户密钥存在数据保护钥匙串里，要正式签名才能用：Apple 开发者证书，加上一份带钥匙串访问组的描述文件（App ID `cn.melonkid.1melon`）。`scripts/package-desktop.sh` 从环境变量读：

| 变量 | 不设时 | 说明 |
|---|---|---|
| `SIGN_IDENTITY` | ad-hoc 签名，没有 Touch ID | 本机自测 `Apple Development: …`；正式发布 `Developer ID Application: …`（带苹果时间戳）。有多张同类证书时写全名，`security find-identity -v -p codesigning` 查看 |
| `PROVISIONING_PROFILE` | 在 Xcode 的描述文件目录里按 bundle id 找没过期的 | 放进 `Contents/embedded.provisionprofile`；Team ID 从这里读，不写在仓库里 |

- **本机自测**：Xcode → Settings → Apple Accounts 登录，生成 Apple Development 证书；建一个 bundle id 为 `cn.melonkid.1melon` 的空 macOS App 工程，⌘B 一次，Xcode 就生成开发用的描述文件。
- **正式发布**：Apple Developer Program（个人，2026-10-28 开通）。Developer ID Application 证书在 Xcode 里生成；Developer ID 描述文件在开发者网站「描述文件」里生成（App ID `cn.melonkid.1melon`，有效期到 2044 年，适用所有 Mac）。本机已用它们签过包并验证（签名链、时间戳、权限声明，系统能启动）。
- **公证**：发布表单开了 melon-ci `desktop-release` 的 `sign: true`：流水线把证书导入临时钥匙串，经 `SIGN_IDENTITY` / `PROVISIONING_PROFILE` 交给 `scripts/package-desktop.sh` 签 .app，再签 dmg、提交公证、钉上公证票据。证书、描述文件和公证密钥在 production 环境（见上表）。因为 dmg 在 build 之后还会变，`latest.json` 的 sha256 在 publish 时才算。

## 安全说明

- 设计稿 `docs/ui/` 里的条目（账号、卡号、证件号、密钥）全部是**虚构的演示数据**，不是真实凭据。
- 真实的保险库文件（`*.1melon`）和任何密钥永远不进 git，见 `.gitignore`。

## 已知限制

- 正式签名和公证要等 melon-ci `desktop-release` 的 `sign` 合并、第一次发布才算验证过；在那之前发出去的安装包是 ad-hoc 签名（没有 Touch ID，首次打开要在「隐私与安全性」里放行）。
- 还做不了静默自动更新：有新版时只提示下载。
- 多设备同步：协议见 `spec/sync-api.md`，服务端和桌面端都已实现，服务端还没上线。

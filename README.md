# 1Melon

自用的本地密码管理器：登录、银行卡、安全笔记、身份信息、SSH 密钥、API Token、Wi-Fi 七类条目，带密码生成器、TOTP 两步验证码和安全报告。保险库是本机的一个加密文件，不依赖任何云服务。

先做 macOS 桌面端；鸿蒙客户端已预留（同一个仓库、同一种保险库文件格式），暂不开发。

> 状态：桌面端开发中。已能用：首次设置主密码、解锁、闲置 5 分钟或睡眠锁屏时自动锁定；多个保险库（新建、改名换色、删除空保险库、条目在保险库之间搬移）；三栏主界面（按保险库浏览、按类型筛选、搜索）；在第三栏直接新建和编辑条目，分组和字段可增删、改名、拖动排序；TOTP 验证码、密码生成器、网站图标（可在设置里关闭）、Touch ID 解锁、检查更新。设置（⌘,）：登录时启动、自动锁定时间、剪贴板清除时间、睡眠锁屏时锁定、多久要求输一次主密码、修改主密码、外观。还没做：安全报告、导入导出、自动备份。UI 设计稿在 [`docs/ui/`](docs/ui/)（用浏览器打开 `Lockbox.dc.html`；稿里的产品名还叫 Lockbox，实现时统一改成 1Melon）。

## 目录

| 目录 | 内容 | 状态 |
|---|---|---|
| `spec/` | **跨端契约**：保险库文件格式（[`spec/vault-format.md`](spec/vault-format.md)）和测试向量。各端的加解密、TOTP 都必须通过同一份测试向量 | 草案 |
| `apps/desktop/` | macOS 客户端（Swift Package）：`Sources/MelonCore` 是不依赖界面的核心逻辑（保险库、加解密、TOTP、生成器、安全报告），Linux 上也能测；`Sources/MelonApp` 是 SwiftUI 界面与系统集成，只在 macOS 上编译 | 骨架 |
| `apps/harmony/` | 鸿蒙客户端（ArkTS） | 预留，暂不建 |
| `docs/ui/` | 桌面端 UI 设计稿 | 已有 |

## 技术选型例外

基线（v3）规定桌面端默认用 Electron + Vue 3。本项目桌面端改用**原生 Swift**：

- **用什么**：Swift 6 + SwiftUI，最低 macOS 14，先只做 arm64；加密用 CryptoKit（AES-256-GCM）和 Argon2id 官方参考实现（C 源码直接放在仓库里，CC0 许可），Touch ID 用 LocalAuthentication 和钥匙串。
- **为什么**：这是密码管理器。原生栈只依赖系统框架、swift-crypto 和一份可以审计的 Argon2 C 源码，没有 Chromium 和几百个 npm 包带来的供应链风险；能把解锁密钥绑定到 Secure Enclave 和生物识别；内存里的密钥能自己清零；设计稿本身就是 macOS 原生风格。
- **代价与对策**：PR 检查跑在 Linux 上，编译不了 SwiftUI。所以核心逻辑放在 `MelonCore`，它不依赖界面，在 Linux 上 `swift test`（用 swift-crypto 替代 CryptoKit）；界面在发布流水线的 macOS 构建机上编译。打包按基线「桌面应用」的 `scripts/package-desktop.sh` 约定。
- **谁同意的**：melonkid，2026-10-25。

鸿蒙端按基线默认用 ArkTS，不算例外。

## 本地运行

要 Xcode 16 或更高版本（Swift 6）。也可以直接用 Xcode 打开 `apps/desktop/Package.swift`。

```bash
swift test --package-path apps/desktop                                # Core 单测（含 spec/test-vectors）
swift run --package-path apps/desktop MelonApp                        # 直接运行（不打包），用的是真实数据
MELON_DATA_DIR=/tmp/1melon-test swift run --package-path apps/desktop MelonApp    # 用临时数据目录试，不碰真实数据
scripts/package-desktop.sh 0.0.0 dev dist && open dist/1Melon.app     # 打成 .app 运行
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

对象存储侧：`oss-1melon` 的 RAM 自定义策略只给 `PutObject`；桶的「Bucket 授权策略」给匿名用户 `1melon/desktop/*` 的只读（不含列举）。`bash scripts/release-desktop.sh oss-test` 已验证能上传、公网能读。客户端从 `https://melon-download.oss-cn-beijing.aliyuncs.com/1melon/desktop/latest.json` 检查更新（`apps/desktop/Sources/MelonApp/Updater.swift`）。

查看：仓库 Settings → Environments → production，或 `gh variable list --env production` / `gh secret list --env production`（只有名字）。

## 安全说明

- 设计稿 `docs/ui/` 里的条目（账号、卡号、证件号、密钥）全部是**虚构的演示数据**，不是真实凭据。
- 真实的保险库文件（`*.1melon`）和任何密钥永远不进 git，见 `.gitignore`。

## 已知限制

- 没有 Apple 开发者签名，做不了静默自动更新；有新版时只提示下载。
- 暂不做多设备同步。方向是把加密后的文件同步到阿里云 OSS，格式已经留好了位置（见 `spec/vault-format.md` §8）。

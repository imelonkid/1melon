# 自动填充调研（macOS 桌面端）

> 状态：**调研结论，待拍板**。2026-10-28。只调研，没有写功能代码，没有建 App ID、描述文件，没有改 melon-ci。
> 标「已核实」的出自 Apple / 华为 / OpenHarmony 官方文档；标「待实测」的只有第三方资料或推断，动手前要在本机验证。

## 0. 结论和推荐

**推荐：做系统级凭据提供者（AutoFill Credential Provider 扩展），分阶段做；暂不做浏览器扩展。**

- **能覆盖的**：Safari 和用系统控件的原生应用里的**密码**（macOS 11+）、**一次性验证码**（macOS 15+）、**通行密钥**（macOS 14+）。Chrome、Firefox 里的**通行密钥**多半也能走系统面板（待实测）。
- **覆盖不到的**：Chrome、Firefox 里的**密码**。它们用自己的密码管理器，不走 macOS 的 AutoFill；我没找到它们接系统凭据提供者的官方说明。这部分先靠现有的「复制 + 30 秒自动清除」兜底，以后真要做再单独评估浏览器扩展（§4）。
- **代价**：
  1. **打包**：SwiftPM 产不出 `.appex`。推荐继续用 SwiftPM 编出扩展的可执行文件，再由 `scripts/package-desktop.sh` 手工组装进 `Contents/PlugIns/`，不引入 Xcode 工程。可行性要先在阶段 0 验证。
  2. **签名**：新建一个扩展 App ID，两个 App ID 都开 AutoFill Credential Provider；主应用的描述文件要重新生成，扩展另要一份。melon-ci `desktop-release` 现在只接一份描述文件，要改成能接两份。
  3. **数据位置**：扩展必须开沙盒，读不到 `~/Library/Application Support/1Melon/`。推荐把数据目录迁到 App Group 容器 `~/Library/Group Containers/793RBBSGZN.cn.melonkid.1melon.shared/`。
  4. **解锁**：扩展自己解锁，不依赖主应用。先用 Touch ID 读同一个钥匙串条目，读不到就输主密码。钥匙串访问组沿用 `793RBBSGZN.cn.melonkid.1melon`。
- **要你拍板的**：
  1. 做不做、做到哪个阶段（§6）；
  2. 数据目录迁到 App Group 还是用沙盒临时例外（§2.3）；
  3. 要不要把「网站 + 用户名」写进系统的凭据身份库（§3.3）。写进去，下拉框里就直接有建议，但这些元数据会以明文留在系统那里；
  4. 项目边界：系统凭据提供者是 `apps/desktop/` 里的一个扩展，不是 CLAUDE.md 里说的「浏览器自动填充扩展」。我的理解是它在边界之内，但它会改数据目录和签名，算一次较大的改动，请确认后再把 CLAUDE.md 的「本项目负责」补上一条。

## 1. 系统级凭据提供者能填什么

### 1.1 API 与系统版本（已核实）

出处：[ASCredentialProviderViewController](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller)、[prepareOneTimeCodeCredentialList(for:)](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller/prepareonetimecodecredentiallist(for:))、[AutoFill Credential Provider Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.authentication-services.autofill-credential-provider)、[Apple 平台安全指南：凭据提供者扩展](https://support.apple.com/guide/security/credential-provider-extensions-sec6319ac7b9/web)。

| 能力 | 关键 API | macOS | 说明 |
|---|---|---|---|
| 密码 | `ASCredentialProviderViewController`（AppKit 下是 `NSViewController` 子类）、`prepareCredentialList(for:)`、`ASPasswordCredential` | 11+ | 用户在建议列表里点「1Melon…」，扩展弹出自己的列表让用户选 |
| 密码直接出现在建议里 | `ASCredentialIdentityStore` + `ASPasswordCredentialIdentity`、`provideCredentialWithoutUserInteraction(for:)` | 11+（`ASCredentialRequest` 版本是 14+） | 扩展预先登记「网站 + 用户名」（**不含密码**），系统在输入框的下拉建议里直接列出；用户选中后系统再向扩展要密码 |
| 通行密钥 | `ASPasskeyCredentialIdentity`、`prepareCredentialList(for:requestParameters:)`、`prepareInterface(forPasskeyRegistration:)`、`ASPasskeyAssertionCredential` / `ASPasskeyRegistrationCredential` | 14+ | 注册和登录都由扩展完成，私钥在扩展里 |
| 一次性验证码（TOTP） | `prepareOneTimeCodeCredentialList(for:)`、`ASOneTimeCodeCredentialIdentity`、`completeOneTimeCodeRequest(using:)` | **15+** | macOS 14 上没有，只能在填密码的同时把验证码复制到剪贴板（1Password 的老做法） |
| 保存 / 生成密码、凭据变更通知 | `prepareInterface(for: ASSavePasswordRequest)`、`ASGeneratePasswordsRequest`、`report…` 系列 | 新 API，具体 macOS 版本**待核实** | 网站报告「这个密码不用了」「用户名改了」之类；第一期不做 |
| 任意文本插入 | `prepareInterfaceForUserChoosingTextToInsert()` | **待核实**（iOS 18 有，macOS 是否支持没查到） | 论坛反映 macOS 上第三方提供者进不了任意输入框的右键「自动填充」菜单（[开发者论坛 tag](https://developer.apple.com/forums/tags/autofill)） |

- 主应用和扩展**都要**带 `com.apple.developer.authentication-services.autofill-credential-provider` 权限（官方文档原话：「to both the extension and its containing app」）。
- 用户开启的位置：平台安全指南写的是 macOS 13 起在「系统设置」的扩展设置里。实际界面里，macOS 14 是「密码 → 密码选项」，macOS 15 起是「通用 → 自动填充与密码」（具体路径待实测）。应用自己关不掉，只能引导用户去设置（`ASSettingsHelper`）。
- `Info.plist` 的 `NSExtension → NSExtensionAttributes → ASCredentialProviderExtensionCapabilities` 声明支持哪几样（`ProvidesPasswords`、`ProvidesPasskeys`、`ProvidesOneTimeCodes`、`ShowsConfigurationUI`）。

**1Melon 的最低系统是 macOS 14**：密码、通行密钥在 14 上就能用；验证码要用 `@available(macOS 15, *)`，14 上退回「填密码时把验证码复制到剪贴板」。

### 1.2 各浏览器和应用的支持程度

| 场景 | 密码 | 一次性验证码 | 通行密钥 | 依据 |
|---|---|---|---|---|
| **Safari**（macOS 14+） | ✅ | ✅（macOS 15+） | ✅ | 已核实：Apple 平台安全指南写明可以填进「an app or a website in Safari」；1Password 8.12.32（2026-08-11 正式版）的原生 AutoFill 在 Safari 里能用（[公告](https://www.1password.community/announcements-52/macos-autofill-is-now-available-to-everyone-25254)，beta 版要求「macOS 14 Sonoma on Apple silicon」，[2026-05 说明](https://www.1password.community/announcements-52/may-2026-at-1password-native-macos-autofill-a-new-developer-site-and-more-24666)）。Safari 设置里「自动填充 → 用户名和密码」要打开 |
| **原生应用**（AppKit / SwiftUI，用系统输入框，标了 `textContentType` 或带 Associated Domains） | ✅（大体能用，**不稳定**） | ⚠️ 待实测 | ✅（应用自己调 `ASAuthorization` 时会弹系统面板） | 平台安全指南写了「app」；WWDC20 [AutoFill everywhere](https://developer.apple.com/videos/play/wwdc2020/10115/) 说 macOS Big Sur 起 AppKit 应用支持密码和验证码自动填充。但论坛里有开发者反映原生应用里常常不出建议，也进不了右键菜单。**用自绘输入框或 Electron 的应用不支持** |
| **Chrome** | ❌（没找到支持的官方说明） | ❌ | ⚠️ 多半可以，待实测 | Chrome 118 起在 macOS 13.5+ 上通过系统 API 用 iCloud 钥匙串里的通行密钥（[Chrome 官方博客](https://developer.chrome.com/blog/passkeys-on-icloud-keychain)）；Chrome 安全团队的 Adam Langley 写过：macOS 14 起第三方密码管理器可以把通行密钥提供给系统，但 Chrome 里会暂时显示成「iCloud Keychain」（[ImperialViolet](https://www.imperialviolet.org/2023/10/18/icloudkeychain.html)）。密码方面，Chrome 用自己的密码管理器，第三方都要装 Chrome 扩展 |
| **Firefox**（及 Zen 等衍生版） | ❌ | ❌ | ⚠️ 待实测 | Firefox 122（2024-01）起在 macOS 上能用 iCloud 钥匙串的通行密钥（[Mozilla Connect](https://connect.mozilla.org/t5/ideas/support-webauthn-passkeys/idc-p/49528)）；密码不走系统 AutoFill，Zen 在 macOS 26 上也有人提了同样的需求（[zen-browser#12452](https://github.com/zen-browser/desktop/discussions/12452)） |

一句话：**系统凭据提供者在 Safari 里最完整；原生应用能用但不稳定；Chrome 和 Firefox 只能指望通行密钥。**作者平时用哪个浏览器，决定了这条路值多少。

## 2. 工程上要改什么

### 2.1 把扩展（.appex）打进 `1Melon.app`

- **SwiftPM 没有 app extension 产物类型**，只能产出可执行文件和库。要得到 `.appex`，有两条路：

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A. SwiftPM + 手工组装（推荐，先验证）** | `Package.swift` 里加一个只在 macOS 编的 `executableTarget("MelonAutoFill")`，链接参数 `-Xlinker -e -Xlinker _NSExtensionMain` 把入口换成扩展入口；`package-desktop.sh` 把它组装成 `Contents/PlugIns/1Melon AutoFill.appex/Contents/{MacOS,Info.plist,embedded.provisionprofile}`，**先签扩展、再签主应用**（由内向外） | 和现在的构建方式一致；Linux CI 不受影响（`#if os(macOS)` 里加 target，和 `MelonApp` 一样）；不引入新工具 | `unsafeFlags` 只能用在根包，没问题，但这是非官方路子。扩展的 `Info.plist`（`NSExtensionPointIdentifier = com.apple.authentication-services-credential-provider-ui`、`NSExtensionPrincipalClass`）要自己写对。出错时只能看 `pluginkit -m -v -p com.apple.authentication-services-credential-provider-ui` 和系统日志，没有 Xcode 帮忙 |
| B. 引入 Xcode 工程（手写 `.xcodeproj` 或用 XcodeGen 生成） | 主应用和扩展两个 target，`xcodebuild archive` + `-exportArchive` | 官方支持的路子，签名和组装都由 Xcode 做 | 要改 CLAUDE.md 里「一个 Swift Package」的约定；melon-ci `desktop-release` 调的是 `package-desktop.sh`，脚本里要换成 `xcodebuild`；XcodeGen 是新依赖 |

- 推荐 A：阶段 0 用一天做个「空扩展」验证。能在「自动填充与密码」里出现、Safari 里能弹出就继续；不行就退到 B。
- 扩展只放界面胶水，填充逻辑（条目查找、域名匹配、TOTP）放 `MelonCore`，在 Linux 上也能测。

### 2.2 签名

当前：一个 App ID `cn.melonkid.1melon`，一份 Developer ID 描述文件（到 2044 年），权限只有 App 标识、Team ID、钥匙串访问组 `793RBBSGZN.cn.melonkid.1melon`；应用**没开沙盒**。

要改的：

1. **新建 App ID** `cn.melonkid.1melon.autofill`（显式 ID），开 **AutoFill Credential Provider**。
2. **主应用 App ID** `cn.melonkid.1melon` 也开 **AutoFill Credential Provider**。改了能力，原来的描述文件就不再包含这个权限，**要重新生成**。
3. **App Group**：macOS 上推荐用 `<TeamID>.<名字>` 的写法，比如 `793RBBSGZN.cn.melonkid.1melon.shared`。系统会核对访问者签名里的 Team ID，不需要在开发者网站上注册，也不用写进描述文件（[Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups) 的 Note）。不要用 `group.` 开头：macOS 15 起，没有被描述文件授权的 `group.` 容器每次访问都会弹「想访问其他 App 的数据」（[Apple 开发者论坛 DTS 回复](https://developer.apple.com/forums/thread/756701)、[thread/767604](https://developer.apple.com/forums/thread/767604)）。
4. **钥匙串访问组**：扩展的权限里也写 `793RBBSGZN.cn.melonkid.1melon`。一般 Developer ID 描述文件授权的是 `793RBBSGZN.*`，扩展用主应用的组名也能签过，但**这一点我没能核实**：读本机描述文件的命令被权限拦了。你可以自己跑 `security cms -D -i <描述文件> | plutil -extract Entitlements xml1 -o - -`，看 `keychain-access-groups` 是不是 `793RBBSGZN.*`。
5. **扩展的权限**（签名时传）：`com.apple.security.app-sandbox`（**扩展必须开沙盒**）、AutoFill 权限、`com.apple.security.application-groups`、`keychain-access-groups`、App 标识和 Team ID。**不加** `com.apple.security.network.client`，扩展从系统层面就发不了网络请求。
6. **主应用**可以继续不开沙盒。它要加 AutoFill 权限，App Group 也要加（没开沙盒的应用也能用 App Group 容器）。
7. **公证**：扩展和主应用都开 hardened runtime、带时间戳。公证本身不用改，流水线照旧签 dmg。

**对 melon-ci `desktop-release` 的影响**（只描述，不改）：

- 现在流水线只认一个 Secret `MACOS_PROVISION_PROFILE_BASE64`，导出成一个环境变量 `PROVISIONING_PROFILE` 交给 `package-desktop.sh`。
- 要改成能传多份，有两种改法：
  - **a. 通用（推荐）**：加一个 Secret，比如 `MACOS_PROVISION_PROFILES_BASE64`，内容是多份描述文件打成的 tar 包的 base64。流水线解到一个目录，经 `PROVISIONING_PROFILES_DIR` 交给脚本，脚本按 bundle id 自己挑哪份签哪个。别的桌面项目以后也能用。
  - **b. 简单**：再加一个可选 Secret `MACOS_PROVISION_PROFILE_EXTENSION_BASE64` → `PROVISIONING_PROFILE_EXTENSION`。
- 两种都向后兼容，只加不改，可以在 `v2` 上发小版本。1Melon 的 `release-desktop.yml` 不用动。
- 本机自测时，脚本已经会在 Xcode 的描述文件目录里按 bundle id 找；扩展的描述文件按同样的规则找就行。

### 2.3 扩展和主应用怎么共享保险库

**问题**：扩展在沙盒里，只能读写自己的容器、App Group 容器，以及权限里明确例外的路径。`~/Library/Application Support/1Melon/` 不在其中。

| 方案 | 做法 | 评价 |
|---|---|---|
| **A. 迁到 App Group 容器（推荐）** | 数据目录改为 `~/Library/Group Containers/793RBBSGZN.cn.melonkid.1melon.shared/`（`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`）。新版首次启动时，把整个旧目录搬过去：同卷 `rename`，失败就复制 → 校验 → 删旧。`device/`、`backups/` 一起搬 | 官方做法。`MELON_DATA_DIR` 照样能用于开发；`Backup.swift` 默认的 `backups/` 跟着搬。要动 `VaultRepository` 的默认路径、spec §3 里写的 macOS 路径（只是文档，**不是格式改动**，不用升版本），以及 CLAUDE.md 里「本地数据只在 …」那句 |
| B. 沙盒临时例外 | 扩展权限加 `com.apple.security.temporary-exception.files.home-relative-path.read-write` = `/Library/Application Support/1Melon/` | 不用迁数据。Developer ID 分发可以用，但 Apple 明说临时例外不鼓励用。以后哪怕想上 Mac App Store 也过不了审。可以当阶段 0 的捷径 |
| C. 扩展经 XPC 问主应用 | 扩展不碰文件，用 App Group 的 Mach 服务名跟主应用通信 | 主应用没开时用不了（要后台常驻或按需拉起），IPC 也多出一个攻击面。只适合当「主应用已解锁时免 Touch ID」的优化，不适合当主路径 |

- 扩展**只读**就够密码、验证码；通行密钥**注册**时要写保险库。写保险库就会和主应用并发：两个进程都是原子 rename，后写的会覆盖先写的。所以写入前要加文件锁（`flock`，放在 App Group 容器里），读到的修订号也要再核对一遍。这是阶段 3 的事。
- 写完后要通知主应用重新加载（`DistributedNotificationCenter`，或者监视文件），同步引擎照常把改动传上去。

**钥匙串和解锁**：

- Touch ID 条目在数据保护钥匙串里（`kSecUseDataProtectionKeychain`，`service = cn.melonkid.1melon.touch-id`，`biometryCurrentSet` + `WhenPasscodeSetThisDeviceOnly`）。扩展的权限里带上同一个访问组，就能用同样的查询读到它。
- 每次读都要过 Touch ID，指纹框由系统在扩展界面上弹。**这正好就是我们要的「每次填充确认一次」。**
- **主应用锁着时扩展怎么解锁**：扩展不看主应用的状态，自己解锁：
  1. Touch ID 读钥匙串，得到 AK（开着同步时还有登录密钥种子，扩展用不到，读出来立即清零）；
  2. 用 AK 打开账户文件和需要的保险库文件（`AccountRepository.unlock(accountKey:)` 现成可用）；
  3. 没登记 Touch ID（开发版、指纹变过、「每两周要求输一次主密码」到期），就在扩展界面里输主密码。还要读 `device/secret-key.json`，因为 Secret Key 也在数据目录里，所以必须一起迁进 App Group；
  4. 扩展**不**写 `unlock.lastPasswordUnlock`，也不改 Touch ID 登记。这两样只由主应用管，免得重蹈验收里「登记被测试账户换掉」的覆辙；
  5. **主应用的 UserDefaults 扩展读不到**：自动锁定时间、Touch ID 开关这些设置在主应用的 defaults 里。扩展需要的少数几项，改存到 App Group 的 `UserDefaults(suiteName:)`。
- 输主密码要跑 Argon2id，默认 256 MiB。macOS 对扩展的内存上限没有公开文档（iOS 上 AutoFill 扩展大约 120 MB），**待实测**。要是在扩展里跑不动，就只能用 Touch ID；没有 Touch ID 时提示「先在 1Melon 里解锁一次」。

## 3. 安全

### 3.1 扩展进程里明文和密钥的生命周期

- 系统按需拉起扩展进程，`completeRequest` 后进程可能还会留一会儿，也可能被复用，不能当它「用完就死」。所以：
  - **不在扩展里缓存解锁状态**。每次请求重新 Touch ID → AK → 解密，完成或取消后马上丢掉。`SymmetricKey` 释放时 CryptoKit 会清零，`LocalUnlockSecret.bytes` 这类 `Data` 用完手动清零；
  - **只解密需要的条目**。列表界面只需要标题、用户名、网址（`index` 不够用，要解密条目才知道网址），选中后才取密码；
  - 交给系统的 `ASPasswordCredential(user:password:)` 只收 `String`，这里躲不开明文 `String`，只能尽量缩短它的存活时间；
  - **不写日志**（`os_log` 里不出现任何条目内容和域名），不落盘，也没有崩溃报告（项目本来就没接）。
- 扩展没有网络权限（§2.2），也就没有「把明文发出去」这条路。

### 3.2 钓鱼防护：域名怎么匹配

- **网页里**：系统传进来的 `ASCredentialServiceIdentifier` 是当前页面的 URL 或域名，由浏览器（Safari）给出，网页改不了。真正的风险在**我们怎么匹配**：
  - 规则：条目 `url` 字段的主机，和请求主机比较**可注册域名**（eTLD+1，按 Public Suffix List）：`accounts.github.com` 能匹配 `github.com`，`github.com.evil.io` 不匹配。还要处理大小写、去掉末尾的 `.`、IDN 转成 punycode 再比；
  - Public Suffix List 打包进应用，随版本更新，**不联网拉**，符合「不加载远程内容」；
  - 列表里只把**匹配的**条目放在前面；用户手动搜别的条目来填时，界面上要明确提示「此条目的网址是 X，当前网站是 Y」；
  - 只填 https 页面；http 页面要用户再确认一次。
- **通行密钥**：浏览器按 WebAuthn 把 RP ID 和页面 origin 校验过才会发请求，扩展拿到的 `relyingPartyIdentifier` 是可信的，按完全相等匹配 `rpId` 即可。本身防钓鱼。
- **原生应用**：系统按应用的 Associated Domains（`webcredentials:`）给出域名；没配的应用，给的标识可能是空的。**空的时候不自动推荐任何条目**，只让用户手动搜。
- 这套匹配规则要写进 spec（§5），鸿蒙以后也照着做。

### 3.3 和 CLAUDE.md 安全约束的对照

| 约束 | 有没有冲突 | 说明 |
|---|---|---|
| 主密码和明文条目永远不落盘 | ⚠️ **只有一处**：`ASCredentialIdentityStore` | 往系统的凭据身份库里登记「网站 + 用户名 + 条目 id」（**没有密码**），系统存在提供者的容器里（平台安全指南：「Metadata is stored inside the credential provider app's container」），卸载时自动删除。这算明文元数据落盘。**建议**：第一期不登记，只走「点 1Melon → 扩展里选」；第二期做成设置项、默认关，打开时说明会留下什么。验证码（`ASOneTimeCodeCredentialIdentity`）同理 |
| 网络请求只有三种 | 没有冲突 | 扩展不开网络权限；图标、同步、检查更新都只在主应用里 |
| `device/` 不同步、不备份 | 没有冲突 | 迁进 App Group 后，`device/` 还是自己那个目录，同步和 `Backup.swift` 的逻辑都不变。Time Machine 对两个位置一视同仁，这一点不受影响 |
| 不从 CDN 拉资源 | 没有冲突 | Public Suffix List 打包进应用 |
| 平台特有的东西不进保险库文件 | 没有冲突 | App Group、凭据身份库都是本机的 |
| 保险库原子写入 | 要补 | 扩展写保险库（只有通行密钥注册会写）时，要和主应用互斥（§2.3） |

## 4. 对比：浏览器扩展方案

| | 系统凭据提供者 | Safari Web Extension | Chrome 扩展 + native messaging |
|---|---|---|---|
| **覆盖** | Safari 全部；原生应用大部分；Chrome / Firefox 只有通行密钥 | 只有 Safari | Chrome 及 Chromium 系（Edge、Arc、Brave）；Firefox 要再适配一遍 |
| **能填的** | 密码、验证码（15+）、通行密钥。系统 API 不支持银行卡、地址 | 页面上任何字段：银行卡、身份信息也能填 | 同左；通行密钥要用 `chrome.webAuthenticationProxy`（Chrome 115+），而且和别的密码管理器扩展抢请求（[bitwarden#20743](https://github.com/bitwarden/clients/issues/20743)、[#20973](https://github.com/bitwarden/clients/issues/20973)） |
| **工作量** | 中：一个 AppKit 扩展加打包、签名、数据迁移 | 中：还是一个 `.appex`，打包和签名问题一样都有；外加一套 JS / content script | 大：新技术栈（TypeScript），要在 `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` 装宿主清单，商店审核、发布流水线都另起一套；Chrome 改了 Manifest 规则就得跟着改 |
| **维护** | 低：跟 Apple 的 API 走，一年一次 WWDC | 中 | 高：识别页面表单是长期的苦活，网站一改版就可能填不上 |
| **安全面** | 小：不碰页面 DOM；域名由浏览器给；系统管界面；扩展沙盒、无网络 | 大：content script 跑在不可信的页面里，要防点击劫持、iframe 钓鱼、恶意页面伪造表单；域名识别全靠自己 | 同左，还多一条 native messaging 通道：要校验调用方扩展 id，主应用要开一个本地 IPC 口 |
| **和项目边界** | 在 `apps/desktop/` 里，我理解属于边界内（待你确认） | CLAUDE.md 明写「浏览器自动填充扩展不在本仓库」 | 同左 |

结论：浏览器扩展唯一的明显优势，是 **Chrome 里的密码**和**银行卡、地址**这类字段。值不值得为此多维护一套 JS 代码，取决于你主要用哪个浏览器。建议先做系统凭据提供者，用一段时间再决定。

## 5. 跨端：鸿蒙和 spec

### 5.1 鸿蒙（HarmonyOS NEXT）

- **系统有「密码保险箱」**：应用里的 ArkUI `TextInput` 设成 `InputType.USER_NAME` / `PASSWORD` / `NEW_PASSWORD` 并开着 `enableAutoFill`，系统就会帮着保存和填充，还能生成强密码（[华为文档：密码保险箱](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/passwordvault-autofill-strong-password-V5)）。这是**系统自带的保险箱**。
- **第三方当不了填充提供方**：提供自动填充服务的 `AutoFillExtensionAbility`，在 OpenHarmony 文档里标的是「**本模块为系统接口**」，从 API 11 开始（[OpenHarmony 文档](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-ability-kit/js-apis-app-ability-autoFillExtensionAbility-sys.md)），普通三方应用调不了。**截至这次调研，没找到华为对三方密码管理器开放自动填充的接口**，以后的版本会不会开放待跟进。
- 所以鸿蒙端能做的，暂时只有「复制 + 自动清除」，最多再加个桌面卡片 / 快捷入口。不影响现在的 spec。

### 5.2 要不要动 `spec/`

| 改动 | 是不是格式改动 | 什么时候 |
|---|---|---|
| **网址匹配规则**（新增一节「自动填充：网址匹配」）：可注册域名、PSL、大小写、IDN、端口、`http` 的处理，加一组测试向量 `url-match.json` | **不是**。只规定行为，不改文件结构，不用升版本 | 阶段 1，写代码前先写 spec |
| **数据目录位置**（§3 里写的 macOS 路径） | 不是。只改文档 | 阶段 1 |
| **通行密钥字段** | **是**。要升保险库文件版本、补测试向量 | 阶段 3 |

通行密钥那条有个坑：spec §5.6 规定「不认识的 `kind` 按 `text` 显示」，所以不能只加一个新 `kind = passkey` 就完事。旧客户端会把私钥当普通文本**明文显示**出来。办法（二选一，阶段 3 再定）：

- 升保险库文件版本，旧客户端直接拒绝打开新文件。会逼所有设备一起升级，自用的话可以接受；
- 或者把通行密钥放进一个新的条目类型 `passkey`，私钥字段用已有的 `secret` kind（默认隐藏），`rpId`、`credentialId`、`userHandle`、`userName` 用 `text`。旧客户端会把它当成「不认识的类型」原样显示，私钥照样隐藏，不用升版本。缺点是在别人看来就是一堆普通字段，一不小心就会被编辑坏。

不管选哪种，原语都要多一个 **ECDSA P-256（ES256）**。CryptoKit 有 `P256.Signing`，鸿蒙 cryptoFramework 有 ECC256 签名，两端都能实现。按 CLAUDE.md，引入前再确认一次。

## 6. 分阶段计划与工作量

工作量按「Claude 写 + 你验收」的人日粗估。

| 阶段 | 内容 | 工作量 | 你要做的 |
|---|---|---|---|
| **0. 验证可行性** | 空扩展：SwiftPM 编出来、手工组装、开发证书签名；验证它在系统设置里出现、Safari 里能弹出；顺便实测 Chrome / Firefox 里通行密钥面板能不能看到 1Melon、原生应用（如「邮件」的添加账户）能不能弹建议、扩展里能不能跑 256 MiB 的 Argon2 | 1–2 天 | 建扩展 App ID、给两个 App ID 开能力、生成开发描述文件（清单 §7） |
| **1. 密码 + 验证码** | spec 加网址匹配规则和向量；数据目录迁到 App Group（含迁移和回退）；扩展里 Touch ID / 主密码解锁；列表、搜索、选中填充；macOS 15+ 填验证码，14 上复制验证码；`package-desktop.sh` 支持两份描述文件 | 6–9 天 | 生成两份 Developer ID 描述文件；改 melon-ci（或同意我另开 PR 去改） |
| **2. 下拉框直接建议**（可选） | 设置项「在系统建议里显示 1Melon 条目」，默认关；条目变动时同步 `ASCredentialIdentityStore`；锁定、注销、关掉开关时清空 | 2–3 天 | 拍板 §3.3 |
| **3. 通行密钥** | spec 定字段并补向量（升版本或新类型）；ES256；注册（扩展写保险库 + 文件锁）、登录；和同步、合并的交互；安全报告里显示通行密钥 | 8–12 天 | 拍板格式方案 |

合计：做到阶段 1 大约 1.5–2 周，做全约 4 周。阶段 0 不通过就停，换方案 B（Xcode 工程）重新估。

## 7. 需要你本人操作的事项

开发者网站（Certificates, Identifiers & Profiles）：

1. **Identifiers → `cn.melonkid.1melon`**：勾上 **AutoFill Credential Provider**，保存。
2. **Identifiers → 新建 App ID** `cn.melonkid.1melon.autofill`（Explicit），勾 **AutoFill Credential Provider**。如果阶段 0 证明钥匙串访问组要单独授权，再勾 Keychain Sharing。
3. App Group 用 `793RBBSGZN.` 开头的写法，**不用在网站上注册**（如果阶段 0 发现 Developer ID 版仍然弹访问提示，再改成注册 `group.` 并写进描述文件）。
4. **Profiles**：
   - 主应用的 Developer ID 描述文件改了能力，要**重新生成**（Edit → Save 就会出一份新的）；
   - 新建扩展的 Developer ID 描述文件；
   - 本机自测用的 Development 描述文件同样要两份（让 Xcode 生成，或在网站上手动建）。
5. 核对描述文件的 `keychain-access-groups` 是不是 `793RBBSGZN.*`（命令见 §2.2 第 4 条）。

GitHub：

6. 把两份 Developer ID 描述文件放进仓库 `production` 环境的 Secret，名字和格式按 melon-ci 改完后的约定来（§2.2）。原来的 `MACOS_PROVISION_PROFILE_BASE64` 要换成新的主应用描述文件，不然发布出来的主应用没有 AutoFill 权限。

本机：

7. 新版装好后，在「系统设置 → 通用 → 自动填充与密码」（macOS 14 是「密码 → 密码选项」）里打开 1Melon；Safari 的「设置 → 自动填充 → 用户名和密码」要开着。
8. 数据迁移前手动备份一次 `~/Library/Application Support/1Melon/`。

## 8. 风险和未知点

| # | 风险 / 未知 | 影响 | 怎么排除 |
|---|---|---|---|
| 1 | SwiftPM + `_NSExtensionMain` 手工组装出来的扩展，系统认不认 | 不认就要上 Xcode 工程 | 阶段 0 |
| 2 | Chrome、Firefox 里能不能用第三方提供者的通行密钥，显示成什么 | 影响这条路对非 Safari 用户的价值 | 阶段 0 实测 |
| 3 | Chrome、Firefox 里的**密码**用不了系统提供者 | 用 Chrome 为主的话，收益有限 | 已知；兜底靠复制，或以后做浏览器扩展 |
| 4 | 原生应用里不稳定（不出建议、进不了右键菜单） | 体验问题 | 论坛已有多人反映，接受 |
| 5 | 扩展里跑 256 MiB 的 Argon2 会不会被系统杀掉 | 不行就只能靠 Touch ID | 阶段 0 实测 |
| 6 | Developer ID 描述文件里的钥匙串访问组是不是通配 `793RBBSGZN.*` | 不是的话扩展读不到 Touch ID 条目，要开 Keychain Sharing 并改访问组（又一次迁移钥匙串条目） | 你本人核对，见 §7 第 5 条 |
| 7 | macOS 15+ 上 Developer ID 版访问 Team ID 开头的 App Group 会不会弹提示 | 弹的话要改成注册 `group.` | 阶段 0 实测（论坛里有 ad-hoc 签名的人反映仍然弹） |
| 8 | 数据目录迁移出错 | 打不开保险库 | 迁移前先自动备份；先复制、校验，最后才删旧目录；旧路径保留一个版本作回退 |
| 9 | 主应用和扩展同时写保险库 | 丢改动 | 只有通行密钥注册会写；文件锁加修订号核对（阶段 3） |
| 10 | `ASCredentialIdentityStore` 的明文元数据 | 和「明文不落盘」有张力 | 默认不开（§3.3） |
| 11 | 保存、生成密码，`report…` 系列，「任意文本插入」在 macOS 上从哪个版本开始有 | 只影响后续功能 | 用到时再查 SDK 头文件 |
| 12 | 鸿蒙以后会不会对三方开放 `AutoFillExtensionAbility` | 影响鸿蒙端规划 | 跟进华为文档 |
| 13 | 苹果的能力支持表（[Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos)）这次没打开 | AutoFill Credential Provider 支不支持 Developer ID 没有直接核实；1Password（Developer ID 分发）已经在用，间接说明支持 | 建 App ID 时网站上能直接看到 |

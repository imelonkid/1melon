# 保险库文件格式（账户文件版本 1–2，保险库文件版本 1）

> 状态：**已实现，待定稿**。桌面端 `MelonCore` 已实现，测试向量已生成，并用独立的 Python 实现（`spec/tools/verify-vectors.py`）交叉验证过：正常路径和全部篡改用例都一致。首个正式版发布前定稿；定稿后任何改动都要升 `version`，并保证新版客户端能读旧文件。

这是各端（macOS、鸿蒙）之间唯一的契约。各端代码不共享，只要都按本文读写、都通过 `spec/test-vectors/` 就算对齐。

## 1. 设计目标

- **只用两端都能实现的原语**：Argon2id v1.3（RFC 9106）、AES-256-GCM、HMAC-SHA1/SHA-256。
  - 桌面端的 Argon2id 用官方参考实现的 C 源码（`apps/desktop/Sources/CArgon2`），鸿蒙端可以用 NDK 编译同一份。
  - 任何符合 RFC 9106 的实现（libsodium、OpenSSL 3.2+）算出的结果都一样。
- **一个主密码解开全部保险库**：只算一次 KDF；改主密码只重新包装一把账户密钥，保险库文件一个都不用动。
- **为云同步预留**：每个保险库一个文件；条目单独加密，带 id 和修订号，能按条目合并；删除留墓碑；没改过的条目密文不变。
- **能发现篡改**：每段密文都用 AEAD 认证并绑定上下文，另有加密索引，能发现条目被删除或回退。
- 平台特有的解锁方式（Touch ID + 钥匙串、鸿蒙生物识别 + HUKS）**不进文件**，只在各端本地缓存账户密钥。

## 2. 密钥层级

```
主密码 ──Argon2id(salt, 参数)──▶ KEK（32 字节，只在内存）
                                   │ AES-256-GCM 包装（account.1melon）
                                   ▼
                     AK 账户密钥（32 字节随机，生成后不变）
                                   │ AES-256-GCM 包装（每个保险库文件里一份）
                     ┌─────────────┴─────────────┐
                 VK「个人」                    VK「工作」 …（各 32 字节随机）
                     │ AES-256-GCM
          ┌──────────┼──────────┐
        索引       条目 1 … n     元数据
```

- **KEK**：主密码先做 Unicode NFC 规范化，再按 UTF-8 编码，然后进 Argon2id，输出 32 字节。
  - 账户文件 v1（不带 Secret Key）：KEK 就是这 32 字节。
  - 账户文件 v2（带 Secret Key，见 §3.4）：KEK = HKDF-SHA256(IKM = Argon2id 输出, salt = Secret Key 的 16 字节, info = `1melon:v2:kek:<accountId>`, L = 32)。
- **AK**：新建账户时由 CSPRNG 生成。改主密码 = 用新 KEK 重新包装 AK。
- **VK**：每个保险库一把，新建保险库时由 CSPRNG 生成，用 AK 包装后存在保险库文件里。
- **本地快速解锁**：解锁成功后，各端可以把 AK 交给平台安全存储保管，下次用生物识别解锁。改主密码不影响它，因为 AK 不变。
  - 这部分**只属于设备**，不属于保险库格式，放在数据目录的 `device/` 下，**不参与同步**。
  - macOS（已实现，`device/local-unlock.json`）：安全隔区里生成一把 P-256 密钥（`biometryCurrentSet`，每次使用都要 Touch ID，指纹有增删时自动作废）；wrapKey = HKDF-SHA256(ECDH(安全隔区私钥, 临时公钥), salt = accountId, info = `1melon:v1:local-unlock`)，用 AES-256-GCM 加密 AK，AAD 是 `1melon:v1:local-unlock:<accountId>`。文件里只有安全隔区密钥的不透明句柄、临时公钥和密文，离开这台 Mac 就没用。
  - 鸿蒙（预留）：用 HUKS 加生物识别，做法类似。

## 3. 文件

```
<数据目录>/                     macOS：~/Library/Application Support/1Melon/
├─ account.1melon               账户文件：KDF 参数 + 包装后的 AK
└─ vaults/
   ├─ <vaultId>.1melon          每个保险库一个文件，文件名就是 vaultId
   └─ …
```

- 所有文件都是 UTF-8 JSON。二进制字段一律用标准 Base64（带 `=` 填充）；整数字段（`version`、`rev`、KDF 参数、时间戳、`order`）写成 JSON 整数。
- 写文件必须原子写入：先写同目录的临时文件，fsync，再 rename。文件权限 0600，所在目录 0700。
- 新建账户时**先写保险库，再写账户文件**，中途失败不会留下「有账户、没保险库」的半成品。

### 3.1 账户文件 `account.1melon`

```json
{
  "format": "1melon-account",
  "version": 1,
  "accountId": "…（UUID v4，小写）",
  "kdf": { "alg": "argon2id13", "memKiB": 262144, "iterations": 3, "parallelism": 1, "salt": "<16 字节>" },
  "secretKey": "none",
  "wrappedKey": { "nonce": "<12 字节>", "ct": "<32 字节 AK 的密文 + 16 字节 tag>" }
}
```

- `secretKey`：v1 只允许 `none`。要用 Secret Key 的账户写成 v2，见下面。

**v2：带 Secret Key 的账户**（开启云同步时启用，见 §3.4、§8）

```json
{
  "format": "1melon-account",
  "version": 2,
  "accountId": "…",
  "kdf": { …（同 v1） },
  "secretKey": "required",
  "secretKeyId": "<8 字节>",
  "wrappedKey": { "nonce": "<12 字节>", "ct": "<48 字节>" }
}
```

- `secretKey` 必须是 `required`；`secretKeyId` = HMAC-SHA256(key = Secret Key 的 16 字节, 消息 = `1melon:v2:secret-key-id:<accountId>`) 的前 8 字节。它只用来在解开之前分辨「Secret Key 不对」和「主密码不对」，泄露它不会降低 Secret Key 的 128 位强度。
- `wrappedKey` 用 v2 的 KEK 加密，AAD 是 `1melon:v2:account:<accountId>`。
- v1 和 v2 之间可以互转：启用或停用 Secret Key 都要输主密码，只重新包装 AK，保险库文件不动。
- 不支持 v2 的旧客户端会提示「需要升级」（见 §4 的检查顺序），不会误读。

### 3.2 保险库文件 `vaults/<vaultId>.1melon`

```json
{
  "format": "1melon-vault",
  "version": 1,
  "vaultId": "…（小写 UUID，与文件名一致）",
  "accountId": "…（属于哪个账户）",
  "wrappedKey": { "nonce": "…", "ct": "<VK 的密文 + tag>" },
  "index": { "nonce": "…", "ct": "…" },
  "meta":  { "nonce": "…", "ct": "…" },
  "items": [ { "id": "…（小写 UUID）", "rev": 3, "nonce": "…", "ct": "…" } ]
}
```

### 3.3 KDF 参数

- `alg` 固定为 `argon2id13`（Argon2id v1.3，RFC 9106），输出 32 字节；不用 secret 和 associated data。
- `parallelism` 固定为 1（libsodium 只支持 1，固定下来各端都好实现）。`salt` 16 字节，由 CSPRNG 生成。
- 默认值是 **256 MiB、3 次迭代**。实测在 Apple 芯片的 Mac 上（release 构建）约 0.3 秒；鸿蒙手机待实测，目标 1 秒左右。参数随账户文件保存，以后可以提高，改主密码时顺带升级。
- **打开前先校验参数，校验不过就不派生密钥**：
  - 内存 < 64 MiB 或迭代 < 2：拒绝，防止有人改文件头降低强度；
  - 内存 > 1 GiB 或迭代 > 10：拒绝，防止被改成把机器卡死的参数；
  - `alg`、`parallelism` 或 `salt` 长度不对：拒绝。

### 3.4 Secret Key

- 128 位，由 CSPRNG 生成，每个账户一把，生成后不变（停用再启用会换一把新的）。
- **只存在设备上，不进任何会离开设备的地方**：不进保险库文件、不进云同步、不进自动备份。
  - macOS：`<数据目录>/device/secret-key.json`，权限 0600，和 Touch ID 文件一样只属于这台设备。
  - 鸿蒙（预留）：应用沙箱里的同名文件，或 HUKS。
- **给人看的写法**：`M1-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX`。
  - `M1` 是写法版本。后面 28 个字符用 Crockford Base32（字母表 `0123456789ABCDEFGHJKMNPQRSTVWXYZ`），每 7 个一组。
  - 前 26 个字符：在 16 字节前面补 2 个 0 比特凑成 130 比特，按大端每 5 比特一个字符，所以第一个字符只可能是 `0`–`7`。
  - 后 2 个字符是校验：SHA-256(16 字节) 的前 10 比特，用来发现抄错。
  - 解析时：忽略大小写、连字符和空白；`M1` 前缀可以省略；`O` 当 `0`，`I`、`L` 当 `1`；字符数不对、有别的字符、第一个字符大于 `7`、校验对不上，都算「写法不对」。
- 新设备拿到 Secret Key 的办法：从已登录的设备复制「设置码」，或者照着自己保存的「应急资料」输入（界面在云同步里做）。**两样都丢了，又没有任何一台设备还登录着，带 Secret Key 的账户就再也打不开了**；界面必须在启用时把这一点说清楚。

## 4. 加密与认证上下文（AAD）

所有密文都是 AES-256-GCM，nonce 12 字节，每次加密都用 CSPRNG 新生成。`ct` = 密文 ‖ 16 字节 tag。

每段密文都用 AAD 绑定它在文件里的位置，防止把密文挪到别处用：

| 段 | 密钥 | AAD（UTF-8 字符串） |
|---|---|---|
| 账户 `wrappedKey`（v1） | KEK | `1melon:v1:account:<accountId>` |
| 账户 `wrappedKey`（v2） | KEK（带 Secret Key） | `1melon:v2:account:<accountId>` |
| 保险库 `wrappedKey` | AK | `1melon:v1:key:<accountId>:<vaultId>` |
| `index` | VK | `1melon:v1:index:<vaultId>` |
| `meta` | VK | `1melon:v1:meta:<vaultId>` |
| `items[i]` | VK | `1melon:v1:item:<vaultId>:<id>:<rev>` |

### 打开时的检查顺序

**账户文件**
1. 解析 JSON，`format` 必须是 `1melon-account`；`version` 比自己支持的大，就提示升级客户端，不往下解析。
2. `accountId` 必须是小写 UUID；v1 的 `secretKey` 必须是 `none`，v2 的必须是 `required` 且 `secretKeyId` 是 8 字节；KDF 参数按 §3.3 校验；`wrappedKey.ct` 必须是 48 字节。
3. v2：先看手上有没有 Secret Key，没有就是**需要 Secret Key**；有就先算 `secretKeyId` 比对，对不上就是 **Secret Key 不对**，不跑 KDF。
4. 派生 KEK，解开 `wrappedKey`，失败就是**主密码错误**。改了 `accountId` 或 `salt` 也会表现成这样，因为 KEK 或 AAD 对不上。

**每个保险库文件**（用 AK）
1. 解析 JSON，`format` 必须是 `1melon-vault`；版本处理同上。
2. `vaultId`、`accountId` 必须是小写 UUID；`accountId` 必须等于当前账户，否则提示「不属于当前账户」；`wrappedKey.ct` 必须是 48 字节。
3. 用 AK 解开 `wrappedKey`；解开 `index` 和 `meta`；逐条解开条目（每条的 `id` 必须是小写 UUID、`rev` ≥ 1、`id` 不重复），再和索引核对。任何一步失败都是**已篡改**。
4. 单个保险库打不开，不影响其他保险库：其余照常打开，界面提示哪个保险库打不开。

各端给用户的提示至少要区分这七种：不是 1Melon 文件、需要升级、文件头参数不安全、主密码错误、需要 Secret Key、Secret Key 不对、文件损坏或被篡改。

## 5. 明文结构

### 5.1 保险库元数据 `meta`

```json
{ "name": "个人", "icon": "person", "color": "blue", "order": 0, "created": 1761400000000 }
```

- `icon` 取自固定集合：`person`、`briefcase`、`house`、`heart`、`star`、`folder`、`lock`、`server`、`cart`、`gamecontroller`。
- `color` 取自固定集合：`blue`、`green`、`orange`、`red`、`purple`、`teal`、`gray`。
- 各端自己把 `icon` 映射成图标资源、把 `color` 映射成色值；不认识的就用默认值。
- 侧栏按 `order` 从小到大排，相同时按 `created`。
- 只放要跟着保险库走的东西。界面设置（主题、自动锁定时间等）属于各端本地，不放这里。

### 5.2 条目

```json
{
  "type": "login",
  "title": "GitHub",
  "favorite": true,
  "tags": ["开发"],
  "notes": "",
  "iconData": "<PNG，可选>",
  "iconHost": "github.com",
  "sections": [
    { "id": "…", "title": "", "fields": [
      { "id": "…", "label": "用户名", "kind": "text", "value": "…" },
      { "id": "…", "label": "密码", "kind": "password", "value": "…" },
      { "id": "…", "label": "网站", "kind": "url", "value": "github.com" }
    ] },
    { "id": "…", "title": "两步验证", "fields": [
      { "id": "…", "label": "一次性验证码", "kind": "totp", "value": "otpauth://… 或 Base32" }
    ] }
  ],
  "created": 1614643200000,
  "modified": 1758153600000,
  "deleted": false
}
```

- **分组 `sections`**：一组字段，可以有标题（第一个分组通常没有）。分组和字段都有 `id`（小写 UUID），顺序就是显示顺序。
- **字段**：`label` 是显示名，用户可以改；各端识别字段靠 `kind`，不靠 `label` 的文字。`monospace: true` 表示用等宽字体显示（卡号、主机、Key ID 等），省略就是 false。
- **网站图标**：
  - `iconData` 是 PNG，64×64 像素、不超过 16 KB；
  - `iconHost` 记录已经为哪个主机处理过图标：取到了，或者用户选了「使用默认图标」。条目里第一个网址的主机和它不一样时才重新取；
  - 没有 `iconData` 就显示类型的默认图标。
  - 怎么取（各端一致）：直接向网站本身请求，不经第三方服务；只对公网域名、只走 https；IP、localhost、`.local` 等内网地址不请求；先读首页 `<link rel="…icon…">` 声明的图标（不要 SVG 和 mask-icon，优先不小于 64px 里最小的），没有再取 `/favicon.ico`；取回后等比缩放、居中画进 64×64 透明画布，编码成 PNG。
- 时间一律是 UTC 毫秒时间戳（整数）。

### 5.3 条目类型 `type`

`login`（登录）、`card`（银行卡）、`note`（安全笔记）、`identity`（身份信息）、`ssh`（SSH 密钥）、`api`（API Token）、`wifi`（Wi-Fi）。

**类型就是一套模板**：只决定新建时有哪些分组和字段（附录 A），建好以后分组和字段都可以增删改、改名、排序。

### 5.4 字段类型 `kind`

| kind | 含义 | 默认隐藏 | 参与弱密码 / 重复检查 |
|---|---|---|---|
| `text` | 文本 | | |
| `password` | 密码 | ✓ | ✓ |
| `secret` | 隐藏文本（CVV、PIN、API Secret） | ✓ | |
| `url` | 网址 | | |
| `email` | 邮箱 | | |
| `phone` | 电话 | | |
| `date` | 日期，`YYYY-MM-DD` | | |
| `monthYear` | 年月，`YYYY-MM`（卡片有效期） | | |
| `totp` | 一次性验证码：Base32 密钥或 `otpauth://` 链接 | | |
| `multiline` | 多行文本（如 SSH 私钥） | ✓ | |

- 安全报告检查条目里**每个分组**的全部 `password` 字段。
- **搜索**只匹配标题、列表副标题、标签、`url` 和 `email`，不匹配任何机密字段。

### 5.5 索引 `index`

```json
{ "items": { "<id>": <rev>, … }, "updated": 1761400000000 }
```

- 打开时必须核对：`items` 数组里每一条的 `id` 和 `rev` 都要和索引一致，数量也要相同。不一致就说明有条目被删除、回退或替换，按篡改处理。
- 索引的结构由格式版本决定，每次保存都完整重写，不保留不认识的键。

### 5.6 向前兼容

- 读到不认识的 JSON 键要原样保留，写回时不能丢。范围包括：账户文件顶层、保险库文件顶层、元数据、条目、分组、字段。
- 不认识的 `type` 没有模板，按原样显示；不认识的 `kind` 按 `text` 显示。都不能报错。

## 6. 修改与墓碑

- 条目的 `id` 创建后不变，每次修改 `rev` 加 1，同时更新 `modified`。
- **删除**不从文件里移除，而是写一条 `deleted: true` 的墓碑：
  - 清空 `title`、`tags`、`notes`、`sections`、`iconData`、`iconHost` 和不认识的键，`favorite` 置为 false；
  - `rev` 加 1；
  - 墓碑保留 90 天后可以清理。
- **在保险库之间搬移**：原保险库里删除（留墓碑），目标保险库里用**同一个 id** 新建（`rev` 从 1 开始）。目标里如果有同 id 的旧墓碑，被新条目取代。
- **没改过的条目**保存时沿用原来的 nonce 和密文，同一个 `id` + `rev` 的密文永远不变，同步时比较起来很容易。

## 7. 测试向量（`spec/test-vectors/`）

每端的测试都必须读这些文件并全部通过：

| 文件 | 内容 |
|---|---|
| `totp.json` | RFC 6238 附录 B 的 SHA-1 向量 |
| `kdf.json` | 固定主密码和 salt 算出的 KEK，含中文、emoji，以及 NFC 组合和分解两种写法（必须得到同一个 KEK） |
| `example/` | 一个完整的示例数据目录（虚构数据）：账户文件和两个保险库（「个人」「工作」），覆盖每种已知类型、每种字段类型、多个分组、墓碑、跨保险库搬移、不认识的类型和键。`expected.json` 是主密码、一个错误密码，以及解开后应得到的明文（保险库按 `order` 排，条目 = 明文字段 + `id` + `rev`，按文件顺序） |
| `secret-key/` | Secret Key：`kdf.json`（主密码 + salt + Secret Key → Argon2id 输出、KEK、`secretKeyId`）；`text.json`（写法的编码和解析，含大小写、省略前缀、O/I/L 替换和各种不合法的写法）；`account.1melon` + `expected.json`（一个 v2 账户文件，期望解开得到的 AK，以及错误的 Secret Key、错误的主密码各会得到什么错误）；`tamper/`（用正确的主密码和 Secret Key 打开，每个都必须拒绝：v2 写成 `none`、v2 没有 `secretKeyId`、改 `secretKeyId`、降级成 v1、版本写成 3）。生成：`MELON_REGEN_VECTORS=1 swift test --package-path apps/desktop --filter testRegenerateSecretKeyVectors`，只重写这个目录 |
| `tamper/` | 15 个篡改过的文件和 `cases.json`（每个文件是账户还是保险库、期望的错误种类）：KDF 降级或调高、版本更新（账户写成版本 3、保险库写成版本 2）、v1 要求 Secret Key、改 accountId；保险库属于别的账户、改 vaultId、换成别的保险库的 wrappedKey、删条目、把条目换回旧版本、改 rev、互换条目密文、翻转一位、互换索引和元数据。每个都必须拒绝打开 |

- 向量由桌面端生成：`MELON_REGEN_VECTORS=1 swift test --package-path apps/desktop --filter testRegenerateVectors`。生成后提交；定稿后哪一端都**不能**为了让测试通过去改向量，除非同时升格式版本。
- `spec/tools/verify-vectors.py` 是第二个参考实现：只按本文用 Python 写成（`cryptography` 库，底层是 OpenSSL），正常路径和篡改用例都校验，用来证明本文足够让另一种语言独立实现。

## 8. 云同步（规划，未实现）

方向：各端把**加密后的文件**原样同步到阿里云 OSS 的私有桶，服务端和 OSS 都只见密文。格式已经为此做了下面这些准备：

- **同步单位是文件**：`account.1melon` 和每个 `vaults/<vaultId>.1melon` 各是一个对象。是否有变化，先比较 OSS 的 ETag 或内容哈希，一样就跳过。
- **哈希不一样时要合并，不能直接覆盖**：两台设备各改了一点，两边的哈希都会变。合并按条目进行，`id` 相同时 `rev` 大的胜出；`rev` 相同但内容不同时，`modified` 晚的胜出，另一份另存为冲突副本。合并满足交换律，所以就算上传时有竞争，下次同步也能收敛。
- **防回退**：各端在本地记住每个保险库最近一次见过的索引 `updated` 和各条目的 `rev`。云端拿到的文件如果比本地旧，就不接受。这同时补上了「整个文件被换成旧版本本地发现不了」这个缺口。
- **Secret Key（已定，见 §2、§3.4）**：密文放到云上之后，主要威胁是有人拿到密文后离线暴力破解主密码。参照 1Password：每个账户再有一把 128 位的 Secret Key，只存在设备上，KEK 由 Argon2id 输出和它一起经 HKDF 得到，账户文件写成 v2。这样只拿到云端密文没有用。开启同步时必须先启用；不同步的账户可以保持 v1。

**已知限制**

- **元数据泄露**：保险库数量、条目数量、id 和修订号是明文。对自用场景来说可以接受，换来的是能按条目合并。
- **整个文件回退**：不同步时，本地发现不了，原因是旧文件本身是合法的。§8 的「防回退」在同步时补上。

## 附录 A：各类型模板

| 类型 | 分组（标题）：字段（类型） |
|---|---|
| `login` | （无标题）：用户名（text）、密码（password）、网站（url）<br>两步验证：一次性验证码（totp） |
| `card` | （无标题）：持卡人（text）、卡号（text，等宽）、有效期（monthYear）、CVV（secret）、PIN（secret） |
| `note` | 没有分组，内容写在 `notes` |
| `identity` | （无标题）：姓名（text）、证件号码（text，等宽）、出生日期（date）<br>联系方式：电话（phone）、邮箱（email）、地址（text） |
| `ssh` | （无标题）：主机（text，等宽）、用户名（text）、私钥（multiline）、指纹（text，等宽） |
| `api` | （无标题）：服务（text）、Key ID（text，等宽）、Secret（secret） |
| `wifi` | （无标题）：网络名称（text）、密码（password）、安全类型（text） |

保存时去掉空字段，以及因此变空的分组。

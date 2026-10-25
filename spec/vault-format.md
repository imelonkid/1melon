# 保险库文件格式（格式版本 1）

> 状态：**已实现，待定稿**。桌面端 `MelonCore` 已实现，测试向量已生成，并用独立的 Python 实现（`spec/tools/verify-vectors.py`）交叉验证过。首个正式版发布前定稿；定稿后任何改动都要升 `version`，并保证新版客户端能读旧文件。

这是各端（macOS、鸿蒙）之间唯一的契约。各端代码不共享，只要都按本文读写、都通过 `spec/test-vectors/` 就算对齐。

## 1. 设计目标

- **只用两端都能实现的原语**：Argon2id v1.3（RFC 9106）、AES-256-GCM、HMAC-SHA1/SHA-256。桌面端的 Argon2id 用官方参考实现的 C 源码（`apps/desktop/Sources/CArgon2`），鸿蒙端可以用 NDK 编译同一份；任何符合 RFC 9106 的实现（libsodium、OpenSSL 3.2+）算出的结果都一样。
- **改主密码不用重新加密全部条目**：主密码只用来包装一把随机的保险库密钥。
- **为以后的同步预留**：条目单独加密，带 id 和修订号，能按条目合并；删除留墓碑。
- **能发现篡改**：每段密文都用 AEAD 认证并绑定上下文，另有加密索引，能发现条目被删除或回退。
- 平台特有的解锁方式（Touch ID + 钥匙串、鸿蒙生物识别 + HUKS）**不进文件**，只在各端本地缓存保险库密钥。

## 2. 密钥层级

```
主密码 ──Argon2id(salt, 参数)──▶ KEK（32 字节，只在内存）
                                   │ AES-256-GCM 包装
                                   ▼
                 VK 保险库密钥（32 字节随机，生成后不变）
                                   │ AES-256-GCM
                     ┌─────────────┼─────────────┐
                   索引          条目 1 … n       元数据
```

- **KEK**：密钥加密密钥。主密码先做 Unicode NFC 规范化，再按 UTF-8 编码，然后进 Argon2id。
- **VK**：创建保险库时由系统 CSPRNG 生成。改主密码 = 用新 KEK 重新包装 VK，条目密文不变。
- **本地快速解锁**：解锁成功后，各端可以把 VK 存进平台安全存储（macOS 用钥匙串，访问控制设为 `biometryCurrentSet`；鸿蒙用 HUKS 加生物识别）。这部分不属于文件格式。

## 3. 文件

- 文件名 `vault.1melon`，内容是 UTF-8 JSON。二进制字段一律用标准 Base64（带 `=` 填充）；整数字段（`version`、`rev`、KDF 参数、时间戳）写成 JSON 整数。
- 写文件必须原子写入：先写同目录的临时文件，fsync，再 rename。文件权限 0600，所在目录 0700。

```json
{
  "format": "1melon-vault",
  "version": 1,
  "vaultId": "8c0e…（UUID v4，小写）",
  "kdf": {
    "alg": "argon2id13",
    "memKiB": 262144,
    "iterations": 3,
    "parallelism": 1,
    "salt": "<16 字节>"
  },
  "wrappedKey": { "nonce": "<12 字节>", "ct": "<32 字节 VK 的密文 + 16 字节 tag>" },
  "index":   { "nonce": "…", "ct": "…" },
  "meta":    { "nonce": "…", "ct": "…" },
  "items": [
    { "id": "…UUID…", "rev": 3, "nonce": "…", "ct": "…" }
  ]
}
```

### KDF 参数

- `alg` 固定为 `argon2id13`（Argon2id v1.3，RFC 9106），输出 32 字节；不用 secret 和 associated data。
- `parallelism` 固定为 1（libsodium 只支持 1，固定下来各端都好实现）。`salt` 16 字节，由 CSPRNG 生成。
- 默认值是 **256 MiB、3 次迭代**。实测在 Apple 芯片的 Mac 上（release 构建）约 0.3 秒；鸿蒙手机待实测，目标 1 秒左右。参数随文件保存，以后可以提高，改主密码时顺带升级。
- **打开前先校验参数，校验不过就不派生密钥**：
  - 内存 < 64 MiB 或迭代 < 2：拒绝，防止有人改文件头降低强度；
  - 内存 > 1 GiB 或迭代 > 10：拒绝，防止被改成把机器卡死的参数；
  - `alg`、`parallelism` 或 `salt` 长度不对：拒绝。

## 4. 加密与认证上下文（AAD）

所有密文都是 AES-256-GCM，nonce 12 字节，每次加密都用 CSPRNG 新生成。`ct` = 密文 ‖ 16 字节 tag。

每段密文都用 AAD 绑定它在文件里的位置，防止把密文挪到别处用：

| 段 | 密钥 | AAD（UTF-8 字符串） |
|---|---|---|
| `wrappedKey` | KEK | `1melon:v1:key:<vaultId>` |
| `index` | VK | `1melon:v1:index:<vaultId>` |
| `meta` | VK | `1melon:v1:meta:<vaultId>` |
| `items[i]` | VK | `1melon:v1:item:<vaultId>:<id>:<rev>` |

`wrappedKey` 解密失败就是主密码错误。改了 `vaultId` 或 `salt` 也会表现成这样，因为算出来的 KEK 或 AAD 对不上。其余任何一段解密失败都视为文件损坏或被篡改：整体拒绝打开，不能只跳过那一条。

### 打开时的检查顺序

1. 解析 JSON，`format` 必须是 `1melon-vault`；`version` 比自己支持的大，就提示升级客户端，不往下解析。
2. `vaultId` 必须是小写 UUID；KDF 参数按上一节校验；`wrappedKey.ct` 必须是 48 字节。
3. 派生 KEK，解开 `wrappedKey`，失败就是**主密码错误**。
4. 解开 `index` 和 `meta`；逐条解开条目（每条的 `id` 必须是小写 UUID、`rev` ≥ 1、`id` 不重复），再和索引核对。任何一步失败都是**已篡改**。

各端给用户的提示至少要区分这五种：不是保险库文件、需要升级、文件头参数不安全、主密码错误、文件损坏或被篡改。

## 5. 明文结构

### 索引 `index`

```json
{ "items": { "<id>": <rev>, … }, "updated": 1761400000000 }
```

索引的结构由格式版本决定，每次保存都完整重写，不保留不认识的键。

打开时必须核对：`items` 数组里每一条的 `id` 和 `rev` 都要和索引一致，数量也要相同。不一致就说明有条目被删除、回退或替换，按篡改处理。

### 元数据 `meta`

```json
{ "name": "个人保险库", "created": 1761400000000 }
```

只放要跟着保险库走的东西。界面设置（主题、自动锁定时间等）属于各端本地，不放这里。

### 条目

```json
{
  "type": "login",
  "title": "GitHub",
  "icon": "github",
  "favorite": true,
  "tags": ["开发"],
  "notes": "",
  "fields": [
    { "id": "f1", "label": "用户名", "kind": "text", "value": "…" },
    { "id": "f2", "label": "密码", "kind": "password", "value": "…" },
    { "id": "f3", "label": "网站", "kind": "url", "value": "github.com" },
    { "id": "f4", "label": "两步验证密钥", "kind": "totp", "value": "otpauth://… 或 Base32" }
  ],
  "created": 1614643200000,
  "modified": 1758153600000,
  "deleted": false
}
```

- `type` 只能是：`login`、`card`、`note`、`identity`、`ssh`、`api`、`wifi`。
- `kind` 只能是：`text`、`password`、`secret`、`mono`、`url`、`totp`、`multiline`。
  - `password`：参与强度检查和重复检查；
  - `secret`：默认隐藏，但不参与那两项检查（如 CVV、PIN、API Secret）；
  - `mono`：等宽显示；
  - `totp`：值是 Base32 密钥或 `otpauth://` 链接。
- `icon` 是可选的图标名，取自固定集合，各端自己映射成图标资源，未知的名字就显示类型默认图标。
- 时间一律是 UTC 毫秒时间戳（整数）。
- `label` 是显示用的，各端识别字段靠 `kind`，不靠 `label` 的文字。
- **向前兼容**：读到不认识的 JSON 键要原样保留，写回时不能丢。不认识的 `type` 或 `kind` 按 `text` 显示，不能报错。

## 6. 为同步预留

当前不做同步，但格式按下面的约定写，以后通过文件同步（iCloud Drive、WebDAV 等）合并时不用改格式：

- 条目的 `id` 创建后不变，每次修改 `rev` 加 1，同时更新 `modified`。
- 删除不从文件里移除，而是写一条 `deleted: true` 的墓碑：清空 `title`、`icon`、`tags`、`notes`、`fields` 和不认识的键，`favorite` 置为 false，`rev` 加 1。墓碑保留 90 天后可以清理。
- 没改过的条目保存时沿用原来的 nonce 和密文，同一个 `id` + `rev` 的密文永远不变，以后同步时比较起来很容易。
- 合并规则（以后实现）：按 `id` 逐条比较，`rev` 大的胜出；`rev` 相同但内容不同时，`modified` 晚的胜出，另一份另存为冲突副本。

**已知限制**

- **元数据泄露**：条目数量、id 和修订号是明文。对自用场景来说可以接受，换来的是能按条目合并。
- **整个文件回退发现不了**：用一份完整的旧文件替换新文件，旧文件本身是合法的，本地无从判断。真要防这个，得由各端在本地记住最近一次见过的索引 `updated` 时间，这个属于各端本地的事，不进格式。

## 7. 测试向量（`spec/test-vectors/`）

每端的测试都必须读这些文件并全部通过：

| 文件 | 内容 | 状态 |
|---|---|---|
| `totp.json` | RFC 6238 附录 B 的 SHA-1 向量 | 已有 |
| `kdf.json` | 固定主密码和 salt 算出的 KEK，含中文、emoji，以及 NFC 组合和分解两种写法（必须得到同一个 KEK） | 已有 |
| `vault-v1.1melon` + `vault-v1.json` | 一个完整的示例保险库（虚构数据：每种已知类型、TOTP、墓碑、不认识的类型和键）、它的主密码和一个错误密码，以及解开后应得到的明文（条目 = 明文字段 + `id` + `rev`，按文件顺序） | 已有 |
| `tamper/` | 10 个篡改过的文件和 `cases.json`（每个文件期望的错误种类）：KDF 降级或调高、版本更新、删条目、把条目换回旧版本、改 rev、互换条目密文、翻转一位、互换索引和元数据、改 vaultId。每个都必须拒绝打开 | 已有 |

- 向量由桌面端生成：`MELON_REGEN_VECTORS=1 swift test --package-path apps/desktop --filter testRegenerateVectors`。生成后提交；之后哪一端都**不能**为了让测试通过去改向量，除非同时升格式版本。
- `spec/tools/verify-vectors.py` 是第二个参考实现：只按本文用 Python 写成（`cryptography` 库，底层是 OpenSSL），用来证明本文足够让另一种语言独立实现。

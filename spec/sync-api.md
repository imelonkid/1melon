# 同步协议与服务端 API（协议版本 1）

> 状态：**已确认（2026-10-27），服务端已实现**（`apps/server`，端到端测试覆盖注册、登录、文件、冲突、删除、换登录密钥、配额、停用、限流）；桌面端已有登录密钥、同步引擎和网络层（`MelonCore/LoginKey.swift`、`SyncEngine.swift`、`VaultMerge.swift`、`SyncClient.swift`、`SyncSetup.swift`，对真实服务端的端到端测试 `SyncServerE2ETests`），界面还没接。各端（macOS、鸿蒙）和服务端只按本文对齐。

## 1. 原则

- **服务端只见密文**：存的是各端上传的 `account.1melon` 和 `vaults/<vaultId>.1melon`，原样保存，不解密，也没有能解密的密钥。
- **同步要求账户带 Secret Key**（账户文件 v2，见 `vault-format.md` §3.4）。拿到服务端全部数据的人，要同时猜中主密码和 128 位的 Secret Key 才能解开，不可行。
- **服务端负责「谁先写谁赢」**：每个文件有一个服务端修订号 `rev`，上传时必须带上自己见过的 `rev`，不一致就拒绝（`412`），客户端合并后重传。合并在客户端做（§6）。
- **客户端里没有任何云凭证**：只有自己的登录密钥（§3），服务端用自己的凭证存数据。
- 只靠邀请码注册（§4.1），陌生人进不来；管理员可以封禁账户或设备。

## 2. 基本约定

- 基础地址：`https://1melon.melonkid.cn/api/v1`（客户端从设置码里读，§7）。只走 HTTPS（客户端只对本机回环地址 `127.0.0.1` / `localhost` / `::1` 放行 http，开发和测试用）；不跟随重定向。
- 请求和响应都是 UTF-8 JSON；二进制字段用标准 Base64（带 `=`）。文件内容的上传和下载是原始字节（`application/octet-stream`），不做 Base64。
- 认证：`Authorization: Bearer <会话令牌>`（§3.2）。没有标注「不用登录」的接口都要。
- 追踪号：客户端每个请求带 `X-Request-Id`（随机），服务端原样回传；没有就自己生成。
- 错误响应：

  ```json
  { "error": { "code": "conflict", "message": "给人看的说明" }, "traceId": "…" }
  ```

  | HTTP | `code` | 含义 |
  |---|---|---|
  | 400 | `bad_request` | 参数或格式不对 |
  | 401 | `unauthorized` | 没登录、令牌过期或无效、签名不对 |
  | 403 | `forbidden` | 账户或设备被封禁、邀请码无效或已用 |
  | 404 | `not_found` | 文件不存在 |
  | 409 | `exists` | 账户已经注册过 |
  | 412 | `conflict` | `If-Match` 的修订号不是最新（响应里带当前的 `rev`） |
  | 413 | `too_large` | 单个文件超过上限，或账户超过配额 |
  | 429 | `rate_limited` | 太频繁，带 `Retry-After` |
  | 5xx | `internal` | 服务端问题，客户端稍后重试 |

- 上限（服务端配置，初始值）：单个文件 16 MiB，每个账户合计 128 MiB，每个账户 50 个文件。

## 3. 身份认证

### 3.1 登录密钥

登录密钥和加密用的 KEK 分开派生，两者互相推不出来：

```
authSeed = HKDF-SHA256(IKM = Argon2id 输出, salt = Secret Key 的 16 字节,
                       info = "1melon:v2:auth:<accountId>", L = 32)
登录私钥 = Ed25519 私钥（种子 = authSeed）     登录公钥 = 对应的 32 字节公钥
```

- Argon2id 输出就是 `vault-format.md` §2 里进 HKDF 之前的那 32 字节，参数取账户文件的 `kdf`。
- Ed25519 按 RFC 8032（macOS 用 CryptoKit `Curve25519.Signing`，鸿蒙用 cryptoFramework 的 Ed25519，服务端用 Go 标准库）。测试向量：`spec/test-vectors/sync-auth/`（`vault-format.md` §7），桌面端、服务端和 `verify-vectors.py` 都读它。
- 服务端只存**登录公钥**。拖库拿到公钥，也要同时猜中主密码和 Secret Key 才能验证一次猜测。
- 新设备只要有主密码、Secret Key、`accountId` 就能算出登录私钥，不需要别的设备批准。它在登录之前还拿不到账户文件，所以 `kdf` 参数由登录挑战接口返回（§3.2）。
- **改主密码**：`kdf.salt` 变了，登录密钥跟着变。新的登录公钥随新的账户文件一起上传（§5.3），旧会话照常有效，直到过期。

### 3.2 挑战签名 → 会话令牌

```
POST /auth/challenge        （不用登录）
  请求 { "accountId": "…" }
  响应 { "challenge": "<Base64>", "expiresAt": 1761400000000,
         "kdf": { …账户文件里的 kdf… } }

POST /auth/session          （不用登录）
  请求 { "accountId": "…", "challenge": "<上一步的原样>",
         "signature": "<Ed25519 签名，64 字节>",
         "device": { "id": "<设备 UUID>", "name": "melonkid 的 MacBook Pro", "platform": "macos" } }
  响应 { "token": "…", "expiresAt": …, "deviceId": "…" }
```

- 签名的消息：UTF-8 字符串 `1melon:v1:auth:<accountId>:<challenge 的 Base64 原文>`。
- `challenge` 由服务端生成、自带过期时间（2 分钟）和服务端签名，服务端不用记状态；每个挑战只能换一次会话（服务端在过期前记住用过的挑战）。
- 账户不存在时，挑战接口照常返回（`kdf` 用由 `accountId` 确定性生成的假参数），不暴露「这个账户是否存在」。
- 会话令牌有效 1 小时，过期后重新走一遍挑战。设备 `id` 由客户端生成并保存在本机 `device/` 下；第一次出现的设备自动登记。
- 账户或设备被封禁：`/auth/session` 返回 `403`，已发出的令牌立即失效。

## 4. 账户

### 4.1 注册

```
POST /accounts              （不用登录）
  请求 { "inviteCode": "…", "accountId": "…", "authPublicKey": "<32 字节>",
         "account": "<account.1melon 的 Base64>" }
  响应 201 { "accountId": "…" }
```

- 邀请码一次性，由管理员发（§8）。用过、过期或不存在：`403`。
- `account` 必须是 v2 账户文件，`accountId` 与请求一致；服务端只读它的公开字段（`format`、`version`、`accountId`、`kdf`、`secretKey`），不解密。它成为这个账户的第一个文件（`rev` = 1）。
- 同一个 `accountId` 已注册：`409`。

### 4.2 设备

```
GET    /devices             响应 { "devices": [ { "id", "name", "platform", "createdAt", "lastSeenAt", "current": true } ] }
DELETE /devices/{id}        移除一台设备：它的会话立即失效，下次登录会重新登记（要防它，就改主密码）
```

## 5. 文件

文件名只允许两种：`account.1melon`、`vaults/<小写 UUID>.1melon`。

### 5.1 列表

```
GET /files
  响应 { "files": [ { "name": "vaults/…1melon", "rev": 7, "sha256": "<hex>", "size": 12345,
                      "updatedAt": …, "deleted": false } ],
         "cursor": "…" }
```

- `rev` 是服务端给每个文件的修订号，每次写入加 1，和条目里的 `rev` 无关。
- 包含删除标记（`deleted: true`，见 5.4），其他设备据此删掉本地的保险库。
- `GET /files?since=<cursor>` 只返回上次之后变过的文件；客户端平时用它轮询。

### 5.2 下载

```
GET /files/{name}           响应 200，原始字节；ETag: "<rev>"；X-Content-SHA256: <hex>
```

### 5.3 上传

```
PUT /files/{name}           原始字节
  If-Match: "<自己见过的 rev>"    更新已有文件
  If-None-Match: *               新建（这个名字从没出现过，或已删除）
  响应 200 { "rev": 8, "sha256": "…" }
  响应 412 { "error": { "code": "conflict" }, "rev": 9 }   别人先写了：下载最新的，合并后再传
```

- 两个头都没有：`400`。服务端保证同一个文件同一时刻只有一次写入成功。
- 服务端做最少的检查，不解密：内容是 JSON，`format` 是 `1melon-account` 或 `1melon-vault`，和文件名对得上，`accountId` 是当前账户，保险库的 `vaultId` 和文件名一致。
- **上传 `account.1melon`** 还要带：
  - `X-Auth-Public-Key: <Base64>`：这份账户文件对应的登录公钥；
  - `X-Auth-Proof: <Base64>`：用这把新私钥对 `1melon:v1:rotate:<accountId>:<文件的 sha256 hex>` 的签名。

  服务端在同一个事务里换上新公钥，之后用旧主密码就登录不了。新文件必须仍是 v2（同步账户不能停用 Secret Key）。

### 5.4 删除

```
DELETE /files/vaults/{vaultId}.1melon     If-Match: "<rev>"     响应 200 { "rev": … }
```

- 只能删保险库文件，不能删账户文件。服务端留删除标记（`deleted: true`，`rev` 加 1），内容清空；之后可以用 `If-None-Match: *` 以同名重建。

## 6. 客户端同步流程

1. **时机**：解锁后、每次保存后（延迟几秒合并成一次）、每 5 分钟、窗口切回前台时。
2. `GET /files?since=…`，对每个变过的文件：
   - 本地没改过：下载，按 `vault-format.md` 的检查顺序打开，通过就替换本地文件。
   - 本地也改过：下载远端，**按条目合并**（`vault-format.md` §8：`id` 相同时 `rev` 大的胜出；`rev` 相同而内容不同时 `modified` 晚的胜出，另一份另存为冲突副本），写本地，再用远端的 `rev` 作 `If-Match` 上传合并结果。
3. 本地改过、远端没变：直接上传。`412` 就回到第 2 步。
4. **防回退**：本地记住每个文件最后见过的服务端 `rev` 和保险库索引里的 `updated`。拿到的文件比记住的旧，就拒绝，并提示「云端数据比本机旧，可能被篡改」。
5. **账户文件冲突**（两台设备都改了主密码）：以先上传成功的为准；后到的设备下载新账户文件后，要求用户输入新主密码。
6. 同步状态放在本机 `device/sync.json`，只属于这台设备，不同步、不备份：
   ```json
   { "format": "1melon-device-sync", "version": 1, "server": "https://…", "accountId": "…", "deviceId": "…",
     "cursor": "…",
     "files": { "vaults/<id>.1melon": { "rev": 7, "sha256": "<hex>", "updated": 1761400000000 } } }
   ```
   - `sha256` 是最后一次同步时本机文件（也就是云端那份）的哈希，本机文件和它不一样就是「本机改过」；
   - `updated` 是保险库索引的 `updated`，防回退用；云端已删除的文件记 `"deleted": true`。
   - 有文件没同步成（冲突重试用完、被判定回退或打不开）时不推进 `cursor`，下一轮还能从列表里看到它。
7. 写本机文件前要确认它还是读到时的样子；同步途中界面又保存过，就跳过这个文件，下一轮再同步，不能覆盖掉。

## 7. 设置码

新设备加入用的一段文字（以后也可以显示成二维码），里面有 Secret Key，**和主密码一样要保密**：

```
1MELON-SETUP1:<Base64url（不带填充）的 JSON>
JSON：{ "server": "https://1melon.melonkid.cn", "accountId": "…", "secretKey": "M1-…" }
```

- 已登录的设备在「设置 → 同步」里显示；「应急资料」页把它和说明一起打印出来。
- 新设备：首次启动选「加入已有账户」→ 粘贴设置码 → 输主密码 → 登录、下载账户文件和全部保险库。

## 8. 管理（不对公网开放）

服务端二进制自带命令行，在服务器上通过部署入口执行，不提供网页后台：

```
1melon-server invite create [--note 给谁] [--expires 7d]    生成一次性邀请码
1melon-server invite list
1melon-server account list                                   账户 id、注册时间、用量、设备数（看不到内容）
1melon-server account disable <accountId>                    封禁：会话立即失效
1melon-server account enable  <accountId>
```

## 9. 健康检查

```
GET /health                 （不用登录，不在 /api/v1 下）
  响应 { "ok": true, "version": "server-v0.1.0", "apiVersion": 1, "minClient": { "desktop": "0.1.0" } }
```

- `version` 是镜像里烘进去的 `APP_VERSION`（= 发布 tag）；门户发布时靠它确认上线的是哪个版本。
- `ok` 为真表示能正常服务：数据库能读写。
- `minClient`：各端最低版本。只有新版客户端发布之后才提高它，低于它的客户端提示必须升级。

import Crypto
import Foundation

/// 打开保险库失败的原因。界面按种类提示，不要把内部细节展示给用户。
public enum VaultError: Error, Equatable {
    /// 不是 1Melon 保险库，或 JSON 结构不对
    case invalidFormat(String)
    /// 文件格式比这个客户端新，要先升级客户端
    case unsupportedVersion(Int)
    /// KDF 参数低于下限或超出上限（可能被改过文件头）
    case unsafeKDFParameters(String)
    /// 主密码错误
    case wrongPassword
    /// 认证失败或索引对不上：文件损坏或被篡改。整体拒绝打开，不跳过单条
    case tampered(String)
}

/// 文件头里的 KDF 参数（spec §3「KDF 参数」）。
public struct KDFParameters: Codable, Equatable, Sendable {
    public static let algorithm = "argon2id13"
    public static let saltLength = 16
    public static let memoryKiBRange: ClosedRange<UInt32> = 65_536...1_048_576   // 64 MiB…1 GiB
    public static let iterationsRange: ClosedRange<UInt32> = 2...10

    public var alg: String
    public var memKiB: UInt32
    public var iterations: UInt32
    public var parallelism: UInt32
    public var salt: Data

    /// 新建保险库和改主密码时用的默认值：Mac 上约 0.3 秒（release 构建实测）。
    public static func defaults() -> KDFParameters {
        KDFParameters(alg: algorithm, memKiB: 262_144, iterations: 3, parallelism: 1, salt: randomBytes(saltLength))
    }

    /// 读文件时先校验参数再派生密钥：太低说明可能被降级，太高会把机器卡死，都拒绝。
    public func validate() throws {
        guard alg == Self.algorithm else { throw VaultError.unsafeKDFParameters("不支持的算法 \(alg)") }
        guard parallelism == 1 else { throw VaultError.unsafeKDFParameters("parallelism 必须是 1") }
        guard salt.count == Self.saltLength else { throw VaultError.unsafeKDFParameters("salt 必须是 16 字节") }
        guard Self.memoryKiBRange.contains(memKiB) else { throw VaultError.unsafeKDFParameters("内存参数 \(memKiB) KiB 超出范围") }
        guard Self.iterationsRange.contains(iterations) else { throw VaultError.unsafeKDFParameters("迭代次数 \(iterations) 超出范围") }
    }
}

/// 一段 AES-256-GCM 密文：`ct` = 密文 ‖ 16 字节 tag。
struct Sealed: Codable, Equatable, Sendable {
    var nonce: Data
    var ct: Data
}

struct SealedItem: Codable, Equatable, Sendable {
    var id: String
    var rev: Int
    var nonce: Data
    var ct: Data
}

struct VaultIndex: Codable, Equatable {
    var items: [String: Int]
    var updated: Int64
}

/// 文件的顶层结构（spec §3）。不认识的顶层键原样保留。
struct VaultFile {
    static let formatName = "1melon-vault"
    static let currentVersion = 1

    var format = formatName
    var version = currentVersion
    var vaultId: String
    /// 属于哪个账户：保险库密钥由这个账户的 AK 包装
    var accountId: String
    var wrappedKey: Sealed
    var index: Sealed
    var meta: Sealed
    var items: [SealedItem]
    var extras: [String: JSONValue] = [:]
}

extension VaultFile: Codable {
    private static let known: Set<String> = ["format", "version", "vaultId", "accountId", "wrappedKey", "index", "meta", "items"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        format = try c.decode(String.self, forKey: AnyKey("format"))
        version = try c.decode(Int.self, forKey: AnyKey("version"))
        guard format == Self.formatName else { throw VaultError.invalidFormat("不是 1Melon 保险库") }
        // 先看版本：新版本的其余结构可能不一样，不往下解析
        guard version <= Self.currentVersion else { throw VaultError.unsupportedVersion(version) }
        guard version == Self.currentVersion else { throw VaultError.invalidFormat("格式版本 \(version) 无效") }
        vaultId = try c.decode(String.self, forKey: AnyKey("vaultId"))
        accountId = try c.decode(String.self, forKey: AnyKey("accountId"))
        wrappedKey = try c.decode(Sealed.self, forKey: AnyKey("wrappedKey"))
        index = try c.decode(Sealed.self, forKey: AnyKey("index"))
        meta = try c.decode(Sealed.self, forKey: AnyKey("meta"))
        items = try c.decode([SealedItem].self, forKey: AnyKey("items"))
        extras = try c.extras(excluding: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extras)
        try c.encode(format, forKey: AnyKey("format"))
        try c.encode(version, forKey: AnyKey("version"))
        try c.encode(vaultId, forKey: AnyKey("vaultId"))
        try c.encode(accountId, forKey: AnyKey("accountId"))
        try c.encode(wrappedKey, forKey: AnyKey("wrappedKey"))
        try c.encode(index, forKey: AnyKey("index"))
        try c.encode(meta, forKey: AnyKey("meta"))
        try c.encode(items, forKey: AnyKey("items"))
    }
}

/// 解锁后的保险库。所有明文只在内存里；`serialized()` 产出的是加密后的文件内容。
public struct UnlockedVault: Sendable {
    public let vaultId: String
    public let accountId: String
    public var meta: VaultMeta
    /// 文件里的全部条目，包括墓碑（`deleted == true`）
    public private(set) var items: [VaultItem]

    private var keyBox: SendableKey
    private var vaultKey: SymmetricKey { keyBox.key }
    private var wrappedKey: Sealed
    /// 没改过的条目沿用原来的密文（同一 id + rev 的密文不变，同步时容易比对）
    private var sealedCache: [String: SealedItem]
    private var fileExtras: [String: JSONValue]

    /// 没被删除的条目
    public var activeItems: [VaultItem] { items.filter { !$0.deleted } }

    // MARK: 新建与打开

    /// 新建保险库：随机生成保险库密钥 VK，用账户密钥 AK 包装。
    public static func create(in account: UnlockedAccount, meta: VaultMeta) throws -> UnlockedVault {
        let vaultId = newID()
        let vaultKey = SymmetricKey(size: .bits256)
        let wrapped = try seal(vaultKey.withUnsafeBytes { Data($0) }, key: account.accountKey,
                               aad: AAD.vaultKey(account.accountId, vaultId))
        return UnlockedVault(
            vaultId: vaultId, accountId: account.accountId, meta: meta, items: [],
            keyBox: SendableKey(vaultKey), wrappedKey: wrapped, sealedCache: [:], fileExtras: [:]
        )
    }

    /// 用账户打开。保险库属于别的账户时抛 `.invalidFormat`；解不开或对不上抛 `.tampered`。
    public static func open(_ data: Data, account: UnlockedAccount) throws -> UnlockedVault {
        let file = try decodeFile(data)
        guard file.accountId == account.accountId else { throw VaultError.invalidFormat("这个保险库不属于当前账户") }
        let keyBytes: Data
        do {
            keyBytes = try unseal(file.wrappedKey, key: account.accountKey, aad: AAD.vaultKey(file.accountId, file.vaultId))
        } catch {
            throw VaultError.tampered("保险库密钥无法解开")
        }
        return try decrypt(file, vaultKey: SymmetricKey(data: keyBytes))
    }

    static func decodeFile(_ data: Data) throws -> VaultFile {
        let file: VaultFile
        do {
            file = try JSONDecoder().decode(VaultFile.self, from: data)
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.invalidFormat("文件结构无法解析")
        }
        guard isLowercaseUUID(file.vaultId), isLowercaseUUID(file.accountId) else {
            throw VaultError.invalidFormat("vaultId 或 accountId 不是小写 UUID")
        }
        guard file.wrappedKey.ct.count == 32 + 16 else { throw VaultError.tampered("wrappedKey 长度不对") }
        return file
    }

    private static func decrypt(_ file: VaultFile, vaultKey: SymmetricKey) throws -> UnlockedVault {
        let decoder = JSONDecoder()
        let index: VaultIndex
        let meta: VaultMeta
        do {
            index = try decoder.decode(VaultIndex.self, from: unseal(file.index, key: vaultKey, aad: AAD.index(file.vaultId)))
            meta = try decoder.decode(VaultMeta.self, from: unseal(file.meta, key: vaultKey, aad: AAD.meta(file.vaultId)))
        } catch {
            throw VaultError.tampered("索引或元数据无法解密")
        }

        // spec §5「索引」：数量、id、rev 都要和索引一致，否则有条目被删除、回退或替换
        guard index.items.count == file.items.count else { throw VaultError.tampered("条目数量与索引不一致") }
        var items: [VaultItem] = []
        var cache: [String: SealedItem] = [:]
        for sealed in file.items {
            guard isLowercaseUUID(sealed.id), sealed.rev >= 1 else { throw VaultError.tampered("条目 id 或 rev 无效") }
            guard cache[sealed.id] == nil else { throw VaultError.tampered("条目 id 重复") }
            guard index.items[sealed.id] == sealed.rev else { throw VaultError.tampered("条目与索引不一致") }
            var item: VaultItem
            do {
                let plain = try unseal(Sealed(nonce: sealed.nonce, ct: sealed.ct), key: vaultKey,
                                       aad: AAD.item(file.vaultId, sealed.id, sealed.rev))
                item = try decoder.decode(ItemPlaintext.self, from: plain).item
            } catch {
                throw VaultError.tampered("条目无法解密")
            }
            item.id = sealed.id
            item.rev = sealed.rev
            items.append(item)
            cache[sealed.id] = sealed
        }
        return UnlockedVault(
            vaultId: file.vaultId, accountId: file.accountId, meta: meta, items: items,
            keyBox: SendableKey(vaultKey), wrappedKey: file.wrappedKey, sealedCache: cache, fileExtras: file.extras
        )
    }

    // MARK: 修改

    /// 新增或修改条目：`rev` 加 1，`modified` 更新为 `now`。
    public mutating func save(_ item: VaultItem, now: Int64) {
        var item = item
        item.modified = now
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            item.rev = items[i].rev + 1
            item.created = items[i].created
            items[i] = item
        } else {
            item.rev = 1
            items.append(item)
        }
        sealedCache[item.id] = nil
    }

    /// 删除：留墓碑（spec §6），清空内容、`rev` 加 1。
    public mutating func delete(id: String, now: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].deleted else { return }
        var tomb = items[i]
        tomb.deleted = true
        tomb.title = ""
        tomb.iconData = nil
        tomb.iconHost = nil
        tomb.favorite = false
        tomb.tags = []
        tomb.notes = ""
        tomb.sections = []
        tomb.extras = [:]
        save(tomb, now: now)
    }

    // MARK: 写出

    /// 加密后的文件内容。写盘用 `VaultStore.write`（原子写入）。
    public mutating func serialized(now: Int64) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var sealedItems: [SealedItem] = []
        for item in items {
            if let cached = sealedCache[item.id], cached.rev == item.rev {
                sealedItems.append(cached)
                continue
            }
            let s = try seal(try encoder.encode(ItemPlaintext(item)), key: vaultKey, aad: AAD.item(vaultId, item.id, item.rev))
            let sealed = SealedItem(id: item.id, rev: item.rev, nonce: s.nonce, ct: s.ct)
            sealedCache[item.id] = sealed
            sealedItems.append(sealed)
        }
        let index = VaultIndex(items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.rev) }), updated: now)
        let file = VaultFile(
            vaultId: vaultId, accountId: accountId, wrappedKey: wrappedKey,
            index: try seal(try encoder.encode(index), key: vaultKey, aad: AAD.index(vaultId)),
            meta: try seal(try encoder.encode(meta), key: vaultKey, aad: AAD.meta(vaultId)),
            items: sealedItems, extras: fileExtras
        )
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(file)
    }

    // MARK: 搬移

    /// 一个保险库里的条目搬到另一个保险库：原来的留墓碑，新的保险库里用同一个 id 新建（`rev` 从 1 开始）。
    public static func move(_ id: String, from source: inout UnlockedVault, to target: inout UnlockedVault, now: Int64) {
        guard source.vaultId != target.vaultId,
              var item = source.items.first(where: { $0.id == id && !$0.deleted }) else { return }
        source.delete(id: id, now: now)
        item.rev = 0
        target.items.removeAll { $0.id == id } // 目标里如果有同 id 的旧墓碑，被新条目取代
        target.sealedCache[id] = nil
        target.save(item, now: now)
    }
}

// MARK: 加密原语（账户文件和保险库文件共用）

/// 每段密文的认证上下文（spec §4）：把密文绑定在它在文件里的位置上。
enum AAD {
    static func account(_ a: String) -> Data { Data("1melon:v1:account:\(a)".utf8) }
    static func vaultKey(_ a: String, _ v: String) -> Data { Data("1melon:v1:key:\(a):\(v)".utf8) }
    static func index(_ v: String) -> Data { Data("1melon:v1:index:\(v)".utf8) }
    static func meta(_ v: String) -> Data { Data("1melon:v1:meta:\(v)".utf8) }
    static func item(_ v: String, _ id: String, _ rev: Int) -> Data { Data("1melon:v1:item:\(v):\(id):\(rev)".utf8) }
}

/// AES-256-GCM 加密，nonce 每次由 CSPRNG 新生成。
func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Sealed {
    let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad)
    return Sealed(nonce: Data(box.nonce), ct: box.ciphertext + box.tag)
}

func unseal(_ sealed: Sealed, key: SymmetricKey, aad: Data) throws -> Data {
    guard sealed.nonce.count == 12, sealed.ct.count >= 16 else { throw VaultError.tampered("密文长度不对") }
    let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: sealed.nonce),
        ciphertext: sealed.ct.dropLast(16),
        tag: sealed.ct.suffix(16)
    )
    return try AES.GCM.open(box, using: key, authenticating: aad)
}

func isLowercaseUUID(_ s: String) -> Bool {
    guard let u = UUID(uuidString: s) else { return false }
    return u.uuidString.lowercased() == s
}

func randomBytes(_ count: Int) -> Data {
    var rng = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
}

/// Linux 上的 swift-crypto 没有把 `SymmetricKey` 标成 `Sendable`（Apple 平台上的 CryptoKit 标了）。
/// `SymmetricKey` 是不可变的值类型，跨线程传递是安全的，所以只在这一处包一层。
struct SendableKey: @unchecked Sendable {
    let key: SymmetricKey
    init(_ key: SymmetricKey) { self.key = key }
}

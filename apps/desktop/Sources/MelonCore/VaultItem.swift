/// 条目类型。不认识的值原样保留（以后的版本可能新增类型），界面按 `text` 处理。
public struct ItemType: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let login = ItemType(rawValue: "login")
    public static let card = ItemType(rawValue: "card")
    public static let note = ItemType(rawValue: "note")
    public static let identity = ItemType(rawValue: "identity")
    public static let ssh = ItemType(rawValue: "ssh")
    public static let api = ItemType(rawValue: "api")
    public static let wifi = ItemType(rawValue: "wifi")
    public static let allKnown: [ItemType] = [.login, .card, .note, .identity, .ssh, .api, .wifi]

    public var isKnown: Bool { Self.allKnown.contains(self) }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// 字段种类（spec §5）。各端识别字段靠它，不靠 `label`。
public struct FieldKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let text = FieldKind(rawValue: "text")
    /// 参与强度检查和重复检查
    public static let password = FieldKind(rawValue: "password")
    /// 默认隐藏，但不参与强度和重复检查（CVV、PIN、API Secret）
    public static let secret = FieldKind(rawValue: "secret")
    public static let mono = FieldKind(rawValue: "mono")
    public static let url = FieldKind(rawValue: "url")
    /// Base32 密钥或 otpauth:// 链接
    public static let totp = FieldKind(rawValue: "totp")
    public static let multiline = FieldKind(rawValue: "multiline")
    public static let allKnown: [FieldKind] = [.text, .password, .secret, .mono, .url, .totp, .multiline]

    public var isKnown: Bool { Self.allKnown.contains(self) }
    /// 默认遮住、需要点「显示」
    public var isConcealed: Bool { self == .password || self == .secret || self == .multiline }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct ItemField: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var kind: FieldKind
    public var value: String
    /// 不认识的键，原样保留
    public var extras: [String: JSONValue] = [:]

    public init(id: String, label: String, kind: FieldKind, value: String) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
    }
}

extension ItemField: Codable {
    private static let known: Set<String> = ["id", "label", "kind", "value"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        label = try c.decode(String.self, forKey: AnyKey("label"))
        kind = try c.decode(FieldKind.self, forKey: AnyKey("kind"))
        value = try c.decode(String.self, forKey: AnyKey("value"))
        extras = try c.extras(excluding: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extras)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(label, forKey: AnyKey("label"))
        try c.encode(kind, forKey: AnyKey("kind"))
        try c.encode(value, forKey: AnyKey("value"))
    }
}

/// 一个条目的明文（spec §5「条目」）。`id` 和 `rev` 在文件里是明文、在条目密文之外，这里一并带上方便使用。
public struct VaultItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var rev: Int
    public var type: ItemType
    public var title: String
    public var icon: String?
    public var favorite: Bool
    public var tags: [String]
    public var notes: String
    public var fields: [ItemField]
    /// UTC 毫秒时间戳
    public var created: Int64
    public var modified: Int64
    /// 墓碑（spec §6）：删除时不从文件里移除
    public var deleted: Bool
    public var extras: [String: JSONValue] = [:]

    public init(
        id: String, rev: Int = 0, type: ItemType, title: String, icon: String? = nil, favorite: Bool = false,
        tags: [String] = [], notes: String = "", fields: [ItemField] = [], created: Int64, modified: Int64, deleted: Bool = false
    ) {
        self.id = id
        self.rev = rev
        self.type = type
        self.title = title
        self.icon = icon
        self.favorite = favorite
        self.tags = tags
        self.notes = notes
        self.fields = fields
        self.created = created
        self.modified = modified
        self.deleted = deleted
    }

    /// 第一个 `password` 字段的值（安全报告用）
    public var password: String? { fields.first { $0.kind == .password && !$0.value.isEmpty }?.value }
}

/// 条目明文的编解码（不含 `id` / `rev`，它们在密文外面）。
struct ItemPlaintext: Codable {
    var item: VaultItem

    private static let known: Set<String> = [
        "type", "title", "icon", "favorite", "tags", "notes", "fields", "created", "modified", "deleted",
    ]

    init(_ item: VaultItem) { self.item = item }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        item = VaultItem(
            id: "", rev: 0,
            type: try c.decode(ItemType.self, forKey: AnyKey("type")),
            title: try c.decode(String.self, forKey: AnyKey("title")),
            icon: try c.decodeIfPresent(String.self, forKey: AnyKey("icon")),
            favorite: try c.decodeIfPresent(Bool.self, forKey: AnyKey("favorite")) ?? false,
            tags: try c.decodeIfPresent([String].self, forKey: AnyKey("tags")) ?? [],
            notes: try c.decodeIfPresent(String.self, forKey: AnyKey("notes")) ?? "",
            fields: try c.decodeIfPresent([ItemField].self, forKey: AnyKey("fields")) ?? [],
            created: try c.decode(Int64.self, forKey: AnyKey("created")),
            modified: try c.decode(Int64.self, forKey: AnyKey("modified")),
            deleted: try c.decodeIfPresent(Bool.self, forKey: AnyKey("deleted")) ?? false
        )
        item.extras = try c.extras(excluding: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(item.extras)
        try c.encode(item.type, forKey: AnyKey("type"))
        try c.encode(item.title, forKey: AnyKey("title"))
        try c.encodeIfPresent(item.icon, forKey: AnyKey("icon"))
        try c.encode(item.favorite, forKey: AnyKey("favorite"))
        try c.encode(item.tags, forKey: AnyKey("tags"))
        try c.encode(item.notes, forKey: AnyKey("notes"))
        try c.encode(item.fields, forKey: AnyKey("fields"))
        try c.encode(item.created, forKey: AnyKey("created"))
        try c.encode(item.modified, forKey: AnyKey("modified"))
        try c.encode(item.deleted, forKey: AnyKey("deleted"))
    }
}

/// 保险库元数据（spec §5「元数据」）。
public struct VaultMeta: Sendable, Equatable {
    public var name: String
    public var created: Int64
    public var extras: [String: JSONValue] = [:]

    public init(name: String, created: Int64) {
        self.name = name
        self.created = created
    }
}

extension VaultMeta: Codable {
    private static let known: Set<String> = ["name", "created"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = try c.decode(String.self, forKey: AnyKey("name"))
        created = try c.decode(Int64.self, forKey: AnyKey("created"))
        extras = try c.extras(excluding: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extras)
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(created, forKey: AnyKey("created"))
    }
}

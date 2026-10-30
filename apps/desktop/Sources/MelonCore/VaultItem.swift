import Foundation

/// 条目类型（spec §5.3）。类型就是一套模板：只决定新建时的初始分组和字段，之后可以随意增删。
/// 不认识的值原样保留（以后的版本可能新增类型）。
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

/// 字段类型（spec §5.4）。各端识别字段靠它，不靠名称。不认识的值原样保留，界面按文本显示。
public struct FieldKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let text = FieldKind(rawValue: "text")
    /// 参与强度检查和重复检查
    public static let password = FieldKind(rawValue: "password")
    /// 隐藏文本：默认遮住，但不参与强度和重复检查（CVV、PIN、API Secret）
    public static let secret = FieldKind(rawValue: "secret")
    public static let url = FieldKind(rawValue: "url")
    public static let email = FieldKind(rawValue: "email")
    public static let phone = FieldKind(rawValue: "phone")
    /// `YYYY-MM-DD`
    public static let date = FieldKind(rawValue: "date")
    /// `YYYY-MM`（卡片有效期）
    public static let monthYear = FieldKind(rawValue: "monthYear")
    /// Base32 密钥或 otpauth:// 链接
    public static let totp = FieldKind(rawValue: "totp")
    public static let multiline = FieldKind(rawValue: "multiline")
    /// 文件附件（保险库版本 2 起）：`attachment` 引用单独的附件文件，`fileName` 是原文件名，`value` 为空。界面不显示内容
    public static let file = FieldKind(rawValue: "file")
    public static let allKnown: [FieldKind] = [.text, .password, .secret, .url, .email, .phone, .date, .monthYear, .totp, .multiline, .file]

    public var isKnown: Bool { Self.allKnown.contains(self) }
    /// 默认遮住、需要点「显示」（多行文本也遮住：SSH 私钥就是多行文本）
    public var isConcealed: Bool { self == .password || self == .secret || self == .multiline }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// 字段：名称（可改）+ 类型 + 值。
public struct ItemField: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var kind: FieldKind
    public var value: String
    /// 显示属性：等宽字体（卡号、主机、Key ID 等）
    public var monospace: Bool
    /// 文件附件的原文件名（只有名字，不带路径）；别的字段类型没有
    public var fileName: String?
    /// 文件附件的引用（spec §5.4）；没选文件或别的字段类型为 nil
    public var attachment: AttachmentRef?
    /// 不认识的键，原样保留
    public var extras: [String: JSONValue] = [:]

    public init(id: String = newID(), label: String, kind: FieldKind, value: String = "", monospace: Bool = false, fileName: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
        self.monospace = monospace
        self.fileName = fileName
    }
}

// MARK: 文件附件（spec §5.4）

extension ItemField {
    /// 放进一个附件：内容在附件文件里（`AttachmentFile.seal`），字段只存引用。`name` 只保留最后一段，不带路径
    public mutating func attach(_ ref: AttachmentRef, name: String) {
        attachment = ref
        value = ""
        let last = name.split(separator: "/").last.map(String.init) ?? name
        fileName = last.isEmpty ? nil : last
    }
}

extension ItemField: Codable {
    private static let known: Set<String> = ["id", "label", "kind", "value", "monospace", "fileName", "attachment"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        label = try c.decode(String.self, forKey: AnyKey("label"))
        kind = try c.decode(FieldKind.self, forKey: AnyKey("kind"))
        value = try c.decode(String.self, forKey: AnyKey("value"))
        monospace = try c.decodeIfPresent(Bool.self, forKey: AnyKey("monospace")) ?? false
        fileName = try c.decodeIfPresent(String.self, forKey: AnyKey("fileName"))
        attachment = try c.decodeIfPresent(AttachmentRef.self, forKey: AnyKey("attachment"))
        extras = try c.extras(excluding: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extras)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(label, forKey: AnyKey("label"))
        try c.encode(kind, forKey: AnyKey("kind"))
        try c.encode(value, forKey: AnyKey("value"))
        if monospace { try c.encode(true, forKey: AnyKey("monospace")) }
        if let fileName { try c.encode(fileName, forKey: AnyKey("fileName")) }
        try c.encodeIfPresent(attachment, forKey: AnyKey("attachment"))
    }
}

/// 分组：一组字段，可以有标题（第一个分组通常没有）。
public struct ItemSection: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var fields: [ItemField]
    public var extras: [String: JSONValue] = [:]

    public init(id: String = newID(), title: String = "", fields: [ItemField] = []) {
        self.id = id
        self.title = title
        self.fields = fields
    }
}

extension ItemSection: Codable {
    private static let known: Set<String> = ["id", "title", "fields"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        title = try c.decodeIfPresent(String.self, forKey: AnyKey("title")) ?? ""
        fields = try c.decodeIfPresent([ItemField].self, forKey: AnyKey("fields")) ?? []
        extras = try c.extras(excluding: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extras)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(title, forKey: AnyKey("title"))
        try c.encode(fields, forKey: AnyKey("fields"))
    }
}

/// 一个条目的明文（spec §5.2）。`id` 和 `rev` 在文件里是明文、在条目密文之外，这里一并带上方便使用。
public struct VaultItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var rev: Int
    public var type: ItemType
    public var title: String
    /// 网站图标：PNG，不超过 64×64、16 KB（spec §5.2）。没有就用类型默认图标
    public var iconData: Data?
    /// 图标是从哪个主机取的；网址的主机变了就重新取
    public var iconHost: String?
    public var favorite: Bool
    public var tags: [String]
    public var notes: String
    public var sections: [ItemSection]
    /// 用户在安全报告里忽略了的问题（spec §5.2）：`weak`、`reused`、`no2fa`、`old`，不认识的值原样保留
    public var ignoredIssues: [String] = []
    /// UTC 毫秒时间戳
    public var created: Int64
    public var modified: Int64
    /// 墓碑（spec §6）：删除时不从文件里移除
    public var deleted: Bool
    public var extras: [String: JSONValue] = [:]

    public init(
        id: String = newID(), rev: Int = 0, type: ItemType, title: String, favorite: Bool = false,
        tags: [String] = [], notes: String = "", sections: [ItemSection] = [], created: Int64, modified: Int64, deleted: Bool = false
    ) {
        self.id = id
        self.rev = rev
        self.type = type
        self.title = title
        self.favorite = favorite
        self.tags = tags
        self.notes = notes
        self.sections = sections
        self.created = created
        self.modified = modified
        self.deleted = deleted
    }

    /// 所有分组里的字段，按顺序
    public var allFields: [ItemField] { sections.flatMap(\.fields) }

    /// 所有非空的密码（安全报告用：每个分组里的密码都算）
    public var passwords: [String] { allFields.filter { $0.kind == .password && !$0.value.isEmpty }.map(\.value) }
}

/// 条目明文的编解码（不含 `id` / `rev`，它们在密文外面）。
struct ItemPlaintext: Codable {
    var item: VaultItem

    private static let known: Set<String> = [
        "type", "title", "iconData", "iconHost", "favorite", "tags", "notes", "sections", "ignoredIssues", "created", "modified", "deleted",
    ]

    init(_ item: VaultItem) { self.item = item }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        item = VaultItem(
            id: "", rev: 0,
            type: try c.decode(ItemType.self, forKey: AnyKey("type")),
            title: try c.decode(String.self, forKey: AnyKey("title")),
            favorite: try c.decodeIfPresent(Bool.self, forKey: AnyKey("favorite")) ?? false,
            tags: try c.decodeIfPresent([String].self, forKey: AnyKey("tags")) ?? [],
            notes: try c.decodeIfPresent(String.self, forKey: AnyKey("notes")) ?? "",
            sections: try c.decodeIfPresent([ItemSection].self, forKey: AnyKey("sections")) ?? [],
            created: try c.decode(Int64.self, forKey: AnyKey("created")),
            modified: try c.decode(Int64.self, forKey: AnyKey("modified")),
            deleted: try c.decodeIfPresent(Bool.self, forKey: AnyKey("deleted")) ?? false
        )
        item.iconData = try c.decodeIfPresent(Data.self, forKey: AnyKey("iconData"))
        item.iconHost = try c.decodeIfPresent(String.self, forKey: AnyKey("iconHost"))
        item.ignoredIssues = try c.decodeIfPresent([String].self, forKey: AnyKey("ignoredIssues")) ?? []
        item.extras = try c.extras(excluding: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(item.extras)
        try c.encode(item.type, forKey: AnyKey("type"))
        try c.encode(item.title, forKey: AnyKey("title"))
        try c.encodeIfPresent(item.iconData, forKey: AnyKey("iconData"))
        try c.encodeIfPresent(item.iconHost, forKey: AnyKey("iconHost"))
        try c.encode(item.favorite, forKey: AnyKey("favorite"))
        try c.encode(item.tags, forKey: AnyKey("tags"))
        try c.encode(item.notes, forKey: AnyKey("notes"))
        try c.encode(item.sections, forKey: AnyKey("sections"))
        if !item.ignoredIssues.isEmpty { try c.encode(item.ignoredIssues, forKey: AnyKey("ignoredIssues")) }
        try c.encode(item.created, forKey: AnyKey("created"))
        try c.encode(item.modified, forKey: AnyKey("modified"))
        try c.encode(item.deleted, forKey: AnyKey("deleted"))
    }
}

/// 保险库元数据（spec §5.1）：名字、图标、颜色、排序。
public struct VaultMeta: Sendable, Equatable {
    /// 保险库图标，取自固定集合（各端自己映射成图标资源；不认识的显示默认图标）
    public static let icons = ["person", "briefcase", "house", "heart", "star", "folder", "lock", "server", "cart", "gamecontroller"]
    /// 保险库颜色，取自固定集合（各端自己映射成具体色值）
    public static let colors = ["blue", "green", "orange", "red", "purple", "teal", "gray"]

    public var name: String
    public var icon: String
    public var color: String
    /// 侧栏里的顺序，小的在前
    public var order: Int
    public var created: Int64
    public var extras: [String: JSONValue] = [:]

    public init(name: String, icon: String = "person", color: String = "blue", order: Int = 0, created: Int64) {
        self.name = name
        self.icon = icon
        self.color = color
        self.order = order
        self.created = created
    }
}

extension VaultMeta: Codable {
    private static let known: Set<String> = ["name", "icon", "color", "order", "created"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = try c.decode(String.self, forKey: AnyKey("name"))
        icon = try c.decodeIfPresent(String.self, forKey: AnyKey("icon")) ?? "person"
        color = try c.decodeIfPresent(String.self, forKey: AnyKey("color")) ?? "blue"
        order = try c.decodeIfPresent(Int.self, forKey: AnyKey("order")) ?? 0
        created = try c.decode(Int64.self, forKey: AnyKey("created"))
        extras = try c.extras(excluding: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extras)
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(icon, forKey: AnyKey("icon"))
        try c.encode(color, forKey: AnyKey("color"))
        try c.encode(order, forKey: AnyKey("order"))
        try c.encode(created, forKey: AnyKey("created"))
    }
}

/// 新 id：小写 UUID
public func newID() -> String { UUID().uuidString.lowercased() }

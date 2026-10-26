import Foundation

/// 模板里的一个字段
public struct FieldTemplate: Sendable, Equatable {
    public let label: String
    public let kind: FieldKind
    public let monospace: Bool

    public init(_ label: String, _ kind: FieldKind, monospace: Bool = false) {
        self.label = label
        self.kind = kind
        self.monospace = monospace
    }
}

/// 模板里的一个分组
public struct SectionTemplate: Sendable, Equatable {
    public let title: String
    public let fields: [FieldTemplate]

    public init(_ title: String = "", fields: [FieldTemplate]) {
        self.title = title
        self.fields = fields
    }
}

/// 各类型的模板（spec 附录 A，各端一致）。模板只决定新建时的样子，建好后分组和字段都能增删改。
public extension ItemType {
    var template: [SectionTemplate] {
        switch self {
        case .login:
            [SectionTemplate(fields: [FieldTemplate("用户名", .text), FieldTemplate("密码", .password), FieldTemplate("网站", .url)]),
             SectionTemplate("两步验证", fields: [FieldTemplate("一次性验证码", .totp)])]
        case .card:
            [SectionTemplate(fields: [FieldTemplate("持卡人", .text), FieldTemplate("卡号", .text, monospace: true), FieldTemplate("有效期", .monthYear),
                              FieldTemplate("CVV", .secret), FieldTemplate("PIN", .secret)])]
        case .identity:
            [SectionTemplate(fields: [FieldTemplate("姓名", .text), FieldTemplate("证件号码", .text, monospace: true), FieldTemplate("出生日期", .date)]),
             SectionTemplate("联系方式", fields: [FieldTemplate("电话", .phone), FieldTemplate("邮箱", .email), FieldTemplate("地址", .text)])]
        case .ssh:
            [SectionTemplate(fields: [FieldTemplate("主机", .text, monospace: true), FieldTemplate("用户名", .text), FieldTemplate("私钥", .multiline),
                              FieldTemplate("指纹", .text, monospace: true)])]
        case .api:
            [SectionTemplate(fields: [FieldTemplate("服务", .text), FieldTemplate("Key ID", .text, monospace: true), FieldTemplate("Secret", .secret)])]
        case .wifi:
            [SectionTemplate(fields: [FieldTemplate("网络名称", .text), FieldTemplate("密码", .password), FieldTemplate("安全类型", .text)])]
        default:
            [] // 安全笔记只有备注；不认识的类型没有模板
        }
    }
}

public extension VaultItem {
    /// 按类型模板新建条目：新 id、`rev` 为 0（保存时变成 1）、分组和字段都是空值。
    static func fromTemplate(_ type: ItemType, title: String = "", now: Int64) -> VaultItem {
        let sections = type.template.map { s in
            ItemSection(title: s.title, fields: s.fields.map { ItemField(label: $0.label, kind: $0.kind, monospace: $0.monospace) })
        }
        return VaultItem(type: type, title: title, sections: sections, created: now, modified: now)
    }

    /// 保存前清理：去掉空字段；去掉清理后没有字段的分组。
    func droppingEmptyFields() -> VaultItem {
        var copy = self
        for i in copy.sections.indices {
            copy.sections[i].fields.removeAll { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        copy.sections.removeAll { $0.fields.isEmpty }
        return copy
    }

    /// 第一个网址（取网站图标、打开网站用）
    var primaryURL: String? { allFields.first { $0.kind == .url && !$0.value.isEmpty }?.value }

    /// 列表里的第二行：只露出能帮你认出条目、又不泄露机密的信息。
    var subtitle: String {
        func first(_ match: (ItemField) -> Bool) -> String {
            allFields.first { match($0) && !$0.value.isEmpty }?.value ?? ""
        }
        let text = first { $0.kind == .text && !$0.monospace }
        let mono = first { $0.kind == .text && $0.monospace }
        switch type {
        case .login:
            let user = text.isEmpty ? first { $0.kind == .email } : text
            return user
        case .wifi, .api:
            return text
        case .card:
            let digits = mono.filter(\.isNumber)
            return digits.count >= 4 ? "•••• " + digits.suffix(4) : ""
        case .identity:
            let id = mono.filter { !$0.isWhitespace }
            return id.count >= 5 ? id.prefix(2) + "••••" + id.suffix(3) : text
        case .ssh:
            let host = mono.split(separator: ":").first.map(String.init) ?? ""
            return text.isEmpty ? host : "\(text)@\(host)"
        case .note:
            return notes.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        default:
            return ""
        }
    }

    /// 搜索：标题、副标题、标签、网址、邮箱，不区分大小写。不搜机密字段，避免把密码当搜索词匹配出来。
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let searchable = allFields.filter { $0.kind == .url || $0.kind == .email }.map(\.value)
        let haystack = ([title, subtitle] + tags + searchable).joined(separator: " ").lowercased()
        return haystack.contains(q)
    }
}

import Foundation

/// 各类型新建条目时的默认字段（设计稿 docs/ui 的模板）。字段的含义靠 `kind`，`label` 只是显示用的默认名。
public extension ItemType {
    var templateFields: [(label: String, kind: FieldKind)] {
        switch self {
        case .login: [("用户名", .text), ("密码", .password), ("网站", .url), ("两步验证密钥", .totp)]
        case .card: [("持卡人", .text), ("卡号", .mono), ("有效期", .text), ("CVV", .secret), ("PIN", .secret)]
        case .identity: [("姓名", .text), ("证件号码", .mono), ("出生日期", .text), ("地址", .text)]
        case .ssh: [("主机", .mono), ("用户名", .text), ("私钥", .multiline), ("指纹", .mono)]
        case .api: [("服务", .text), ("Key ID", .mono), ("Secret", .secret)]
        case .wifi: [("网络名称", .text), ("密码", .password), ("安全类型", .text)]
        default: []
        }
    }
}

public extension VaultItem {
    /// 按类型模板补齐缺的字段（编辑时用：老条目也能看到模板里的全部字段）。已有字段的顺序和内容不变。
    func withTemplateFields() -> VaultItem {
        var copy = self
        for t in type.templateFields where !copy.fields.contains(where: { $0.label == t.label && $0.kind == t.kind }) {
            copy.fields.append(ItemField(id: UUID().uuidString.lowercased(), label: t.label, kind: t.kind, value: ""))
        }
        return copy
    }

    /// 去掉空字段（保存时用）。
    func droppingEmptyFields() -> VaultItem {
        var copy = self
        copy.fields.removeAll { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return copy
    }

    /// 列表里的第二行：只露出能帮你认出条目、又不泄露机密的信息。
    var subtitle: String {
        func first(_ kind: FieldKind) -> String {
            fields.first { $0.kind == kind && !$0.value.isEmpty }?.value ?? ""
        }
        switch type {
        case .login, .wifi, .api:
            return first(.text)
        case .card:
            let digits = first(.mono).filter(\.isNumber)
            return digits.count >= 4 ? "•••• " + digits.suffix(4) : ""
        case .identity:
            let id = first(.mono).filter { !$0.isWhitespace }
            return id.count >= 5 ? id.prefix(2) + "••••" + id.suffix(3) : ""
        case .ssh:
            let user = first(.text), host = first(.mono).split(separator: ":").first.map(String.init) ?? ""
            return user.isEmpty ? host : "\(user)@\(host)"
        case .note:
            return notes.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        default:
            return ""
        }
    }

    /// 搜索：标题、副标题、标签、网址，不区分大小写。不搜机密字段，避免输入时把密码当搜索词匹配出来。
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let haystack = ([title, subtitle] + tags + fields.filter { $0.kind == .url }.map(\.value))
            .joined(separator: " ").lowercased()
        return haystack.contains(q)
    }
}

import Foundation

/// 导出成明文 CSV：一行一个条目，表头和浏览器导出的密码文件兼容（导回 1Melon、Chrome、Bitwarden 都能认）。
/// 没有专门列的字段（第二个密码、卡号、自定义字段……）按「分组 · 名称：值」追加到备注里，不丢内容。
/// 网站图标、字段类型、分组结构不导出；要完整保留请用加密备份。
public enum Exporter {
    public struct Entry: Sendable {
        public var vault: String
        public var item: VaultItem
        public init(vault: String, item: VaultItem) {
            self.vault = vault
            self.item = item
        }
    }

    public static let header = ["title", "url", "username", "password", "otpauth", "notes", "vault", "type", "tags", "favorite"]

    public static func csv(_ entries: [Entry]) -> String {
        var lines = [header.joined(separator: ",")]
        for e in entries where !e.item.deleted {
            lines.append(row(e).map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func row(_ e: Entry) -> [String] {
        let item = e.item
        var used = Set<String>()
        func take(_ match: (ItemField) -> Bool) -> String {
            guard let f = item.allFields.first(where: { !used.contains($0.id) && !$0.value.isEmpty && match($0) }) else { return "" }
            used.insert(f.id)
            return f.value
        }
        let url = take { $0.kind == .url }
        let password = take { $0.kind == .password }
        let otp = take { $0.kind == .totp }
        // 登录的用户名：第一个普通文本，没有就第一个邮箱
        var username = ""
        if item.type == .login {
            username = take { $0.kind == .text && !$0.monospace }
            if username.isEmpty { username = take { $0.kind == .email } }
        }

        var extra: [String] = []
        for section in item.sections {
            for f in section.fields where !used.contains(f.id) && !f.value.isEmpty {
                let label = section.title.isEmpty ? f.label : "\(section.title) · \(f.label)"
                extra.append("\(label)：\(f.value)")
            }
        }
        let notes = ([item.notes].filter { !$0.isEmpty } + extra).joined(separator: "\n")
        return [item.title, url, username, password, otp, notes, e.vault, item.type.rawValue,
                item.tags.joined(separator: ","), item.favorite ? "1" : ""]
    }

    /// RFC 4180：含逗号、引号、换行的值加引号，引号写两遍
    static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

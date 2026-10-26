import Foundation

/// 从别的密码管理器导入（只在本机解析，不联网）。各格式先转成 `ImportResult`，界面预览后再写进保险库。
public struct ImportResult: Sendable, Equatable {
    public struct Vault: Sendable, Equatable {
        /// 原来的保险库名（没有保险库概念的格式为 nil）
        public var name: String?
        public var items: [VaultItem]
    }

    public var source: String
    public var vaults: [Vault]
    /// 导入不了的东西，给用户看的说明（附件、不支持的字段等）
    public var skipped: [String]

    public var itemCount: Int { vaults.reduce(0) { $0 + $1.items.count } }
}

public enum ImportError: Error, Equatable {
    case unrecognized(String)
}

public enum Importer {
    /// 按文件内容猜格式：.1pux（ZIP 里的 export.data）、Bitwarden JSON、CSV
    public static func parse(fileName: String, data: Data, now: Int64 = Date().unixMilliseconds) throws -> ImportResult {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".1pux") {
            #if canImport(Compression)
            guard let exportData = try ZipReader.entry(named: "export.data", in: data) else {
                throw ImportError.unrecognized("1pux 文件里没有 export.data")
            }
            return try onePassword(exportData: exportData, now: now)
            #else
            throw ImportError.unrecognized("这个平台不支持读取 .1pux")
            #endif
        }
        if lower.hasSuffix(".json") { return try bitwarden(json: data, now: now) }
        if lower.hasSuffix(".csv") {
            guard let text = String(data: data, encoding: .utf8) else { throw ImportError.unrecognized("CSV 不是 UTF-8 编码") }
            return try browserCSV(text, now: now)
        }
        throw ImportError.unrecognized("不认识的文件类型，支持 .1pux、Bitwarden 的 .json、浏览器导出的 .csv")
    }

    // MARK: 1Password（.1pux 里的 export.data）

    public static func onePassword(exportData: Data, now: Int64 = Date().unixMilliseconds) throws -> ImportResult {
        guard let root = try? JSONSerialization.jsonObject(with: exportData) as? [String: Any],
              let accounts = root["accounts"] as? [[String: Any]] else {
            throw ImportError.unrecognized("不是 1Password 的导出数据")
        }
        var result = ImportResult(source: "1Password", vaults: [], skipped: [])
        for account in accounts {
            for vault in account["vaults"] as? [[String: Any]] ?? [] {
                let name = (vault["attrs"] as? [String: Any])?["name"] as? String
                var items: [VaultItem] = []
                for raw in vault["items"] as? [[String: Any]] ?? [] {
                    if let item = onePasswordItem(raw, now: now, skipped: &result.skipped) { items.append(item) }
                }
                result.vaults.append(.init(name: name, items: items))
            }
        }
        return result
    }

    /// 1Password 类别 → 我们的类型（对不上的按安全笔记，字段一个不丢）
    static func onePasswordType(_ category: String) -> ItemType {
        switch category {
        case "001", "005", "110", "111": .login     // 登录、密码、服务器、邮箱账户
        case "002": .card
        case "003": .note
        case "004", "103", "106", "108": .identity  // 身份、驾照、护照、社保号
        case "109": .wifi
        case "112": .api
        case "114": .ssh
        default: .note
        }
    }

    static func onePasswordItem(_ raw: [String: Any], now: Int64, skipped: inout [String]) -> VaultItem? {
        let overview = raw["overview"] as? [String: Any] ?? [:]
        let details = raw["details"] as? [String: Any] ?? [:]
        let title = (overview["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未命名"
        let category = raw["categoryUuid"] as? String ?? ""
        let type = onePasswordType(category)

        var item = VaultItem(type: type, title: title,
                             created: seconds(raw["createdAt"]) ?? now, modified: seconds(raw["updatedAt"]) ?? now)
        item.favorite = (raw["favIndex"] as? Int ?? 0) > 0
        item.tags = overview["tags"] as? [String] ?? []
        if (raw["state"] as? String) == "archived" { item.tags.append("1Password 已归档") }
        item.notes = details["notesPlain"] as? String ?? ""

        // 主分组：登录表单里的用户名、密码，加上网址
        var main: [ItemField] = []
        for f in details["loginFields"] as? [[String: Any]] ?? [] {
            guard let value = f["value"] as? String, !value.isEmpty else { continue }
            switch f["designation"] as? String {
            case "username": main.append(ItemField(label: "用户名", kind: .text, value: value))
            case "password": main.append(ItemField(label: "密码", kind: .password, value: value))
            default:
                let isSecret = (f["fieldType"] as? String) == "P"
                main.append(ItemField(label: (f["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "表单字段",
                                      kind: isSecret ? .secret : .text, value: value))
            }
        }
        if let pw = details["password"] as? String, !pw.isEmpty { main.append(ItemField(label: "密码", kind: .password, value: pw)) }
        var urls = (overview["urls"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }.filter { !$0.isEmpty }
        if urls.isEmpty, let u = overview["url"] as? String, !u.isEmpty { urls = [u] }
        for (i, u) in urls.enumerated() { main.append(ItemField(label: i == 0 ? "网站" : "网站 \(i + 1)", kind: .url, value: u)) }

        var sections: [ItemSection] = main.isEmpty ? [] : [ItemSection(fields: main)]
        for s in details["sections"] as? [[String: Any]] ?? [] {
            var fields: [ItemField] = []
            for f in s["fields"] as? [[String: Any]] ?? [] {
                if let field = onePasswordField(f, itemTitle: title, skipped: &skipped) { fields.append(field) }
            }
            guard !fields.isEmpty else { continue }
            let sectionTitle = (s["title"] as? String) ?? ""
            if sectionTitle.isEmpty, !sections.isEmpty, sections[0].title.isEmpty {
                sections[0].fields += fields // 没标题的分组并进主分组
            } else {
                sections.append(ItemSection(title: sectionTitle, fields: fields))
            }
        }
        item.sections = sections
        if (details["documentAttributes"] as? [String: Any]) != nil || category == "006" {
            skipped.append("「\(title)」是文档（附件），文件本身没有导入")
        }
        return item
    }

    static func onePasswordField(_ f: [String: Any], itemTitle: String, skipped: inout [String]) -> ItemField? {
        let label = (f["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "字段"
        guard let value = f["value"] as? [String: Any], let (key, v) = value.first else { return nil }
        func text(_ any: Any) -> String { any as? String ?? (any as? NSNumber)?.stringValue ?? "" }
        let lowerLabel = label.lowercased()
        switch key {
        case "string", "menu", "gender", "creditCardType":
            let s = text(v)
            return s.isEmpty ? nil : ItemField(label: label, kind: .text, value: s)
        case "concealed":
            let s = text(v)
            guard !s.isEmpty else { return nil }
            let isPassword = lowerLabel.contains("password") || label.contains("密码")
            return ItemField(label: label, kind: isPassword ? .password : .secret, value: s)
        case "totp":
            let s = text(v)
            return s.isEmpty ? nil : ItemField(label: label == "字段" ? "一次性验证码" : label, kind: .totp, value: s)
        case "url":
            let s = text(v)
            return s.isEmpty ? nil : ItemField(label: label, kind: .url, value: s)
        case "email":
            let s = (v as? [String: Any])?["email_address"] as? String ?? text(v)
            return s.isEmpty ? nil : ItemField(label: label, kind: .email, value: s)
        case "phone":
            let s = text(v)
            return s.isEmpty ? nil : ItemField(label: label, kind: .phone, value: s)
        case "date":
            guard let ts = (v as? NSNumber)?.doubleValue, ts != 0 else { return nil }
            return ItemField(label: label, kind: .date, value: ymd(Date(timeIntervalSince1970: ts)))
        case "monthYear":
            guard let n = (v as? NSNumber)?.intValue, n > 0 else { return nil }
            return ItemField(label: label, kind: .monthYear, value: String(format: "%04d-%02d", n / 100, n % 100))
        case "creditCardNumber":
            let s = text(v)
            return s.isEmpty ? nil : ItemField(label: label, kind: .text, value: s, monospace: true)
        case "sshKey":
            let key = (v as? [String: Any])?["privateKey"] as? String ?? ""
            return key.isEmpty ? nil : ItemField(label: label == "字段" ? "私钥" : label, kind: .multiline, value: key)
        case "address":
            let a = v as? [String: Any] ?? [:]
            let parts = ["street", "city", "state", "zip", "country"].compactMap { a[$0] as? String }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : ItemField(label: label, kind: .text, value: parts.joined(separator: ", "))
        case "file":
            skipped.append("「\(itemTitle)」的附件「\(label)」没有导入")
            return nil
        case "reference":
            return nil
        default:
            let s = text(v)
            guard !s.isEmpty else { return nil }
            return ItemField(label: label, kind: .text, value: s)
        }
    }

    // MARK: Bitwarden（未加密的 .json 导出）

    public static func bitwarden(json data: Data, now: Int64 = Date().unixMilliseconds) throws -> ImportResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            throw ImportError.unrecognized("不是 Bitwarden 的导出文件（加密导出要先在 Bitwarden 里选「.json」不加密导出）")
        }
        let folders = Dictionary((root["folders"] as? [[String: Any]] ?? []).compactMap { f -> (String, String)? in
            guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
            return (id, name)
        }, uniquingKeysWith: { a, _ in a })
        var out: [VaultItem] = []
        var skipped: [String] = []
        for raw in items {
            let title = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未命名"
            let typeCode = raw["type"] as? Int ?? 1
            let type: ItemType = [1: .login, 2: .note, 3: .card, 4: .identity][typeCode] ?? .note
            var item = VaultItem(type: type, title: title, created: now, modified: now)
            item.favorite = raw["favorite"] as? Bool ?? false
            item.notes = raw["notes"] as? String ?? ""
            if let folder = (raw["folderId"] as? String).flatMap({ folders[$0] }) { item.tags = [folder] }
            var main: [ItemField] = []
            func add(_ label: String, _ kind: FieldKind, _ value: Any?, mono: Bool = false) {
                guard let s = value as? String, !s.isEmpty else { return }
                main.append(ItemField(label: label, kind: kind, value: s, monospace: mono))
            }
            if let login = raw["login"] as? [String: Any] {
                add("用户名", .text, login["username"])
                add("密码", .password, login["password"])
                for (i, u) in (login["uris"] as? [[String: Any]] ?? []).compactMap({ $0["uri"] as? String }).enumerated() {
                    add(i == 0 ? "网站" : "网站 \(i + 1)", .url, u)
                }
                add("一次性验证码", .totp, login["totp"])
            }
            if let card = raw["card"] as? [String: Any] {
                add("持卡人", .text, card["cardholderName"])
                add("卡号", .text, card["number"], mono: true)
                if let m = (card["expMonth"] as? String).flatMap(Int.init), let y = (card["expYear"] as? String).flatMap(Int.init) {
                    main.append(ItemField(label: "有效期", kind: .monthYear, value: String(format: "%04d-%02d", y < 100 ? 2000 + y : y, m)))
                }
                add("CVV", .secret, card["code"])
                add("卡组织", .text, card["brand"])
            }
            if let id = raw["identity"] as? [String: Any] {
                let name = ["lastName", "firstName", "middleName"].compactMap { id[$0] as? String }.filter { !$0.isEmpty }.joined(separator: " ")
                add("姓名", .text, name)
                add("邮箱", .email, id["email"])
                add("电话", .phone, id["phone"])
                add("证件号码", .text, id["passportNumber"] ?? id["licenseNumber"] ?? id["ssn"], mono: true)
                let addr = ["address1", "address2", "city", "state", "postalCode", "country"].compactMap { id[$0] as? String }.filter { !$0.isEmpty }
                add("地址", .text, addr.isEmpty ? nil : addr.joined(separator: ", "))
            }
            var custom: [ItemField] = []
            for f in raw["fields"] as? [[String: Any]] ?? [] {
                guard let v = f["value"] as? String, !v.isEmpty else { continue }
                let kind: FieldKind = (f["type"] as? Int) == 1 ? .secret : .text
                custom.append(ItemField(label: (f["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "字段", kind: kind, value: v))
            }
            if (raw["attachments"] as? [Any])?.isEmpty == false { skipped.append("「\(title)」的附件没有导入") }
            item.sections = (main.isEmpty ? [] : [ItemSection(fields: main)]) + (custom.isEmpty ? [] : [ItemSection(title: "自定义字段", fields: custom)])
            out.append(item)
        }
        return ImportResult(source: "Bitwarden", vaults: [.init(name: nil, items: out)], skipped: skipped)
    }

    // MARK: 浏览器导出的 CSV（Chrome / Safari / Firefox / Edge）

    public static func browserCSV(_ text: String, now: Int64 = Date().unixMilliseconds) throws -> ImportResult {
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else {
            throw ImportError.unrecognized("CSV 是空的")
        }
        func col(_ names: String...) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let pwCol = col("password"), let urlCol = col("url", "login_uri", "website") else {
            throw ImportError.unrecognized("CSV 里找不到 url 和 password 列，不像浏览器导出的密码文件")
        }
        let nameCol = col("name", "title"), userCol = col("username", "login_username", "user")
        let noteCol = col("note", "notes", "comment"), otpCol = col("otpauth", "totp")
        // 1Melon 自己导出的 CSV 多几列：保险库、标签、收藏
        let vaultCol = col("vault"), tagsCol = col("tags"), favCol = col("favorite"), typeCol = col("type")
        var groups: [(name: String?, items: [VaultItem])] = []
        for row in rows.dropFirst() where row.count > max(pwCol, urlCol) {
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil }?.trimmingCharacters(in: .whitespaces) ?? "" }
            let url = cell(urlCol), password = cell(pwCol)
            // 1Melon 导出的非登录条目（卡、笔记……）可能没有网址和密码，有标题就收
            let type = ItemType.allKnown.first { $0.rawValue == cell(typeCol) } ?? .login
            guard !url.isEmpty || !password.isEmpty || (typeCol != nil && !cell(nameCol).isEmpty) else { continue }
            let title = cell(nameCol).isEmpty ? (WebsiteIcon.host(forURL: url) ?? (url.isEmpty ? "未命名" : url)) : cell(nameCol)
            var item = VaultItem.fromTemplate(.login, title: title, now: now)
            if type == .login {
                item.sections[0].fields[0].value = cell(userCol)
                item.sections[0].fields[1].value = password
                item.sections[0].fields[2].value = url
                item.sections[1].fields[0].value = cell(otpCol)
            } else {
                // 其他类型的字段导出时已经写进备注；这里只放回有专门列的几个
                item.type = type
                item.sections = [ItemSection(fields: [
                    ItemField(label: "网站", kind: .url, value: url),
                    ItemField(label: "密码", kind: .password, value: password),
                    ItemField(label: "一次性验证码", kind: .totp, value: cell(otpCol)),
                ])]
            }
            item.notes = cell(noteCol)
            item.tags = cell(tagsCol).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            item.favorite = ["1", "true", "yes"].contains(cell(favCol).lowercased())
            let vault: String? = cell(vaultCol).isEmpty ? nil : cell(vaultCol)
            if let i = groups.firstIndex(where: { $0.name == vault }) {
                groups[i].items.append(item.droppingEmptyFields())
            } else {
                groups.append((vault, [item.droppingEmptyFields()]))
            }
        }
        if groups.isEmpty { groups = [(nil, [])] }
        return ImportResult(source: vaultCol == nil ? "浏览器 CSV" : "1Melon CSV",
                            vaults: groups.map { .init(name: $0.name, items: $0.items) }, skipped: [])
    }

    // MARK: 工具

    static func seconds(_ any: Any?) -> Int64? {
        guard let n = (any as? NSNumber)?.doubleValue, n > 0 else { return nil }
        return Int64(n * 1000)
    }

    static func ymd(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// RFC 4180 CSV：引号、引号里的逗号和换行、连续两个引号表示一个引号
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }
}

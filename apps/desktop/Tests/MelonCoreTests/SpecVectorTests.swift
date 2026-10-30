import Foundation
import XCTest
@testable import MelonCore

/// 跨端测试向量（spec §7）。校验每次都跑；生成只在 `MELON_REGEN_VECTORS=1` 时跑，
/// 而且格式定稿后，除非同时升格式版本，否则不能为了让测试通过去改向量。
final class SpecVectorTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("spec/test-vectors")
    static var example: URL { dir.appendingPathComponent("example") }

    static let password = "correct horse battery staple · 1Melon"

    // MARK: 校验

    struct KDFVectors: Decodable {
        struct Case: Decodable {
            let name: String
            let password: String
            let salt: Data
            let memKiB: UInt32
            let iterations: UInt32
            let parallelism: UInt32
            let kek: String
        }
        let cases: [Case]
    }

    func testKDFVectors() throws {
        let v = try JSONDecoder().decode(KDFVectors.self, from: Data(contentsOf: Self.dir.appendingPathComponent("kdf.json")))
        XCTAssertFalse(v.cases.isEmpty)
        for c in v.cases {
            let kdf = KDFParameters(alg: KDFParameters.algorithm, memKiB: c.memKiB, iterations: c.iterations,
                                    parallelism: c.parallelism, salt: c.salt)
            let kek = try UnlockedAccount.deriveKEK(password: c.password, kdf: kdf)
            XCTAssertEqual(kek.withUnsafeBytes { hex(Array($0)) }, c.kek, c.name)
        }
    }

    struct Expectation: Decodable {
        struct Vault: Decodable {
            let file: String
            let vaultId: String
            let meta: JSONValue
            let items: [JSONValue]
        }
        struct Attachment: Decodable {
            let file: String
            let ref: AttachmentRef
            let plaintext: Data
        }
        let password: String
        let wrongPassword: String
        let accountId: String
        let vaults: [Vault]
        let attachments: [Attachment]
    }

    static func loadExpectation() throws -> Expectation {
        try JSONDecoder().decode(Expectation.self, from: Data(contentsOf: example.appendingPathComponent("expected.json")))
    }

    static func loadExampleAccount() throws -> UnlockedAccount {
        try UnlockedAccount.open(Data(contentsOf: example.appendingPathComponent("account.1melon")), password: password)
    }

    func testExampleAccountAndVaults() throws {
        let expect = try Self.loadExpectation()
        let repo = AccountRepository(root: Self.example)
        let loaded = try repo.unlock(password: expect.password)
        XCTAssertEqual(loaded.account.accountId, expect.accountId)
        XCTAssertTrue(loaded.failures.isEmpty)
        XCTAssertEqual(loaded.vaults.map(\.vaultId), expect.vaults.map(\.vaultId))
        for (vault, e) in zip(loaded.vaults, expect.vaults) {
            XCTAssertEqual("\(vault.vaultId).1melon", e.file)
            XCTAssertEqual(try Self.json(vault.meta), e.meta)
            XCTAssertEqual(try vault.items.map(Self.json), e.items)
        }
        // 附件文件（spec §3.5）：每个都被引用、用引用里的密钥解开后等于期望的明文
        XCTAssertFalse(expect.attachments.isEmpty)
        XCTAssertEqual(Set(repo.localAttachmentIds()), Set(expect.attachments.map(\.ref.id)))
        let refs = loaded.vaults.reduce(into: [String: AttachmentRef]()) { $0.merge($1.attachmentRefs) { a, _ in a } }
        for a in expect.attachments {
            XCTAssertEqual(a.file, "\(a.ref.id).1melon")
            XCTAssertEqual(refs[a.ref.id], a.ref)
            XCTAssertEqual(try repo.readAttachment(a.ref, accountId: expect.accountId), a.plaintext)
        }
        XCTAssertThrowsError(try AccountRepository(root: Self.example).unlock(password: expect.wrongPassword)) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    struct TamperCase: Decodable {
        let file: String
        /// account：当账户文件用主密码打开；vault：用示例账户打开；attachment：用 expected.json 里 `attachmentId` 的引用打开
        let target: String
        let attachmentId: String?
        let expect: String
        let what: String
    }

    func testTamperedFilesAreRejected() throws {
        let cases = try JSONDecoder().decode([TamperCase].self,
                                             from: Data(contentsOf: Self.dir.appendingPathComponent("tamper/cases.json")))
        XCTAssertFalse(cases.isEmpty)
        let account = try Self.loadExampleAccount()
        let refs = Dictionary(uniqueKeysWithValues: try Self.loadExpectation().attachments.map { ($0.ref.id, $0.ref) })
        for c in cases {
            let data = try Data(contentsOf: Self.dir.appendingPathComponent("tamper/\(c.file)"))
            XCTAssertThrowsError(
                try {
                    switch c.target {
                    case "account": _ = try UnlockedAccount.open(data, password: Self.password)
                    case "attachment":
                        guard let id = c.attachmentId, let ref = refs[id] else { throw VaultError.invalidFormat("用例没有对应的引用") }
                        _ = try AttachmentFile.open(data, ref: ref, accountId: account.accountId)
                    default: _ = try UnlockedVault.open(data, account: account)
                    }
                }(),
                c.file
            ) { error in
                XCTAssertEqual(Self.kind(error), c.expect, "\(c.file)：\(c.what)")
            }
        }
    }

    static func kind(_ error: Error) -> String {
        switch error as? VaultError {
        case .invalidFormat?: "invalidFormat"
        case .unsupportedVersion?: "unsupportedVersion"
        case .unsafeKDFParameters?: "unsafeKDFParameters"
        case .wrongPassword?: "wrongPassword"
        case .tampered?: "tampered"
        case .secretKeyRequired?: "secretKeyRequired"
        case .wrongSecretKey?: "wrongSecretKey"
        case nil: "other: \(error)"
        }
    }

    /// 明文的标准 JSON 形式：条目 = 明文字段 + id + rev
    static func json(_ item: VaultItem) throws -> JSONValue {
        guard case .object(var o) = try roundTrip(ItemPlaintext(item)) else { throw VaultError.invalidFormat("") }
        o["id"] = .string(item.id)
        o["rev"] = .number(Double(item.rev))
        return .object(o)
    }

    static func json(_ meta: VaultMeta) throws -> JSONValue { try roundTrip(meta) }

    static func roundTrip<T: Encodable>(_ v: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
    }

    // MARK: 生成（MELON_REGEN_VECTORS=1）

    func testRegenerateVectors() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MELON_REGEN_VECTORS"] == "1", "设置 MELON_REGEN_VECTORS=1 才重新生成向量")
        let fm = FileManager.default
        for old in ["example", "tamper", "vault-v1.1melon", "vault-v1.json"] {
            try? fm.removeItem(at: Self.dir.appendingPathComponent(old))
        }
        try fm.createDirectory(at: Self.dir.appendingPathComponent("tamper"), withIntermediateDirectories: true)
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        // kdf.json：主密码 → KEK
        var kdfCases: [JSONValue] = []
        for (name, pw, saltByte) in [
            ("ascii", "password", UInt8(0x11)),
            ("中文与符号", "主密码：瓜！🍉", 0x22),
            ("NFC：组合形式", "caf\u{00E9}", 0x33),
            ("NFC：分解形式（必须与上一条得到相同的 KEK）", "cafe\u{0301}", 0x33),
        ] {
            let salt = Data(repeating: saltByte, count: 16)
            let kdf = KDFParameters(alg: KDFParameters.algorithm, memKiB: 65_536, iterations: 2, parallelism: 1, salt: salt)
            let kek = try UnlockedAccount.deriveKEK(password: pw, kdf: kdf)
            kdfCases.append(.object([
                "name": .string(name), "password": .string(pw), "salt": .string(salt.base64EncodedString()),
                "memKiB": .number(65_536), "iterations": .number(2), "parallelism": .number(1),
                "kek": .string(kek.withUnsafeBytes { hex(Array($0)) }),
            ]))
        }
        try pretty.encode(JSONValue.object([
            "description": .string("主密码 → KEK（spec §2）：NFC 规范化 → UTF-8 → Argon2id v1.3，输出 32 字节"),
            "cases": .array(kdfCases),
        ])).write(to: Self.dir.appendingPathComponent("kdf.json"))

        // example/：一个账户、两个保险库，虚构数据，覆盖每种已知类型、每种字段类型、多个分组、墓碑、搬移和向前兼容
        var kdf = testKDF
        kdf.salt = randomBytes(16)
        let repo = AccountRepository(root: Self.example)
        let created = try repo.create(password: Self.password, now: t0, kdf: kdf)
        let account = created.account
        var personal = created.vaults[0]
        var work = try UnlockedVault.create(in: account, meta: VaultMeta(name: "工作", icon: "briefcase", color: "green", order: 1, created: t0 + 1))

        var login = VaultItem.fromTemplate(.login, title: "示例网站", now: t0)
        login.favorite = true
        login.tags = ["示例", "开发"]
        login.sections[0].fields[0].value = "demo"
        login.sections[0].fields[1].value = "v7#Qm2!xLp9@Tz4K"
        login.sections[0].fields[2].value = "example.com"
        login.sections[0].fields.append(ItemField(label: "邮箱", kind: .email, value: "demo@example.com"))
        login.sections[1].fields[0].value = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        login.sections.append(ItemSection(title: "安全问题", fields: [
            ItemField(label: "小学校名", kind: .secret, value: "示例小学"),
            ItemField(label: "备用电话", kind: .phone, value: "+86 138 0000 0000"),
        ]))
        login.iconData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG 文件头，示意
        login.iconHost = "example.com"
        login.ignoredIssues = ["no2fa"]
        personal.save(login, now: t0)

        var card = VaultItem.fromTemplate(.card, title: "示例信用卡", now: t0 + 1000)
        card.sections[0].fields[1].value = "4111 1111 1111 1111"
        card.sections[0].fields[2].value = "2029-08"
        card.sections[0].fields[3].value = "123"
        card.notes = "测试卡号，不是真卡"
        personal.save(card, now: t0 + 1000)

        var note = VaultItem.fromTemplate(.note, title: "示例笔记", now: t0 + 2000)
        note.notes = "第一行\n第二行，含 emoji 🍉 和 \"引号\""
        personal.save(note, now: t0 + 2000)

        var future = VaultItem.fromTemplate(ItemType(rawValue: "passkey"), title: "未来版本的类型", now: t0 + 3000)
        var futureField = ItemField(label: "凭据", kind: FieldKind(rawValue: "webauthn"), value: "opaque")
        futureField.extras = ["algorithm": .string("ES256")]
        future.sections = [ItemSection(title: "Passkey", fields: [futureField])]
        future.extras = ["color": .string("orange")]
        personal.save(future, now: t0 + 3000)

        let doomed = VaultItem.fromTemplate(.wifi, title: "要删除的条目", now: t0 + 4000)
        personal.save(doomed, now: t0 + 4000)
        personal.delete(id: doomed.id, now: t0 + 5000)

        var identity = VaultItem.fromTemplate(.identity, title: "示例证件", now: t0 + 6000)
        identity.sections[0].fields[0].value = "张三"
        identity.sections[0].fields[1].value = "E00000000"
        identity.sections[0].fields[2].value = "1990-01-01"
        work.save(identity, now: t0 + 6000)
        var ssh = VaultItem.fromTemplate(.ssh, title: "示例服务器", now: t0 + 7000)
        ssh.sections[0].fields[0].value = "host.example.com:22"
        ssh.sections[0].fields[1].value = "deploy"
        // 文件附件（保险库版本 2）：附件文件单独存，字段里只有引用。内容是演示用的假数据
        let keyPlain = Data("1Melon 演示附件：不是真的密钥\n".utf8)
        let (keyRef, keyFileData) = try AttachmentFile.seal(keyPlain, accountId: account.accountId)
        try VaultStore.write(keyFileData, to: repo.attachmentURL(keyRef.id))
        var keyFile = ItemField(label: "密钥文件", kind: .file)
        keyFile.attach(keyRef, name: "demo_key.txt")
        ssh.sections[0].fields.append(keyFile)
        work.save(ssh, now: t0 + 7000)
        // 搬移：个人里的卡搬到工作，个人里留墓碑
        UnlockedVault.move(card.id, from: &personal, to: &work, now: t0 + 8000)

        let personalV1 = try personal.serialized(now: t0 + 8000)
        var edited = personal.items[0]
        edited.notes = "改过一次"
        personal.save(edited, now: t0 + 9000)
        try repo.save(&personal, now: t0 + 9000)
        try repo.save(&work, now: t0 + 9000)

        let loaded = repo.loadVaults(account)
        let expectation: JSONValue = .object([
            "description": .string("example/ 用 password 解开后应得到的明文：保险库按 meta.order 排序，条目按文件顺序，含墓碑"),
            "password": .string(Self.password),
            "wrongPassword": .string("correct horse battery staple · 1melon"),
            "accountId": .string(account.accountId),
            "vaults": .array(try loaded.vaults.map { v in
                .object([
                    "file": .string("\(v.vaultId).1melon"), "vaultId": .string(v.vaultId),
                    "meta": try Self.json(v.meta), "items": .array(try v.items.map(Self.json)),
                ])
            }),
            "attachments": .array([.object([
                "file": .string("\(keyRef.id).1melon"), "ref": try Self.roundTrip(keyRef),
                "plaintext": .string(keyPlain.base64EncodedString()),
            ])]),
        ])
        try pretty.encode(expectation).write(to: Self.example.appendingPathComponent("expected.json"))

        // tamper/：每个都必须拒绝打开
        let accountData = try Data(contentsOf: repo.accountURL)
        let personalData = try Data(contentsOf: repo.vaultURL(personal.vaultId))
        let workData = try Data(contentsOf: repo.vaultURL(work.vaultId))
        func edit(_ base: Data, _ f: (inout [String: JSONValue]) throws -> Void) throws -> Data {
            var top = try jsonObject(base)
            try f(&top)
            return try pretty.encode(top)
        }
        func items(_ top: [String: JSONValue]) -> [JSONValue] {
            guard case .array(let a)? = top["items"] else { return [] }
            return a
        }
        func flip(_ b64: JSONValue?) -> JSONValue {
            guard case .string(let s)? = b64, var d = Data(base64Encoded: s) else { return .null }
            d[d.startIndex] ^= 0x01
            return .string(d.base64EncodedString())
        }
        func kdfEdit(_ key: String, _ value: JSONValue) throws -> Data {
            try edit(accountData) {
                guard case .object(var k)? = $0["kdf"] else { return }
                k[key] = value
                $0["kdf"] = .object(k)
            }
        }
        let oldLogin = items(try jsonObject(personalV1))[0]

        let cases: [(String, String, String, String, Data)] = [
            ("account-kdf-weak.1melon", "account", "unsafeKDFParameters", "KDF 内存参数被改成 8 MiB（降级攻击）", try kdfEdit("memKiB", .number(8192))),
            ("account-kdf-huge.1melon", "account", "unsafeKDFParameters", "KDF 内存参数被改成 4 GiB（会把机器卡死）", try kdfEdit("memKiB", .number(4_194_304))),
            ("account-version-future.1melon", "account", "unsupportedVersion", "账户格式版本是 3", try edit(accountData) { $0["version"] = .number(3) }),
            ("account-secret-key.1melon", "account", "invalidFormat", "v1 账户文件要求 Secret Key（只有 v2 才能要求）", try edit(accountData) { $0["secretKey"] = .string("required") }),
            ("account-id-changed.1melon", "account", "wrongPassword", "accountId 被改（AAD 对不上，表现为密码错误）", try edit(accountData) { $0["accountId"] = .string(newID()) }),
            ("vault-version-future.1melon", "vault", "unsupportedVersion", "保险库格式版本是 3", try edit(personalData) { $0["version"] = .number(3) }),
            ("vault-foreign-account.1melon", "vault", "invalidFormat", "保险库声明属于另一个账户", try edit(personalData) { $0["accountId"] = .string(newID()) }),
            ("vault-id-changed.1melon", "vault", "tampered", "vaultId 被改（保险库密钥的 AAD 对不上）", try edit(personalData) { $0["vaultId"] = .string(newID()) }),
            ("vault-key-swapped.1melon", "vault", "tampered", "换成另一个保险库的 wrappedKey", try edit(personalData) {
                $0["wrappedKey"] = try jsonObject(workData)["wrappedKey"]
            }),
            ("vault-item-removed.1melon", "vault", "tampered", "删掉了一个条目", try edit(personalData) {
                var a = items($0); a.remove(at: 1); $0["items"] = .array(a)
            }),
            ("vault-item-rollback.1melon", "vault", "tampered", "把登录条目换回旧版本（旧的 id/rev/密文都是真的）", try edit(personalData) {
                var a = items($0); a[0] = oldLogin; $0["items"] = .array(a)
            }),
            ("vault-item-rev-edited.1melon", "vault", "tampered", "只把条目的 rev 改小（AAD 对不上）", try edit(personalData) {
                var a = items($0)
                guard case .object(var o) = a[0], case .number(let r)? = o["rev"] else { return }
                o["rev"] = .number(r - 1); a[0] = .object(o); $0["items"] = .array(a)
            }),
            ("vault-item-ciphertext-swapped.1melon", "vault", "tampered", "两个条目的密文互换（AAD 绑定了 id）", try edit(personalData) {
                var a = items($0)
                guard case .object(var x) = a[0], case .object(var y) = a[2] else { return }
                (x["nonce"], y["nonce"]) = (y["nonce"], x["nonce"])
                (x["ct"], y["ct"]) = (y["ct"], x["ct"])
                a[0] = .object(x); a[2] = .object(y); $0["items"] = .array(a)
            }),
            ("vault-item-bitflip.1melon", "vault", "tampered", "条目密文翻转了一位", try edit(personalData) {
                var a = items($0)
                guard case .object(var o) = a[2] else { return }
                o["ct"] = flip(o["ct"]); a[2] = .object(o); $0["items"] = .array(a)
            }),
            ("vault-index-meta-swapped.1melon", "vault", "tampered", "索引和元数据的密文互换", try edit(personalData) {
                ($0["index"], $0["meta"]) = ($0["meta"], $0["index"])
            }),
        ]
        // 附件：用 expected.json 里的引用打开
        func attachmentEdit(_ f: (inout [String: JSONValue]) -> Void) throws -> Data { try edit(keyFileData, f) }
        let attachmentCases: [(String, String, String, Data)] = [
            ("attachment-version-future.1melon", "unsupportedVersion", "附件格式版本是 2", try attachmentEdit { $0["version"] = .number(2) }),
            ("attachment-foreign-account.1melon", "invalidFormat", "附件声明属于另一个账户", try attachmentEdit { $0["accountId"] = .string(newID()) }),
            ("attachment-id-changed.1melon", "tampered", "attachmentId 被改（和引用对不上）", try attachmentEdit { $0["attachmentId"] = .string(newID()) }),
            ("attachment-bitflip.1melon", "tampered", "附件密文翻转了一位", try attachmentEdit {
                guard case .object(var c)? = $0["content"] else { return }
                c["ct"] = flip(c["ct"]); $0["content"] = .object(c)
            }),
        ]
        for c in cases { try c.4.write(to: Self.dir.appendingPathComponent("tamper/\(c.0)")) }
        for c in attachmentCases { try c.3.write(to: Self.dir.appendingPathComponent("tamper/\(c.0)")) }
        try pretty.encode(JSONValue.array(cases.map {
            .object(["file": .string($0.0), "target": .string($0.1), "expect": .string($0.2), "what": .string($0.3)])
        } + attachmentCases.map {
            .object(["file": .string($0.0), "target": .string("attachment"), "attachmentId": .string(keyRef.id),
                     "expect": .string($0.1), "what": .string($0.2)])
        })).write(to: Self.dir.appendingPathComponent("tamper/cases.json"))
    }
}

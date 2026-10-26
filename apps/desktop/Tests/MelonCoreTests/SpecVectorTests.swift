import Foundation
import XCTest
@testable import MelonCore

/// 跨端测试向量（spec §7）。校验每次都跑；生成只在 `MELON_REGEN_VECTORS=1` 时跑，
/// 而且向量一旦提交，除非同时升格式版本，否则不能为了让测试通过去改它。
final class SpecVectorTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("spec/test-vectors")

    static let vaultPassword = "correct horse battery staple · 1Melon"

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
            let kek = try UnlockedVault.deriveKEK(password: c.password, kdf: kdf)
            XCTAssertEqual(kek.withUnsafeBytes { hex(Array($0)) }, c.kek, c.name)
        }
    }

    struct VaultExpectation: Decodable {
        let password: String
        let wrongPassword: String
        let vaultId: String
        let meta: JSONValue
        let items: [JSONValue]
    }

    func testExampleVault() throws {
        let data = try Data(contentsOf: Self.dir.appendingPathComponent("vault-v1.1melon"))
        let expect = try JSONDecoder().decode(VaultExpectation.self,
                                              from: Data(contentsOf: Self.dir.appendingPathComponent("vault-v1.json")))
        let vault = try UnlockedVault.open(data, password: expect.password)
        XCTAssertEqual(vault.vaultId, expect.vaultId)
        XCTAssertEqual(try Self.json(vault.meta), expect.meta)
        XCTAssertEqual(try vault.items.map(Self.json), expect.items)
        XCTAssertThrowsError(try UnlockedVault.open(data, password: expect.wrongPassword)) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    struct TamperCase: Decodable {
        let file: String
        let expect: String
        let what: String
    }

    func testTamperedFilesAreRejected() throws {
        let cases = try JSONDecoder().decode([TamperCase].self,
                                             from: Data(contentsOf: Self.dir.appendingPathComponent("tamper/cases.json")))
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let data = try Data(contentsOf: Self.dir.appendingPathComponent("tamper/\(c.file)"))
            XCTAssertThrowsError(try UnlockedVault.open(data, password: Self.vaultPassword), c.file) { error in
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
        try fm.createDirectory(at: Self.dir.appendingPathComponent("tamper"), withIntermediateDirectories: true)
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        // kdf.json
        var kdfCases: [[String: JSONValue]] = []
        for (name, pw, saltByte) in [
            ("ascii", "password", UInt8(0x11)),
            ("中文与符号", "主密码：瓜！🍉", 0x22),
            ("NFC：组合形式", "caf\u{00E9}", 0x33),
            ("NFC：分解形式（必须与上一条得到相同的 KEK）", "cafe\u{0301}", 0x33),
        ] {
            let salt = Data(repeating: saltByte, count: 16)
            let kdf = KDFParameters(alg: KDFParameters.algorithm, memKiB: 65_536, iterations: 2, parallelism: 1, salt: salt)
            let kek = try UnlockedVault.deriveKEK(password: pw, kdf: kdf)
            kdfCases.append([
                "name": .string(name), "password": .string(pw), "salt": .string(salt.base64EncodedString()),
                "memKiB": .number(65_536), "iterations": .number(2), "parallelism": .number(1),
                "kek": .string(kek.withUnsafeBytes { hex(Array($0)) }),
            ])
        }
        let kdfDoc: [String: JSONValue] = [
            "description": .string("主密码 → KEK（spec §2）：NFC 规范化 → UTF-8 → Argon2id v1.3，输出 32 字节"),
            "cases": .array(kdfCases.map(JSONValue.object)),
        ]
        try pretty.encode(kdfDoc).write(to: Self.dir.appendingPathComponent("kdf.json"))

        // vault-v1.1melon + vault-v1.json：虚构数据，覆盖每种已知类型、TOTP、墓碑和向前兼容
        var kdf = testKDF
        kdf.salt = randomBytes(16)
        var vault = try UnlockedVault.create(password: Self.vaultPassword, name: "测试保险库", now: t0, kdf: kdf)
        var login = UnlockedVault.newItem(type: .login, title: "示例网站", now: t0)
        login.icon = "globe"
        login.favorite = true
        login.tags = ["示例", "开发"]
        login.fields = [
            ItemField(id: "f1", label: "用户名", kind: .text, value: "demo@example.com"),
            ItemField(id: "f2", label: "密码", kind: .password, value: "v7#Qm2!xLp9@Tz4K"),
            ItemField(id: "f3", label: "网站", kind: .url, value: "example.com"),
            ItemField(id: "f4", label: "两步验证密钥", kind: .totp, value: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"),
        ]
        vault.save(login, now: t0)
        var card = UnlockedVault.newItem(type: .card, title: "示例信用卡", now: t0 + 1000)
        card.fields = [
            ItemField(id: "f1", label: "卡号", kind: .mono, value: "4111 1111 1111 1111"),
            ItemField(id: "f2", label: "CVV", kind: .secret, value: "123"),
        ]
        card.notes = "测试卡号，不是真卡"
        vault.save(card, now: t0 + 1000)
        var note = UnlockedVault.newItem(type: .note, title: "示例笔记", now: t0 + 2000)
        note.notes = "第一行\n第二行，含 emoji 🍉 和 \"引号\""
        vault.save(note, now: t0 + 2000)
        var future = UnlockedVault.newItem(type: ItemType(rawValue: "passkey"), title: "未来版本的类型", now: t0 + 3000)
        var futureField = ItemField(id: "f1", label: "凭据", kind: FieldKind(rawValue: "webauthn"), value: "opaque")
        futureField.extras = ["algorithm": .string("ES256")]
        future.fields = [futureField]
        future.extras = ["color": .string("orange")]
        vault.save(future, now: t0 + 3000)
        let doomed = UnlockedVault.newItem(type: .wifi, title: "要删除的条目", now: t0 + 4000)
        vault.save(doomed, now: t0 + 4000)
        vault.delete(id: doomed.id, now: t0 + 5000)

        let v1 = try vault.serialized(now: t0 + 5000)
        // 再改一次登录条目，得到 v2；v1 里的旧版本用来构造「回退」篡改
        var edited = vault.items[0]
        edited.notes = "改过一次"
        vault.save(edited, now: t0 + 6000)
        let v2 = try vault.serialized(now: t0 + 6000)
        try v2.write(to: Self.dir.appendingPathComponent("vault-v1.1melon"))

        let expectation: [String: JSONValue] = [
            "description": .string("vault-v1.1melon 用 password 解开后应得到的明文；条目按文件顺序，含墓碑"),
            "password": .string(Self.vaultPassword),
            "wrongPassword": .string("correct horse battery staple · 1melon"),
            "vaultId": .string(vault.vaultId),
            "meta": try Self.json(vault.meta),
            "items": .array(try vault.items.map(Self.json)),
        ]
        try pretty.encode(expectation).write(to: Self.dir.appendingPathComponent("vault-v1.json"))

        // tamper/：每个都必须拒绝打开
        func edit(_ base: Data, _ f: (inout [String: JSONValue]) throws -> Void) throws -> Data {
            var top = try JSONDecoder().decode([String: JSONValue].self, from: base)
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
        let oldLogin = items(try JSONDecoder().decode([String: JSONValue].self, from: v1))[0]

        let cases: [(String, String, String, Data)] = [
            ("kdf-weak.1melon", "unsafeKDFParameters", "KDF 内存参数被改成 8 MiB（降级攻击）", try edit(v2) {
                guard case .object(var k)? = $0["kdf"] else { return }
                k["memKiB"] = .number(8192); $0["kdf"] = .object(k)
            }),
            ("kdf-huge.1melon", "unsafeKDFParameters", "KDF 内存参数被改成 4 GiB（会把机器卡死）", try edit(v2) {
                guard case .object(var k)? = $0["kdf"] else { return }
                k["memKiB"] = .number(4_194_304); $0["kdf"] = .object(k)
            }),
            ("version-future.1melon", "unsupportedVersion", "格式版本是 2（比客户端新）", try edit(v2) { $0["version"] = .number(2) }),
            ("item-removed.1melon", "tampered", "删掉了一个条目", try edit(v2) {
                var a = items($0); a.remove(at: 1); $0["items"] = .array(a)
            }),
            ("item-rollback.1melon", "tampered", "把登录条目换回旧版本（旧的 id/rev/密文都是真的）", try edit(v2) {
                var a = items($0); a[0] = oldLogin; $0["items"] = .array(a)
            }),
            ("item-rev-edited.1melon", "tampered", "只把条目的 rev 改小（AAD 对不上）", try edit(v2) {
                var a = items($0)
                guard case .object(var o) = a[0], case .number(let r)? = o["rev"] else { return }
                o["rev"] = .number(r - 1); a[0] = .object(o); $0["items"] = .array(a)
            }),
            ("item-ciphertext-swapped.1melon", "tampered", "两个条目的密文互换（AAD 绑定了 id）", try edit(v2) {
                var a = items($0)
                guard case .object(var x) = a[0], case .object(var y) = a[1] else { return }
                (x["nonce"], y["nonce"]) = (y["nonce"], x["nonce"])
                (x["ct"], y["ct"]) = (y["ct"], x["ct"])
                a[0] = .object(x); a[1] = .object(y); $0["items"] = .array(a)
            }),
            ("item-bitflip.1melon", "tampered", "条目密文翻转了一位", try edit(v2) {
                var a = items($0)
                guard case .object(var o) = a[2] else { return }
                o["ct"] = flip(o["ct"]); a[2] = .object(o); $0["items"] = .array(a)
            }),
            ("index-meta-swapped.1melon", "tampered", "索引和元数据的密文互换", try edit(v2) {
                ($0["index"], $0["meta"]) = ($0["meta"], $0["index"])
            }),
            ("vault-id-changed.1melon", "wrongPassword", "vaultId 被改（包装密钥的 AAD 对不上，表现为密码错误）", try edit(v2) {
                $0["vaultId"] = .string(UUID().uuidString.lowercased())
            }),
        ]
        for (file, _, _, data) in cases { try data.write(to: Self.dir.appendingPathComponent("tamper/\(file)")) }
        let caseDoc = JSONValue.array(cases.map { .object(["file": .string($0.0), "expect": .string($0.1), "what": .string($0.2)]) })
        try pretty.encode(caseDoc).write(to: Self.dir.appendingPathComponent("tamper/cases.json"))
    }
}

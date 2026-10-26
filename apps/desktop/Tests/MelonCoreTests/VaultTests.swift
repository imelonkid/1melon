import Crypto
import Foundation
import XCTest
@testable import MelonCore

/// 测试用的最低 KDF 参数（64 MiB、2 次），比默认值快，又不低于打开时的下限。
let testKDF = KDFParameters(alg: KDFParameters.algorithm, memKiB: 65_536, iterations: 2, parallelism: 1,
                            salt: Data(repeating: 0x5A, count: 16))
let t0: Int64 = 1_761_400_000_000

func sampleLogin(_ now: Int64) -> VaultItem {
    var item = UnlockedVault.newItem(type: .login, title: "GitHub", now: now)
    item.fields = [
        ItemField(id: "f1", label: "用户名", kind: .text, value: "demo-user"),
        ItemField(id: "f2", label: "密码", kind: .password, value: "v7#Qm2!xLp9@Tz4K"),
    ]
    return item
}

final class VaultTests: XCTestCase {
    func testCreateSaveOpenRoundTrip() throws {
        var vault = try UnlockedVault.create(password: "主密码 correct horse", name: "个人保险库", now: t0, kdf: testKDF)
        vault.save(sampleLogin(t0), now: t0)
        let data = try vault.serialized(now: t0)

        let reopened = try UnlockedVault.open(data, password: "主密码 correct horse")
        XCTAssertEqual(reopened.vaultId, vault.vaultId)
        XCTAssertEqual(reopened.meta, vault.meta)
        XCTAssertEqual(reopened.items, vault.items)
        XCTAssertEqual(reopened.items.first?.rev, 1)
    }

    func testWrongPassword() throws {
        var vault = try UnlockedVault.create(password: "right", name: "v", now: t0, kdf: testKDF)
        let data = try vault.serialized(now: t0)
        XCTAssertThrowsError(try UnlockedVault.open(data, password: "wrong")) { XCTAssertEqual($0 as? VaultError, .wrongPassword) }
    }

    func testPasswordIsNFCNormalized() throws {
        var vault = try UnlockedVault.create(password: "caf\u{00E9}", name: "v", now: t0, kdf: testKDF)
        let data = try vault.serialized(now: t0)
        XCTAssertNoThrow(try UnlockedVault.open(data, password: "cafe\u{0301}"))
    }

    func testSaveBumpsRevAndKeepsCreated() throws {
        var vault = try UnlockedVault.create(password: "p", name: "v", now: t0, kdf: testKDF)
        var item = sampleLogin(t0)
        vault.save(item, now: t0)
        item = vault.items[0]
        item.title = "GitHub（工作）"
        item.created = 0 // 调用方传错也不影响
        vault.save(item, now: t0 + 1000)
        XCTAssertEqual(vault.items.count, 1)
        XCTAssertEqual(vault.items[0].rev, 2)
        XCTAssertEqual(vault.items[0].created, t0)
        XCTAssertEqual(vault.items[0].modified, t0 + 1000)
    }

    func testDeleteLeavesTombstone() throws {
        var vault = try UnlockedVault.create(password: "p", name: "v", now: t0, kdf: testKDF)
        let item = sampleLogin(t0)
        vault.save(item, now: t0)
        vault.delete(id: item.id, now: t0 + 1)
        XCTAssertEqual(vault.items.count, 1)
        XCTAssertTrue(vault.activeItems.isEmpty)
        let tomb = vault.items[0]
        XCTAssertTrue(tomb.deleted)
        XCTAssertEqual(tomb.rev, 2)
        XCTAssertTrue(tomb.fields.isEmpty && tomb.title.isEmpty && tomb.notes.isEmpty)

        let reopened = try UnlockedVault.open(try vault.serialized(now: t0 + 1), password: "p")
        XCTAssertEqual(reopened.items, vault.items)
    }

    func testChangePasswordKeepsItemCiphertext() throws {
        var vault = try UnlockedVault.create(password: "old", name: "v", now: t0, kdf: testKDF)
        vault.save(sampleLogin(t0), now: t0)
        let before = try JSONDecoder().decode(VaultFile.self, from: try vault.serialized(now: t0))
        var newKDF = testKDF
        newKDF.salt = Data(repeating: 0x33, count: 16)
        try vault.changePassword(to: "new", kdf: newKDF)
        let data = try vault.serialized(now: t0)
        let after = try JSONDecoder().decode(VaultFile.self, from: data)

        XCTAssertEqual(before.items, after.items)
        XCTAssertNotEqual(before.wrappedKey, after.wrappedKey)
        XCTAssertThrowsError(try UnlockedVault.open(data, password: "old"))
        XCTAssertNoThrow(try UnlockedVault.open(data, password: "new"))
    }

    func testOpenWithVaultKey() throws {
        var vault = try UnlockedVault.create(password: "p", name: "v", now: t0, kdf: testKDF)
        vault.save(sampleLogin(t0), now: t0)
        let data = try vault.serialized(now: t0)
        let reopened = try UnlockedVault.open(data, vaultKey: vault.vaultKeyForLocalUnlock)
        XCTAssertEqual(reopened.items, vault.items)
        XCTAssertThrowsError(try UnlockedVault.open(data, vaultKey: SymmetricKey(size: .bits256)))
    }

    /// spec §5「向前兼容」：不认识的键、类型、字段种类都要原样保留。
    func testUnknownKeysSurviveRoundTrip() throws {
        var vault = try UnlockedVault.create(password: "p", name: "v", now: t0, kdf: testKDF)
        var item = UnlockedVault.newItem(type: ItemType(rawValue: "passkey"), title: "未来的类型", now: t0)
        var field = ItemField(id: "f1", label: "凭据", kind: FieldKind(rawValue: "webauthn"), value: "x")
        field.extras = ["algorithm": .string("ES256")]
        item.fields = [field]
        item.extras = ["color": .string("orange"), "nested": .object(["a": .array([.number(1), .bool(true), .null])])]
        vault.save(item, now: t0)
        vault.meta.extras = ["syncedAt": .number(123)]

        var data = try vault.serialized(now: t0)
        // 文件顶层加一个不认识的键
        var top = try JSONDecoder().decode([String: JSONValue].self, from: data)
        top["futureHeader"] = .string("keep me")
        data = try JSONEncoder().encode(top)

        var reopened = try UnlockedVault.open(data, password: "p")
        XCTAssertEqual(reopened.items, vault.items)
        XCTAssertEqual(reopened.meta, vault.meta)
        XCTAssertFalse(reopened.items[0].type.isKnown)

        let rewritten = try JSONDecoder().decode([String: JSONValue].self, from: try reopened.serialized(now: t0 + 1))
        XCTAssertEqual(rewritten["futureHeader"], .string("keep me"))
    }

    func testUnchangedItemsKeepCiphertext() throws {
        var vault = try UnlockedVault.create(password: "p", name: "v", now: t0, kdf: testKDF)
        let a = sampleLogin(t0), b = sampleLogin(t0)
        vault.save(a, now: t0)
        vault.save(b, now: t0)
        let first = try JSONDecoder().decode(VaultFile.self, from: try vault.serialized(now: t0))
        var edited = vault.items[1]
        edited.notes = "改了"
        vault.save(edited, now: t0 + 1)
        let second = try JSONDecoder().decode(VaultFile.self, from: try vault.serialized(now: t0 + 1))
        XCTAssertEqual(first.items[0], second.items[0])
        XCTAssertNotEqual(first.items[1], second.items[1])
    }

    func testRejectsBadKDFBeforeDerivingKey() throws {
        var vault = try UnlockedVault.create(password: "p", name: "v", now: t0, kdf: testKDF)
        let data = try vault.serialized(now: t0)
        for (key, value) in [("memKiB", JSONValue.number(8192)), ("memKiB", .number(4_194_304)),
                             ("iterations", .number(1)), ("parallelism", .number(4)), ("alg", .string("argon2i13"))] {
            var top = try JSONDecoder().decode([String: JSONValue].self, from: data)
            guard case .object(var kdf)? = top["kdf"] else { return XCTFail() }
            kdf[key] = value
            top["kdf"] = .object(kdf)
            XCTAssertThrowsError(try UnlockedVault.open(try JSONEncoder().encode(top), password: "p"), key) {
                guard case .unsafeKDFParameters = $0 as? VaultError else { return XCTFail("\(key): \($0)") }
            }
        }
    }

    func testRejectsNonVaultFiles() {
        XCTAssertThrowsError(try UnlockedVault.open(Data("not json".utf8), password: "p")) {
            guard case .invalidFormat = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try UnlockedVault.open(Data(#"{"format":"other","version":1}"#.utf8), password: "p")) {
            guard case .invalidFormat = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try UnlockedVault.open(Data(#"{"format":"1melon-vault","version":7}"#.utf8), password: "p")) {
            XCTAssertEqual($0 as? VaultError, .unsupportedVersion(7))
        }
    }
}

final class VaultStoreTests: XCTestCase {
    func testAtomicWriteReplacesAndRestrictsPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("1melon-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vault.1melon")
        try VaultStore.write(Data("one".utf8), to: url)
        try VaultStore.write(Data("two".utf8), to: url)
        XCTAssertEqual(try VaultStore.read(url), Data("two".utf8))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        // 不留临时文件
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["vault.1melon"])
    }
}

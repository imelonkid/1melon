import Crypto
import Foundation
import XCTest
@testable import MelonCore

/// 测试用的最低 KDF 参数（64 MiB、2 次），比默认值快，又不低于打开时的下限。
let testKDF = KDFParameters(alg: KDFParameters.algorithm, memKiB: 65_536, iterations: 2, parallelism: 1,
                            salt: Data(repeating: 0x5A, count: 16))
let t0: Int64 = 1_761_400_000_000
/// 整个测试进程共用一个账户，免得每个测试都跑一遍 KDF
let testAccount = try! UnlockedAccount.create(password: "主密码 correct horse", kdf: testKDF)

func sampleLogin(_ now: Int64, title: String = "GitHub") -> VaultItem {
    var item = VaultItem.fromTemplate(.login, title: title, now: now)
    item.sections[0].fields[0].value = "demo-user"
    item.sections[0].fields[1].value = "v7#Qm2!xLp9@Tz4K"
    return item
}

func newVault(_ name: String = "个人", account: UnlockedAccount = testAccount) throws -> UnlockedVault {
    try UnlockedVault.create(in: account, meta: VaultMeta(name: name, created: t0))
}

func jsonObject(_ data: Data) throws -> [String: JSONValue] { try JSONDecoder().decode([String: JSONValue].self, from: data) }

final class AccountTests: XCTestCase {
    func testOpenWithPassword() throws {
        let data = try testAccount.serialized()
        let reopened = try UnlockedAccount.open(data, password: "主密码 correct horse")
        XCTAssertEqual(reopened.accountId, testAccount.accountId)
        XCTAssertThrowsError(try UnlockedAccount.open(data, password: "wrong")) { XCTAssertEqual($0 as? VaultError, .wrongPassword) }
    }

    func testPasswordIsNFCNormalized() throws {
        let account = try UnlockedAccount.create(password: "caf\u{00E9}", kdf: testKDF)
        XCTAssertNoThrow(try UnlockedAccount.open(try account.serialized(), password: "cafe\u{0301}"))
    }

    func testChangePasswordKeepsAccountKeySoVaultsStillOpen() throws {
        var account = try UnlockedAccount.create(password: "old", kdf: testKDF)
        var vault = try newVault(account: account)
        vault.save(sampleLogin(t0), now: t0)
        let vaultData = try vault.serialized(now: t0)

        var newKDF = testKDF
        newKDF.salt = Data(repeating: 0x33, count: 16)
        try account.changePassword(to: "new", kdf: newKDF)
        let data = try account.serialized()
        XCTAssertThrowsError(try UnlockedAccount.open(data, password: "old"))
        let reopened = try UnlockedAccount.open(data, password: "new")
        XCTAssertEqual(try UnlockedVault.open(vaultData, account: reopened).items, vault.items)
    }

    func testOpenWithAccountKey() throws {
        let data = try testAccount.serialized()
        let viaKey = try UnlockedAccount.open(data, accountKey: testAccount.accountKeyForLocalUnlock)
        var vault = try newVault()
        vault.save(sampleLogin(t0), now: t0)
        XCTAssertEqual(try UnlockedVault.open(try vault.serialized(now: t0), account: viaKey).items.count, 1)
    }

    func testRejectsBadKDFBeforeDerivingKey() throws {
        let data = try testAccount.serialized()
        for (key, value) in [("memKiB", JSONValue.number(8192)), ("memKiB", .number(4_194_304)),
                             ("iterations", .number(1)), ("parallelism", .number(4)), ("alg", .string("argon2i13"))] {
            var top = try jsonObject(data)
            guard case .object(var kdf)? = top["kdf"] else { return XCTFail() }
            kdf[key] = value
            top["kdf"] = .object(kdf)
            XCTAssertThrowsError(try UnlockedAccount.open(try JSONEncoder().encode(top), password: "x"), key) {
                guard case .unsafeKDFParameters = $0 as? VaultError else { return XCTFail("\(key): \($0)") }
            }
        }
    }

    func testSecretKeyIsReservedButNotYetSupported() throws {
        var top = try jsonObject(try testAccount.serialized())
        top["secretKey"] = .string("required")
        XCTAssertThrowsError(try UnlockedAccount.open(try JSONEncoder().encode(top), password: "x")) {
            guard case .invalidFormat = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    func testRejectsNonAccountFiles() {
        XCTAssertThrowsError(try UnlockedAccount.open(Data("not json".utf8), password: "p")) {
            guard case .invalidFormat = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try UnlockedAccount.open(Data(#"{"format":"1melon-vault","version":1}"#.utf8), password: "p")) {
            guard case .invalidFormat = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try UnlockedAccount.open(Data(#"{"format":"1melon-account","version":7}"#.utf8), password: "p")) {
            XCTAssertEqual($0 as? VaultError, .unsupportedVersion(7))
        }
    }

    func testUnknownTopLevelKeysSurvive() throws {
        var top = try jsonObject(try testAccount.serialized())
        top["futureHeader"] = .string("keep me")
        let account = try UnlockedAccount.open(try JSONEncoder().encode(top), password: "主密码 correct horse")
        XCTAssertEqual(try jsonObject(try account.serialized())["futureHeader"], .string("keep me"))
    }
}

final class VaultTests: XCTestCase {
    func testCreateSaveOpenRoundTrip() throws {
        var vault = try newVault()
        vault.save(sampleLogin(t0), now: t0)
        let reopened = try UnlockedVault.open(try vault.serialized(now: t0), account: testAccount)
        XCTAssertEqual(reopened.vaultId, vault.vaultId)
        XCTAssertEqual(reopened.meta, vault.meta)
        XCTAssertEqual(reopened.items, vault.items)
        XCTAssertEqual(reopened.items.first?.rev, 1)
        XCTAssertEqual(reopened.items.first?.sections.count, 2)
    }

    func testVaultOfAnotherAccountIsRejected() throws {
        let other = try UnlockedAccount.create(password: "x", kdf: testKDF)
        var vault = try newVault(account: other)
        let data = try vault.serialized(now: t0)
        XCTAssertThrowsError(try UnlockedVault.open(data, account: testAccount)) {
            guard case .invalidFormat = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        // 只改 accountId 冒充：包装密钥的 AAD 对不上
        var top = try jsonObject(data)
        top["accountId"] = .string(testAccount.accountId)
        XCTAssertThrowsError(try UnlockedVault.open(try JSONEncoder().encode(top), account: testAccount)) {
            guard case .tampered = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    func testSaveBumpsRevAndKeepsCreated() throws {
        var vault = try newVault()
        vault.save(sampleLogin(t0), now: t0)
        var item = vault.items[0]
        item.title = "GitHub（工作）"
        item.created = 0 // 调用方传错也不影响
        vault.save(item, now: t0 + 1000)
        XCTAssertEqual(vault.items.count, 1)
        XCTAssertEqual(vault.items[0].rev, 2)
        XCTAssertEqual(vault.items[0].created, t0)
        XCTAssertEqual(vault.items[0].modified, t0 + 1000)
    }

    func testDeleteLeavesTombstone() throws {
        var vault = try newVault()
        var item = sampleLogin(t0)
        item.iconData = Data([1, 2, 3])
        item.iconHost = "github.com"
        vault.save(item, now: t0)
        vault.delete(id: item.id, now: t0 + 1)
        XCTAssertTrue(vault.activeItems.isEmpty)
        let tomb = vault.items[0]
        XCTAssertTrue(tomb.deleted)
        XCTAssertEqual(tomb.rev, 2)
        XCTAssertTrue(tomb.sections.isEmpty && tomb.title.isEmpty && tomb.notes.isEmpty && tomb.iconData == nil)
        XCTAssertEqual(try UnlockedVault.open(try vault.serialized(now: t0 + 1), account: testAccount).items, vault.items)
    }

    func testMoveBetweenVaults() throws {
        var personal = try newVault("个人"), work = try newVault("工作")
        let item = sampleLogin(t0)
        personal.save(item, now: t0)
        UnlockedVault.move(item.id, from: &personal, to: &work, now: t0 + 5)
        XCTAssertTrue(personal.activeItems.isEmpty)
        XCTAssertTrue(personal.items[0].deleted)
        XCTAssertEqual(work.activeItems.map(\.id), [item.id])
        XCTAssertEqual(work.activeItems[0].rev, 1)
        XCTAssertEqual(work.activeItems[0].sections, item.sections)
        // 搬回来：原来的墓碑被取代
        UnlockedVault.move(item.id, from: &work, to: &personal, now: t0 + 6)
        XCTAssertEqual(personal.items.count, 1)
        XCTAssertFalse(personal.items[0].deleted)
        XCTAssertNoThrow(try UnlockedVault.open(try personal.serialized(now: t0 + 6), account: testAccount))
    }

    /// spec §5「向前兼容」：不认识的键、类型、配置项类型都要原样保留。
    func testUnknownKeysSurviveRoundTrip() throws {
        var vault = try newVault()
        var item = VaultItem.fromTemplate(ItemType(rawValue: "passkey"), title: "未来的类型", now: t0)
        var field = ItemField(label: "凭据", kind: FieldKind(rawValue: "webauthn"), value: "x")
        field.extras = ["algorithm": .string("ES256")]
        var section = ItemSection(title: "Passkey", fields: [field])
        section.extras = ["collapsed": .bool(true)]
        item.sections = [section]
        item.extras = ["color": .string("orange"), "nested": .object(["a": .array([.number(1), .bool(true), .null])])]
        vault.save(item, now: t0)
        vault.meta.extras = ["syncedAt": .number(123)]

        var top = try jsonObject(try vault.serialized(now: t0))
        top["futureHeader"] = .string("keep me")
        var reopened = try UnlockedVault.open(try JSONEncoder().encode(top), account: testAccount)
        XCTAssertEqual(reopened.items, vault.items)
        XCTAssertEqual(reopened.meta, vault.meta)
        XCTAssertFalse(reopened.items[0].type.isKnown)
        XCTAssertEqual(try jsonObject(try reopened.serialized(now: t0 + 1))["futureHeader"], .string("keep me"))
    }

    func testUnchangedItemsKeepCiphertext() throws {
        var vault = try newVault()
        vault.save(sampleLogin(t0), now: t0)
        vault.save(sampleLogin(t0), now: t0)
        let first = try JSONDecoder().decode(VaultFile.self, from: try vault.serialized(now: t0))
        var edited = vault.items[1]
        edited.notes = "改了"
        vault.save(edited, now: t0 + 1)
        let second = try JSONDecoder().decode(VaultFile.self, from: try vault.serialized(now: t0 + 1))
        XCTAssertEqual(first.items[0], second.items[0])
        XCTAssertNotEqual(first.items[1], second.items[1])
    }

    func testRejectsNonVaultFiles() {
        XCTAssertThrowsError(try UnlockedVault.open(Data(#"{"format":"1melon-account","version":1}"#.utf8), account: testAccount)) {
            guard case .invalidFormat = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try UnlockedVault.open(Data(#"{"format":"1melon-vault","version":7}"#.utf8), account: testAccount)) {
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["vault.1melon"])
    }
}

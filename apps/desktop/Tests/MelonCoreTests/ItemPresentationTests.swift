import Foundation
import XCTest
@testable import MelonCore

final class ItemPresentationTests: XCTestCase {
    func item(_ type: ItemType, _ fields: [(FieldKind, String, Bool)], notes: String = "") -> VaultItem {
        var it = VaultItem(type: type, title: "t", created: 0, modified: 0)
        it.sections = [ItemSection(fields: fields.map { ItemField(label: "l", kind: $0.0, value: $0.1, monospace: $0.2) })]
        it.notes = notes
        return it
    }

    func testSubtitleNeverShowsSecrets() {
        XCTAssertEqual(item(.login, [(.text, "me", false), (.password, "hunter2", false)]).subtitle, "me")
        XCTAssertEqual(item(.login, [(.email, "me@example.com", false), (.password, "hunter2", false)]).subtitle, "me@example.com")
        XCTAssertEqual(item(.card, [(.text, "CHEN", false), (.text, "4111 1111 1111 1234", true), (.secret, "123", false)]).subtitle, "•••• 1234")
        XCTAssertEqual(item(.identity, [(.text, "陈林", false), (.text, "310105 19900521 3217", true)]).subtitle, "31••••217")
        XCTAssertEqual(item(.ssh, [(.text, "vps.example.com:22", true), (.text, "root", false)]).subtitle, "root@vps.example.com")
        XCTAssertEqual(item(.note, [], notes: "\n第一行\n第二行").subtitle, "第一行")
        XCTAssertEqual(item(.card, [(.text, "12", true)]).subtitle, "")
    }

    func testSearchSkipsSecretFields() {
        var it = item(.login, [(.text, "alice", false), (.password, "s3cret-word", false), (.url, "github.com", false)])
        it.title = "GitHub"
        it.tags = ["开发"]
        XCTAssertTrue(it.matches("git"))
        XCTAssertTrue(it.matches("ALICE"))
        XCTAssertTrue(it.matches("开发"))
        XCTAssertTrue(it.matches("  "))
        XCTAssertFalse(it.matches("s3cret"))
    }

    func testPasswordsFromEverySection() {
        var it = item(.login, [(.password, "a", false)])
        it.sections.append(ItemSection(title: "旧密码", fields: [ItemField(label: "密码", kind: .password, value: "b"),
                                                                ItemField(label: "PIN", kind: .secret, value: "c")]))
        XCTAssertEqual(it.passwords, ["a", "b"])
    }

    func testTemplatesAndCleanup() {
        let login = VaultItem.fromTemplate(.login, now: 0)
        XCTAssertEqual(login.sections.map(\.title), ["", "两步验证"])
        XCTAssertEqual(login.sections[0].fields.map(\.kind), [.text, .password, .url])
        XCTAssertEqual(Set(login.allFields.map(\.id)).count, login.allFields.count)
        XCTAssertTrue(VaultItem.fromTemplate(.note, now: 0).sections.isEmpty)
        XCTAssertTrue(VaultItem.fromTemplate(.card, now: 0).allFields.first { $0.label == "卡号" }!.monospace)

        var filled = login
        filled.sections[0].fields[0].value = "alice"
        let cleaned = filled.droppingEmptyFields()
        XCTAssertEqual(cleaned.sections.count, 1) // 「两步验证」块里没填，整块去掉
        XCTAssertEqual(cleaned.allFields.map(\.label), ["用户名"])
        for t in ItemType.allKnown where t != .note { XCTAssertFalse(t.template.isEmpty, t.rawValue) }
    }
}

final class AccountRepositoryTests: XCTestCase {
    func testCreateUnlockMultipleVaultsAndFailures() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("1melon-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = AccountRepository(root: dir)
        XCTAssertFalse(repo.exists)

        let created = try repo.create(password: "pw", now: t0, kdf: testKDF)
        XCTAssertTrue(repo.exists)
        XCTAssertEqual(created.vaults.map(\.meta.name), ["个人"])
        XCTAssertThrowsError(try repo.create(password: "other", now: t0, kdf: testKDF))

        var personal = created.vaults[0]
        personal.save(sampleLogin(t0), now: t0)
        try repo.save(&personal, now: t0)
        _ = try repo.createVault(in: created.account, meta: VaultMeta(name: "工作", icon: "briefcase", color: "green", order: 1, created: t0 + 1), now: t0 + 1)
        // 一个坏掉的保险库文件：不影响其他保险库
        try VaultStore.write(Data("garbage".utf8), to: repo.vaultURL(newID()))

        let loaded = try repo.unlock(password: "pw")
        XCTAssertEqual(loaded.vaults.map(\.meta.name), ["个人", "工作"])
        XCTAssertEqual(loaded.vaults[0].activeItems.count, 1)
        XCTAssertEqual(loaded.failures.count, 1)
        XCTAssertThrowsError(try repo.unlock(password: "nope")) { XCTAssertEqual($0 as? VaultError, .wrongPassword) }
    }

    func testDeleteOnlyEmptyVaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("1melon-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = AccountRepository(root: dir)
        let created = try repo.create(password: "pw", now: t0, kdf: testKDF)
        var work = try repo.createVault(in: created.account, meta: VaultMeta(name: "工作", order: 1, created: t0), now: t0)
        work.save(sampleLogin(t0), now: t0)
        try repo.save(&work, now: t0)
        XCTAssertThrowsError(try repo.deleteVault(work))
        work.delete(id: work.activeItems[0].id, now: t0 + 1)
        try repo.save(&work, now: t0 + 1)
        try repo.deleteVault(work)
        XCTAssertEqual(repo.loadVaults(created.account).vaults.map(\.meta.name), ["个人"])
    }
}

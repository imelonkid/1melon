import Foundation
import XCTest
@testable import MelonCore

final class ItemPresentationTests: XCTestCase {
    func item(_ type: ItemType, _ fields: [(FieldKind, String)], notes: String = "") -> VaultItem {
        var it = UnlockedVault.newItem(type: type, title: "t", now: 0)
        it.fields = fields.enumerated().map { ItemField(id: "f\($0.offset)", label: "l", kind: $0.element.0, value: $0.element.1) }
        it.notes = notes
        return it
    }

    func testSubtitleNeverShowsSecrets() {
        XCTAssertEqual(item(.login, [(.text, "me@example.com"), (.password, "hunter2")]).subtitle, "me@example.com")
        XCTAssertEqual(item(.card, [(.text, "CHEN"), (.mono, "4111 1111 1111 1234"), (.secret, "123")]).subtitle, "•••• 1234")
        XCTAssertEqual(item(.identity, [(.mono, "310105 19900521 3217")]).subtitle, "31••••217")
        XCTAssertEqual(item(.ssh, [(.mono, "vps.example.com:22"), (.text, "root")]).subtitle, "root@vps.example.com")
        XCTAssertEqual(item(.note, [], notes: "\n第一行\n第二行").subtitle, "第一行")
        XCTAssertEqual(item(.card, [(.mono, "12")]).subtitle, "")
    }

    func testSearchSkipsSecretFields() {
        var it = item(.login, [(.text, "alice"), (.password, "s3cret-word"), (.url, "github.com")])
        it.title = "GitHub"
        it.tags = ["开发"]
        XCTAssertTrue(it.matches("git"))
        XCTAssertTrue(it.matches("ALICE"))
        XCTAssertTrue(it.matches("开发"))
        XCTAssertTrue(it.matches("  "))
        XCTAssertFalse(it.matches("s3cret"))
    }

    func testTemplateFillAndEmptyFieldDrop() {
        var it = item(.login, [(.text, "alice")])
        it.fields[0].label = "用户名"
        let filled = it.withTemplateFields()
        XCTAssertEqual(filled.fields.map(\.label), ["用户名", "密码", "网站", "两步验证密钥"])
        XCTAssertEqual(filled.fields[0].value, "alice")
        XCTAssertEqual(Set(filled.fields.map(\.id)).count, 4)
        XCTAssertEqual(filled.droppingEmptyFields().fields.map(\.label), ["用户名"])
        XCTAssertTrue(ItemType.note.templateFields.isEmpty)
    }
}

final class VaultRepositoryTests: XCTestCase {
    func testCreateUnlockSaveAndRefuseOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("1melon-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = VaultRepository(url: dir.appendingPathComponent("1Melon/vault.1melon"))
        XCTAssertFalse(repo.exists)

        var vault = try repo.create(password: "pw", now: t0, kdf: testKDF)
        XCTAssertTrue(repo.exists)
        XCTAssertThrowsError(try repo.create(password: "other", now: t0, kdf: testKDF))

        vault.save(sampleLogin(t0), now: t0)
        try repo.save(&vault, now: t0)
        let reopened = try repo.unlock(password: "pw")
        XCTAssertEqual(reopened.activeItems.count, 1)
        XCTAssertThrowsError(try repo.unlock(password: "nope")) { XCTAssertEqual($0 as? VaultError, .wrongPassword) }
    }
}

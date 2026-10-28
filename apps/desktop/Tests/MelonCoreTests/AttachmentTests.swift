import Foundation
import XCTest
@testable import MelonCore

/// 文件附件：单独的附件文件（spec §3.5）和字段里的引用（§5.4），保险库版本 2
final class AttachmentTests: XCTestCase {
    let demo = Data("1Melon 演示附件：不是真的密钥\n".utf8)

    func tempRepo() throws -> AccountRepository {
        let repo = AccountRepository(root: FileManager.default.temporaryDirectory.appendingPathComponent("1melon-att-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: repo.vaultsDirectory, withIntermediateDirectories: true)
        return repo
    }

    func testSealAndOpenRoundTrip() throws {
        let (ref, file) = try AttachmentFile.seal(demo, accountId: testAccount.accountId)
        XCTAssertEqual(ref.size, demo.count)
        XCTAssertEqual(ref.key.count, 32)
        XCTAssertTrue(isLowercaseUUID(ref.id))
        let top = try jsonObject(file)
        XCTAssertEqual(top["format"], .string("1melon-attachment"))
        XCTAssertEqual(top["attachmentId"], .string(ref.id))
        XCTAssertEqual(try AttachmentFile.open(file, ref: ref, accountId: testAccount.accountId), demo)
        XCTAssertFalse(String(decoding: file, as: UTF8.self).contains("演示附件"), "文件里不能有明文")
    }

    func testRejectsOverFiveMiB() {
        XCTAssertNoThrow(try AttachmentFile.seal(Data(count: AttachmentFile.maxBytes), accountId: testAccount.accountId))
        XCTAssertThrowsError(try AttachmentFile.seal(Data(count: AttachmentFile.maxBytes + 1), accountId: testAccount.accountId)) {
            XCTAssertEqual($0 as? AttachmentFile.AttachmentError, .tooLarge(AttachmentFile.maxBytes + 1))
        }
    }

    func testOpenChecksEverything() throws {
        let aid = testAccount.accountId
        let (ref, file) = try AttachmentFile.seal(demo, accountId: aid)
        func edited(_ f: (inout [String: JSONValue]) throws -> Void) throws -> Data {
            var top = try jsonObject(file)
            try f(&top)
            return try JSONEncoder().encode(top)
        }
        func expect(_ data: Data, ref: AttachmentRef, _ kind: String, _ what: String) {
            XCTAssertThrowsError(try AttachmentFile.open(data, ref: ref, accountId: aid), what) {
                XCTAssertEqual(SpecVectorTests.kind($0), kind, what)
            }
        }
        expect(try edited { $0["version"] = .number(2) }, ref: ref, "unsupportedVersion", "版本更新")
        expect(try edited { $0["format"] = .string("1melon-vault") }, ref: ref, "invalidFormat", "不是附件")
        expect(try edited { $0["accountId"] = .string(newID()) }, ref: ref, "invalidFormat", "别的账户")
        expect(try edited { $0["attachmentId"] = .string(newID()) }, ref: ref, "tampered", "attachmentId 和引用对不上")
        var wrongKey = ref
        wrongKey.key = Data(repeating: 1, count: 32)
        expect(file, ref: wrongKey, "tampered", "密钥不对")
        var wrongSize = ref
        wrongSize.size += 1
        expect(file, ref: wrongSize, "tampered", "大小和引用对不上")
        let (_, otherFile) = try AttachmentFile.seal(Data("另一个".utf8), accountId: aid)
        expect(try edited { $0["content"] = try jsonObject(otherFile)["content"] }, ref: ref, "tampered", "换成别的附件的密文")
    }

    func testFieldStoresOnlyTheReference() throws {
        let (ref, _) = try AttachmentFile.seal(demo, accountId: testAccount.accountId)
        var f = ItemField(label: "密钥文件", kind: .file)
        f.attach(ref, name: "/Users/demo/.ssh/id_demo")
        XCTAssertEqual(f.fileName, "id_demo")
        XCTAssertEqual(f.value, "")

        var vault = try newVault()
        var item = VaultItem.fromTemplate(.ssh, title: "服务器", now: t0)
        item.sections[0].fields.append(f)
        vault.save(item.droppingEmptyFields(), now: t0)
        let data = try vault.serialized(now: t0)
        XCTAssertEqual(try jsonObject(data)["version"], .number(2))
        var reopened = try UnlockedVault.open(data, account: testAccount)
        XCTAssertEqual(reopened.items[0].allFields.first { $0.kind == .file }?.attachment, ref, "空 value 的附件字段不能被当成空字段丢掉")
        XCTAssertEqual(reopened.attachmentRefs, [ref.id: ref])

        // 删除条目：墓碑没有字段，附件就没人引用了
        reopened.delete(id: item.id, now: t0 + 1)
        XCTAssertTrue(reopened.attachmentRefs.isEmpty)
    }

    func testVersion1VaultStillOpensAndIsWrittenBackAsVersion2() throws {
        var vault = try newVault()
        vault.save(sampleLogin(t0), now: t0)
        var top = try jsonObject(try vault.serialized(now: t0))
        top["version"] = .number(1)
        var reopened = try UnlockedVault.open(try JSONEncoder().encode(top), account: testAccount)
        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertEqual(try jsonObject(try reopened.serialized(now: t0 + 1))["version"], .number(2))
    }

    func testCSVExportSkipsAttachmentContent() throws {
        let (ref, _) = try AttachmentFile.seal(demo, accountId: testAccount.accountId)
        var item = VaultItem.fromTemplate(.ssh, title: "服务器", now: t0)
        var f = ItemField(label: "密钥文件", kind: .file)
        f.attach(ref, name: "demo.txt")
        item.sections[0].fields.append(f)
        let csv = Exporter.csv([.init(vault: "个人", item: item)])
        XCTAssertFalse(csv.contains(ref.key.base64EncodedString()), "密钥不能导出")
        XCTAssertTrue(csv.contains("demo.txt（文件附件，未导出）"))
    }

    func testRepositoryReadsAndSweepsOrphans() throws {
        let repo = try tempRepo()
        let aid = testAccount.accountId
        let (kept, keptFile) = try AttachmentFile.seal(demo, accountId: aid)
        let (orphan, orphanFile) = try AttachmentFile.seal(Data("孤儿".utf8), accountId: aid)
        try VaultStore.write(keptFile, to: repo.attachmentURL(kept.id))
        try VaultStore.write(orphanFile, to: repo.attachmentURL(orphan.id))
        XCTAssertEqual(try repo.readAttachment(kept, accountId: aid), demo)
        let (missing, _) = try AttachmentFile.seal(demo, accountId: aid)
        XCTAssertNil(try repo.readAttachment(missing, accountId: aid), "本机没有的附件返回 nil")
        XCTAssertEqual(Set(repo.localAttachmentIds()), [kept.id, orphan.id])

        // 刚写的孤儿留一小时
        XCTAssertEqual(repo.sweepOrphanAttachments(referenced: [kept.id], now: Date()), [])
        XCTAssertEqual(repo.sweepOrphanAttachments(referenced: [kept.id], now: Date().addingTimeInterval(7200)), [orphan.id])
        XCTAssertEqual(repo.localAttachmentIds(), [kept.id])
    }

    func testBackupIncludesAttachments() throws {
        let repo = try tempRepo()
        try VaultStore.write(Data("account".utf8), to: repo.accountURL)
        let (ref, file) = try AttachmentFile.seal(demo, accountId: testAccount.accountId)
        try VaultStore.write(file, to: repo.attachmentURL(ref.id))
        XCTAssertEqual(try BackupStore.files(in: repo.root).keys.sorted(), ["account.1melon", "attachments/\(ref.id).1melon"])
    }
}

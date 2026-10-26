import Foundation
import XCTest
@testable import MelonCore

/// 导出 CSV 和本地备份：数据全部虚构。
final class ExportBackupTests: XCTestCase {
    private func sampleLogin() -> VaultItem {
        var item = VaultItem.fromTemplate(.login, title: "示例, 网站", now: 1_000)
        item.sections[0].fields[0].value = "demo"
        item.sections[0].fields[1].value = #"p"a,ss"#
        item.sections[0].fields[2].value = "https://example.com"
        item.sections[1].fields[0].value = "otpauth://totp/x?secret=GEZDGNBV"
        item.sections.append(ItemSection(title: "安全问题", fields: [ItemField(label: "小学", kind: .secret, value: "示例小学")]))
        item.notes = "第一行\n第二行"
        item.tags = ["开发", "工作"]
        item.favorite = true
        return item
    }

    func testCSVRoundTripThroughImporter() throws {
        var card = VaultItem.fromTemplate(.card, title: "示例卡", now: 1_000)
        card.sections[0].fields[0].value = "4111111111111111"
        var gone = VaultItem.fromTemplate(.note, title: "已删除", now: 1_000)
        gone.deleted = true
        let csv = Exporter.csv([.init(vault: "个人", item: sampleLogin()), .init(vault: "工作", item: card), .init(vault: "个人", item: gone)])
        XCTAssertTrue(csv.hasPrefix("title,url,username,password,otpauth,notes,vault,type,tags,favorite\r\n"))
        XCTAssertFalse(csv.contains("已删除"), "墓碑不导出")

        let r = try Importer.parse(fileName: "export.csv", data: Data(csv.utf8), now: 0)
        XCTAssertEqual(r.source, "1Melon CSV")
        XCTAssertEqual(r.vaults.map(\.name), ["个人", "工作"])
        let login = r.vaults[0].items[0]
        XCTAssertEqual(login.title, "示例, 网站")
        XCTAssertEqual(login.passwords, [#"p"a,ss"#])
        XCTAssertEqual(login.primaryURL, "https://example.com")
        XCTAssertEqual(login.allFields.first { $0.kind == .totp }?.value, "otpauth://totp/x?secret=GEZDGNBV")
        XCTAssertEqual(login.notes, "第一行\n第二行\n安全问题 · 小学：示例小学", "没有专门列的字段追加到备注")
        XCTAssertEqual(login.tags, ["开发", "工作"])
        XCTAssertTrue(login.favorite)

        let back = r.vaults[1].items[0]
        XCTAssertEqual(back.type, .card)
        XCTAssertTrue(back.notes.contains("4111111111111111"))
    }

    private func makeRepo() throws -> (AccountRepository, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        let repo = AccountRepository(root: dir)
        try VaultStore.write(Data("account".utf8), to: repo.accountURL)
        try VaultStore.write(Data("v1".utf8), to: repo.vaultURL("aaa"))
        try VaultStore.write(Data("device".utf8), to: dir.appendingPathComponent("device/local-unlock.json"))
        try VaultStore.write(Data("tmp".utf8), to: repo.vaultsDirectory.appendingPathComponent(".aaa.1melon.x.tmp"))
        return (repo, dir)
    }

    func testBackupCopiesEncryptedFilesAndSkipsUnchanged() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackupStore(destination: BackupStore.defaultDestination(for: repo))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try XCTUnwrap(store.backUp(repo, now: t0))
        XCTAssertEqual(try BackupStore.files(in: first.url).keys.sorted(), ["account.1melon", "vaults/aaa.1melon"], "不备份 device/ 和临时文件")
        XCTAssertNil(try store.backUp(repo, now: t0.addingTimeInterval(60)), "没变化不重复备份")

        try VaultStore.write(Data("v1-changed".utf8), to: repo.vaultURL("aaa"))
        let second = try XCTUnwrap(store.backUp(repo, now: t0.addingTimeInterval(120)))
        XCTAssertEqual(store.list().map(\.url.lastPathComponent), [second.url.lastPathComponent, first.url.lastPathComponent], "新的在前")
        XCTAssertEqual(try Data(contentsOf: second.url.appendingPathComponent("vaults/aaa.1melon")), Data("v1-changed".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.destination.path).contains { $0.hasSuffix(".tmp") })

        // 只留最新一份；目录里别的东西不动
        try Data().write(to: store.destination.appendingPathComponent("别的文件.txt"))
        XCTAssertEqual(store.prune(keep: 1).map(\.url.lastPathComponent), [first.url.lastPathComponent])
        XCTAssertEqual(store.list().map(\.url.lastPathComponent), [second.url.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.destination.appendingPathComponent("别的文件.txt").path))
    }

    func testBackupWithoutAccountFails() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        let store = BackupStore(destination: dir.appendingPathComponent("b"))
        XCTAssertThrowsError(try store.backUp(AccountRepository(root: dir))) { XCTAssertEqual($0 as? BackupStore.Failure, .noAccount) }
    }
}

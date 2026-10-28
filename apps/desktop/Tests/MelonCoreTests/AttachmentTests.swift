import Foundation
import XCTest
@testable import MelonCore

/// 文件附件和保险库版本 2（spec §3.2、§5.4）
final class AttachmentTests: XCTestCase {
    func testAttachKeepsBytesAndOnlyFileName() throws {
        var f = ItemField(label: "密钥文件", kind: .file)
        let data = Data((0..<300).map { UInt8($0 % 256) })
        try f.attach(data, name: "/Users/demo/.ssh/id_demo")
        XCTAssertEqual(f.attachmentData, data)
        XCTAssertEqual(f.attachmentSize, 300)
        XCTAssertEqual(f.fileName, "id_demo")
    }

    func testAttachmentSizeMatchesBase64Padding() throws {
        for n in [0, 1, 2, 3, 4, 5] where n > 0 {
            var f = ItemField(label: "f", kind: .file)
            try f.attach(Data(repeating: 7, count: n), name: "a")
            XCTAssertEqual(f.attachmentSize, n)
        }
    }

    func testRejectsOverOneMiB() throws {
        var f = ItemField(label: "f", kind: .file)
        XCTAssertNoThrow(try f.attach(Data(count: ItemField.maxAttachmentBytes), name: "ok"))
        XCTAssertThrowsError(try f.attach(Data(count: ItemField.maxAttachmentBytes + 1), name: "big")) {
            XCTAssertEqual($0 as? ItemField.AttachmentError, .tooLarge(ItemField.maxAttachmentBytes + 1))
        }
    }

    func testFileFieldRoundTripsThroughVault() throws {
        var vault = try newVault()
        var item = VaultItem.fromTemplate(.ssh, title: "服务器", now: t0)
        var f = ItemField(label: "密钥文件", kind: .file)
        try f.attach(Data("演示附件".utf8), name: "demo.txt")
        item.sections[0].fields.append(f)
        vault.save(item, now: t0)
        let data = try vault.serialized(now: t0)
        XCTAssertEqual(try jsonObject(data)["version"], .number(2))
        let reopened = try UnlockedVault.open(data, account: testAccount)
        let back = reopened.items[0].allFields.first { $0.kind == .file }
        XCTAssertEqual(back?.fileName, "demo.txt")
        XCTAssertEqual(back?.attachmentData, Data("演示附件".utf8))
    }

    func testVersion1VaultStillOpensAndIsWrittenBackAsVersion2() throws {
        var vault = try newVault()
        vault.save(sampleLogin(t0), now: t0)
        var top = try jsonObject(try vault.serialized(now: t0))
        top["version"] = .number(1)
        let v1 = try JSONEncoder().encode(top)
        var reopened = try UnlockedVault.open(v1, account: testAccount)
        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertEqual(try jsonObject(try reopened.serialized(now: t0 + 1))["version"], .number(2))
    }

    func testCSVExportSkipsAttachmentContent() throws {
        var item = VaultItem.fromTemplate(.ssh, title: "服务器", now: t0)
        var f = ItemField(label: "密钥文件", kind: .file)
        try f.attach(Data("不该出现在 CSV 里".utf8), name: "demo.txt")
        item.sections[0].fields.append(f)
        let csv = Exporter.csv([.init(vault: "个人", item: item)])
        XCTAssertFalse(csv.contains(f.value))
        XCTAssertTrue(csv.contains("demo.txt（文件附件，未导出）"))
    }
}

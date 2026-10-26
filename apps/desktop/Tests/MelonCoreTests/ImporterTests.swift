import Foundation
import XCTest
@testable import MelonCore

/// 导入：样例数据全部虚构，结构照各家真实导出格式写。
final class ImporterTests: XCTestCase {
    static let onePasswordExport = #"""
    {"accounts":[{"attrs":{"name":"示例账户"},"vaults":[
      {"attrs":{"name":"Personal"},"items":[
        {"uuid":"a1","favIndex":1,"createdAt":1600000000,"updatedAt":1700000000,"state":"active","categoryUuid":"001",
         "overview":{"title":"示例网站","url":"https://example.com","urls":[{"label":"","url":"https://example.com"},{"label":"","url":"https://m.example.com"}],"tags":["开发"]},
         "details":{"loginFields":[{"value":"demo","name":"username","fieldType":"T","designation":"username"},
                                   {"value":"v7#Qm2!xLp9@Tz4K","name":"password","fieldType":"P","designation":"password"}],
                    "notesPlain":"备注一行",
                    "sections":[{"title":"","fields":[{"title":"one-time password","value":{"totp":"otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"}}]},
                                {"title":"安全问题","fields":[{"title":"小学校名","value":{"concealed":"示例小学"}},
                                                          {"title":"附件","value":{"file":{"fileName":"a.pdf"}}}]}]}},
        {"uuid":"a2","categoryUuid":"002","state":"archived","createdAt":1600000000,"updatedAt":1600000000,
         "overview":{"title":"示例信用卡"},
         "details":{"sections":[{"title":"","fields":[{"title":"卡号","value":{"creditCardNumber":"4111111111111111"}},
                                                      {"title":"有效期","value":{"monthYear":202908}},
                                                      {"title":"CVV","value":{"concealed":"123"}}]}]}}
      ]},
      {"attrs":{"name":"Ops"},"items":[
        {"uuid":"b1","categoryUuid":"114","overview":{"title":"示例服务器密钥"},
         "details":{"sections":[{"title":"","fields":[{"title":"private key","value":{"sshKey":{"privateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----","metadata":{}}}},
                                                      {"title":"生日","value":{"date":631152000}},
                                                      {"title":"邮箱","value":{"email":{"email_address":"ops@example.com"}}}]}]}},
        {"uuid":"b2","categoryUuid":"115","overview":{"title":"未知类别"},"details":{"sections":[{"title":"","fields":[{"title":"地址","value":{"string":"0xabc"}}]}]}}
      ]}
    ]}]}
    """#

    func testOnePasswordExportData() throws {
        let r = try Importer.onePassword(exportData: Data(Self.onePasswordExport.utf8), now: 0)
        XCTAssertEqual(r.vaults.map(\.name), ["Personal", "Ops"])
        XCTAssertEqual(r.itemCount, 4)

        let login = r.vaults[0].items[0]
        XCTAssertEqual(login.type, .login)
        XCTAssertTrue(login.favorite)
        XCTAssertEqual(login.tags, ["开发"])
        XCTAssertEqual(login.notes, "备注一行")
        XCTAssertEqual(login.created, 1_600_000_000_000)
        XCTAssertEqual(login.sections.count, 2) // 无标题分组并进主分组；「安全问题」单独一组
        XCTAssertEqual(login.sections[0].fields.map(\.kind), [.text, .password, .url, .url, .totp])
        XCTAssertEqual(login.sections[1].title, "安全问题")
        XCTAssertEqual(login.sections[1].fields.map(\.kind), [.secret])
        XCTAssertTrue(r.skipped.contains { $0.contains("附件") })

        let card = r.vaults[0].items[1]
        XCTAssertEqual(card.type, .card)
        XCTAssertTrue(card.tags.contains("1Password 已归档"))
        XCTAssertEqual(card.allFields.first { $0.kind == .monthYear }?.value, "2029-08")
        XCTAssertTrue(card.allFields.first { $0.label == "卡号" }!.monospace)

        let ssh = r.vaults[1].items[0]
        XCTAssertEqual(ssh.type, .ssh)
        XCTAssertEqual(ssh.allFields.map(\.kind), [.multiline, .date, .email])
        XCTAssertEqual(ssh.allFields[1].value, "1990-01-01")
        XCTAssertEqual(r.vaults[1].items[1].type, .note, "不认识的类别按安全笔记，字段保留")
        XCTAssertEqual(r.vaults[1].items[1].allFields.first?.value, "0xabc")
    }

    #if canImport(Compression)
    /// 打成真正的 .1pux（ZIP）再读：DEFLATE 和不压缩两种都测
    func testOnePuxZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("1pux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.onePasswordExport.utf8).write(to: dir.appendingPathComponent("export.data"))
        try Data(#"{"version":3}"#.utf8).write(to: dir.appendingPathComponent("export.attributes"))
        for (name, level) in [("deflate.1pux", "-6"), ("stored.1pux", "-0")] {
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = dir
            zip.arguments = ["-q", level, name, "export.attributes", "export.data"]
            try zip.run(); zip.waitUntilExit()
            XCTAssertEqual(zip.terminationStatus, 0)
            let r = try Importer.parse(fileName: name, data: Data(contentsOf: dir.appendingPathComponent(name)), now: 0)
            XCTAssertEqual(r.itemCount, 4, name)
        }
        XCTAssertNil(try ZipReader.entry(named: "missing", in: Data(contentsOf: dir.appendingPathComponent("stored.1pux"))))
        XCTAssertThrowsError(try ZipReader.entry(named: "export.data", in: Data("not a zip at all, definitely not".utf8)))
    }
    #endif

    func testBitwardenJSON() throws {
        let json = #"""
        {"encrypted":false,"folders":[{"id":"f1","name":"工作"}],"items":[
          {"type":1,"name":"示例网站","favorite":true,"folderId":"f1","notes":"n",
           "login":{"username":"demo","password":"p@ss","totp":"GEZDGNBVGY3TQOJQ","uris":[{"uri":"https://example.com"}]},
           "fields":[{"name":"PIN","value":"1234","type":1}]},
          {"type":3,"name":"示例卡","card":{"cardholderName":"ZHANG","number":"4111111111111111","expMonth":"8","expYear":"2029","code":"123","brand":"Visa"}},
          {"type":2,"name":"笔记","notes":"内容","attachments":[{"fileName":"a.txt"}]}
        ]}
        """#
        let r = try Importer.bitwarden(json: Data(json.utf8), now: 0)
        XCTAssertEqual(r.itemCount, 3)
        let login = r.vaults[0].items[0]
        XCTAssertEqual(login.tags, ["工作"])
        XCTAssertTrue(login.favorite)
        XCTAssertEqual(login.sections[0].fields.map(\.kind), [.text, .password, .url, .totp])
        XCTAssertEqual(login.sections[1].fields.first?.kind, .secret)
        XCTAssertEqual(r.vaults[0].items[1].allFields.first { $0.kind == .monthYear }?.value, "2029-08")
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertThrowsError(try Importer.bitwarden(json: Data(#"{"encrypted":true,"data":"x"}"#.utf8)))
    }

    func testBrowserCSV() throws {
        let chrome = "name,url,username,password,note\n示例,https://example.com/login,demo,\"pa,ss\"\"word\",\"多行\n备注\"\n,https://no-name.example.org,u,p,\n"
        let r = try Importer.browserCSV(chrome, now: 0)
        XCTAssertEqual(r.itemCount, 2)
        let first = r.vaults[0].items[0]
        XCTAssertEqual(first.title, "示例")
        XCTAssertEqual(first.passwords, [#"pa,ss"word"#])
        XCTAssertEqual(first.notes, "多行\n备注")
        XCTAssertEqual(first.sections.count, 1, "空的两步验证分组被去掉")
        XCTAssertEqual(r.vaults[0].items[1].title, "no-name.example.org", "没有名称时用主机名")

        let safari = "Title,URL,Username,Password,Notes,OTPAuth\r\nA,https://a.example.com,u,p,,otpauth://totp/a?secret=GEZDGNBV\r\n"
        let s = try Importer.browserCSV(safari, now: 0)
        XCTAssertEqual(s.vaults[0].items[0].allFields.map(\.kind), [.text, .password, .url, .totp])
        XCTAssertThrowsError(try Importer.browserCSV("a,b\n1,2\n"))
    }
}

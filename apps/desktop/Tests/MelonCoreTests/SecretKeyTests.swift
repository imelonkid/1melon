import Crypto
import Foundation
import XCTest
@testable import MelonCore

/// Secret Key（spec §3.4）和带 Secret Key 的账户文件 v2（spec §3.1）。
final class SecretKeyTests: XCTestCase {
    func testTextRoundTripAndLenientParsing() throws {
        for _ in 0..<200 {
            let sk = SecretKey.generate()
            let text = sk.text
            XCTAssertTrue(text.hasPrefix("M1-"))
            XCTAssertEqual(text.count, 3 + 28 + 3)
            XCTAssertTrue("01234567".contains(text[text.index(text.startIndex, offsetBy: 3)]), "第一个数据字符只可能是 0–7")
            XCTAssertEqual(try SecretKey(text: text), sk)
            XCTAssertEqual(try SecretKey(text: text.lowercased()), sk, "不分大小写")
            XCTAssertEqual(try SecretKey(text: String(text.dropFirst(3)).replacingOccurrences(of: "-", with: " ")), sk, "可以省略前缀、用空格分组")
            let confusable = text.dropFirst(3).replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l")
            XCTAssertEqual(try SecretKey(text: confusable), sk, "O 当 0、l 当 1")
        }
    }

    func testInvalidTextIsRejected() throws {
        let text = try SecretKey(bytes: Data(repeating: 0xAB, count: 16)).text
        var chars = Array(text)
        let last = chars.count - 1
        chars[last] = chars[last] == "0" ? "2" : "0" // 改校验位
        for bad in ["", "M1-", String(text.dropLast()), text + "0", String(chars), text.replacingOccurrences(of: "-", with: "U"),
                    "M1-8" + String(text.dropFirst(4))] {
            XCTAssertThrowsError(try SecretKey(text: bad), bad)
        }
        XCTAssertThrowsError(try SecretKey(bytes: Data(count: 15)))
    }

    func testAccountV2RequiresSecretKey() throws {
        let sk = SecretKey.generate()
        let account = try UnlockedAccount.create(password: "pw", kdf: testKDF, secretKey: sk)
        let data = try account.serialized()
        let top = try jsonObject(data)
        XCTAssertEqual(top["version"], .number(2))
        XCTAssertEqual(top["secretKey"], .string("required"))
        XCTAssertEqual(top["secretKeyId"], .string(sk.id(accountId: account.accountId).base64EncodedString()))

        let opened = try UnlockedAccount.open(data, password: "pw", secretKey: sk)
        XCTAssertEqual(opened.accountKey, account.accountKey)
        XCTAssertEqual(opened.secretKey, sk)
        XCTAssertThrowsError(try UnlockedAccount.open(data, password: "pw")) { XCTAssertEqual($0 as? VaultError, .secretKeyRequired) }
        XCTAssertThrowsError(try UnlockedAccount.open(data, password: "pw", secretKey: .generate())) {
            XCTAssertEqual($0 as? VaultError, .wrongSecretKey)
        }
        XCTAssertThrowsError(try UnlockedAccount.open(data, password: "wrong", secretKey: sk)) { XCTAssertEqual($0 as? VaultError, .wrongPassword) }

        // KEK 真的用到了 Secret Key：只用 Argon2id 输出解不开
        let argon = try UnlockedAccount.deriveKEK(password: "pw", kdf: testKDF)
        XCTAssertThrowsError(try UnlockedAccount.open(data, kek: argon, secretKey: sk)) { XCTAssertEqual($0 as? VaultError, .wrongPassword) }
    }

    func testEnableChangePasswordAndDisable() throws {
        var account = try UnlockedAccount.create(password: "pw", kdf: testKDF)
        let ak = account.accountKey
        var v = try newVault(account: account)
        let vault = try v.serialized(now: t0)

        let sk = SecretKey.generate()
        try account.setSecretKey(sk, password: "pw")
        var data = try account.serialized()
        XCTAssertEqual(try jsonObject(data)["version"], .number(2))
        var opened = try UnlockedAccount.open(data, password: "pw", secretKey: sk)
        XCTAssertEqual(opened.accountKey, ak, "AK 不变，保险库不用重新加密")
        XCTAssertNoThrow(try UnlockedVault.open(vault, account: opened))

        try opened.changePassword(to: "pw2", kdf: testKDF)
        data = try opened.serialized()
        XCTAssertEqual(try UnlockedAccount.open(data, password: "pw2", secretKey: sk).accountKey, ak, "改主密码保留 Secret Key")

        try opened.setSecretKey(nil, password: "pw2")
        data = try opened.serialized()
        let top = try jsonObject(data)
        XCTAssertEqual(top["version"], .number(1))
        XCTAssertEqual(top["secretKey"], .string("none"))
        XCTAssertNil(top["secretKeyId"])
        XCTAssertEqual(try UnlockedAccount.open(data, password: "pw2").accountKey, ak)
    }

    func testAccountKeyUnlockKeepsDeviceSecretKey() throws {
        let sk = SecretKey.generate()
        let account = try UnlockedAccount.create(password: "pw", kdf: testKDF, secretKey: sk)
        let data = try account.serialized()
        XCTAssertEqual(try UnlockedAccount.open(data, accountKey: account.accountKey, secretKey: sk).secretKey, sk)
        XCTAssertNil(try UnlockedAccount.open(data, accountKey: account.accountKey, secretKey: .generate()).secretKey, "对不上的不带")
    }

    func testRepositoryStoresSecretKeyOnDevice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("1melon-sk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = AccountRepository(root: dir)
        var account = try repo.create(password: "pw", now: t0, kdf: testKDF).account
        XCTAssertFalse(repo.accountRequiresSecretKey)

        let sk = SecretKey.generate()
        try account.setSecretKey(sk, password: "pw")
        try repo.saveAccount(account)
        XCTAssertTrue(repo.accountRequiresSecretKey)
        XCTAssertThrowsError(try repo.unlock(password: "pw")) { XCTAssertEqual($0 as? VaultError, .secretKeyRequired) }

        // 手输一次 Secret Key 解锁成功后，存进设备目录（0600），之后不用再输
        XCTAssertEqual(try repo.unlock(password: "pw", secretKey: sk).vaults.count, 1)
        XCTAssertEqual(repo.readSecretKey(accountId: account.accountId), sk)
        XCTAssertNil(repo.readSecretKey(accountId: newID()), "别的账户的不算")
        let perms = try FileManager.default.attributesOfItem(atPath: repo.secretKeyURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(try repo.unlock(password: "pw").vaults.count, 1)

        // 备份不带 Secret Key
        let backup = try XCTUnwrap(BackupStore(destination: dir.appendingPathComponent("backups")).backUp(repo))
        XCTAssertFalse(try BackupStore.files(in: backup.url).keys.contains { $0.contains("secret") })

        repo.removeSecretKey()
        XCTAssertNil(repo.readSecretKey())
    }
}

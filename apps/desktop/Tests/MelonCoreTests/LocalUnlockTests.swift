import Crypto
import Foundation
import XCTest
@testable import MelonCore

/// 本机快速解锁：交给钥匙串的字节（钥匙串本身只在 macOS 上、要正式签名，这里只测编解码和账户密钥解锁）
final class LocalUnlockTests: XCTestCase {
    func testSecretRoundTrip() throws {
        let plain = LocalUnlockSecret(account: testAccount, loginKey: nil)
        XCTAssertEqual(plain.bytes.count, 32)
        let back = try LocalUnlockSecret(bytes: plain.bytes)
        XCTAssertEqual(back.accountKey.withUnsafeBytes { Data($0) }, testAccount.accountKey.withUnsafeBytes { Data($0) })
        XCTAssertNil(back.loginKey)

        let key = LoginKey.derive(argon2Output: SymmetricKey(size: .bits256), secretKey: .generate(), accountId: testAccount.accountId)
        let withKey = LocalUnlockSecret(account: testAccount, loginKey: key)
        XCTAssertEqual(withKey.bytes.count, 64)
        XCTAssertEqual(try LocalUnlockSecret(bytes: withKey.bytes).loginKey?.publicKey, key.publicKey)

        for n in [0, 31, 33, 63, 65] {
            XCTAssertThrowsError(try LocalUnlockSecret(bytes: Data(count: n)), "\(n) 字节")
        }
    }

    func testRepositoryUnlockWithAccountKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("1melon-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = AccountRepository(root: dir)
        let created = try repo.create(password: "pw", now: t0, kdf: testKDF)
        let ak = created.account.accountKeyForLocalUnlock

        let loaded = try repo.unlock(accountKey: ak)
        XCTAssertEqual(loaded.vaults.map(\.meta.name), ["个人"])
        // 账户密钥不对：保险库全部打不开 → 按主密码错误处理
        XCTAssertThrowsError(try repo.unlock(accountKey: SymmetricKey(size: .bits256))) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }

        // 旧版本的 Touch ID 文件：删掉就行
        try FileManager.default.createDirectory(at: repo.deviceDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: repo.legacyLocalUnlockURL)
        repo.removeLegacyLocalUnlock()
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.legacyLocalUnlockURL.path))
    }
}

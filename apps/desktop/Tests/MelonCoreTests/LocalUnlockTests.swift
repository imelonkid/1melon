import Crypto
import Foundation
import XCTest
@testable import MelonCore

/// 本机解锁信封：用软件 P-256 密钥代替安全隔区测（桌面端真正用的是安全隔区密钥，接口相同）。
final class LocalUnlockTests: XCTestCase {
    func testSealAndOpenRoundTrip() throws {
        let device = P256.KeyAgreement.PrivateKey()
        let file = try LocalUnlockFile.seal(account: testAccount, to: device.publicKey, deviceKey: Data("handle".utf8))
        let ak = try file.open { try device.sharedSecretFromKeyAgreement(with: $0) }
        XCTAssertEqual(ak.withUnsafeBytes { Data($0) }, testAccount.accountKey.withUnsafeBytes { Data($0) })
    }

    func testWrongDeviceKeyFails() throws {
        let file = try LocalUnlockFile.seal(account: testAccount, to: P256.KeyAgreement.PrivateKey().publicKey, deviceKey: Data())
        let other = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try file.open { try other.sharedSecretFromKeyAgreement(with: $0) }) {
            guard case .tampered = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    func testBoundToAccountId() throws {
        let device = P256.KeyAgreement.PrivateKey()
        var file = try LocalUnlockFile.seal(account: testAccount, to: device.publicKey, deviceKey: Data())
        file.accountId = newID()
        XCTAssertThrowsError(try file.open { try device.sharedSecretFromKeyAgreement(with: $0) })
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

        let device = P256.KeyAgreement.PrivateKey()
        try repo.writeLocalUnlock(try LocalUnlockFile.seal(account: created.account, to: device.publicKey, deviceKey: Data("h".utf8)))
        let perms = try FileManager.default.attributesOfItem(atPath: repo.localUnlockURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(repo.readLocalUnlock()?.accountId, created.account.accountId)
        repo.removeLocalUnlock()
        XCTAssertNil(repo.readLocalUnlock())
    }
}

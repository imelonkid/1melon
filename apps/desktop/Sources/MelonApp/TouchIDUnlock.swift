import CryptoKit
import Foundation
import LocalAuthentication
import MelonCore

/// Touch ID 解锁：账户密钥用安全隔区里的一把 P-256 密钥封起来，存在本机 `device/local-unlock.json`。
/// - 那把私钥只能在这台 Mac 的安全隔区里用，每次用都要过 Touch ID（`biometryCurrentSet`）；文件拷到别处没有用
/// - 指纹有增删时这把密钥自动作废：解不开就删掉本机文件，下次输主密码后重新登记
/// - 不需要钥匙串和 Apple 开发者证书（ad-hoc 签名也能用）
enum TouchIDUnlock {
    enum Failure: Error {
        /// 用户取消了 Touch ID，或者选了输密码
        case cancelled
        /// 指纹变了或文件坏了：本机文件已删除，要用主密码解锁
        case invalidated
        case unavailable
    }

    static let settingKey = Preferences.Key.touchID
    /// 「每次启动后」模式下，这次启动以来是否输过主密码
    @MainActor static var passwordEnteredThisLaunch = false

    /// 设置里的「使用 Touch ID 解锁」，默认开启
    static var enabledInSettings: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// 这台 Mac 能不能用 Touch ID（有安全隔区、登记过指纹）
    static var isAvailable: Bool {
        var error: NSError?
        return SecureEnclave.isAvailable && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// 本机已经登记好、可以用 Touch ID 解锁（还要主密码没「过期」，见 `passwordIsFresh`）
    @MainActor static func isReady(_ repo: AccountRepository) -> Bool {
        enabledInSettings && isAvailable && repo.readLocalUnlock() != nil && passwordIsFresh
    }

    /// 本机登记过 Touch ID，但距离上次输主密码太久，这次必须输主密码
    @MainActor static func needsPassword(_ repo: AccountRepository) -> Bool {
        enabledInSettings && isAvailable && repo.readLocalUnlock() != nil && !passwordIsFresh
    }

    /// 设置里「要求输入主密码」的周期之内输过主密码，才允许用 Touch ID
    @MainActor static var passwordIsFresh: Bool {
        let days = Preferences.requirePasswordDays
        if days == 0 { return passwordEnteredThisLaunch }
        guard let last = Preferences.lastPasswordUnlock else { return false }
        return Date().timeIntervalSince(last) < Double(days) * 86_400
    }

    /// 用主密码解锁或新建账户后调用：记下时间，重新开始计算周期
    @MainActor static func notePasswordEntered() {
        passwordEnteredThisLaunch = true
        Preferences.lastPasswordUnlock = Date()
    }

    /// 登记：新建一把安全隔区密钥，把账户密钥封给它（主密码解锁成功后调用，不弹 Touch ID）
    static func enroll(_ account: UnlockedAccount, repo: AccountRepository) throws {
        guard isAvailable else { throw Failure.unavailable }
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &cfError
        ) else { throw Failure.unavailable }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        try repo.writeLocalUnlock(try LocalUnlockFile.seal(account: account, to: key.publicKey, deviceKey: key.dataRepresentation))
    }

    /// 弹 Touch ID，成功后取出账户密钥。失败时区分「取消」和「已作废」
    static func accountKey(repo: AccountRepository) async throws -> SymmetricKey {
        guard let file = repo.readLocalUnlock() else { throw Failure.invalidated }
        let context = LAContext()
        context.localizedCancelTitle = "输入主密码"
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "解锁 1Melon")
        } catch let e as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(e.code) {
            throw Failure.cancelled
        } catch {
            throw Failure.cancelled
        }
        do {
            // 用刚才验证过的 context，不会再弹第二次
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: file.deviceKey, authenticationContext: context)
            return try file.open { try key.sharedSecretFromKeyAgreement(with: $0) }
        } catch {
            repo.removeLocalUnlock()
            throw Failure.invalidated
        }
    }

    static func disable(repo: AccountRepository) {
        repo.removeLocalUnlock()
    }
}

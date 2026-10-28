import CryptoKit
import Foundation
import LocalAuthentication
import MelonCore
import Security

/// Touch ID 解锁：账户密钥（开着同步时还有同步登录密钥的种子，`LocalUnlockSecret`）存在钥匙串里。
/// - 数据保护钥匙串，访问组是 `<TeamID>.cn.melonkid.1melon`：只有用我们的证书签名、带描述文件的 1Melon 能读，
///   别的程序既读不到，也没法借它弹 Touch ID
/// - 每次读都要过 Touch ID（`biometryCurrentSet`），只在这台设备上（`ThisDeviceOnly`，不进 iCloud 钥匙串、不进备份），
///   要设了登录密码（`WhenPasscodeSet`）；指纹有增删时条目自动作废：读不出来就删掉，下次输主密码后重新登记
/// - 带指纹保护的条目连属性也要过 Touch ID 才能读，所以另存一条不带保护的「说明」：登记的是哪个账户、有没有登录密钥
///   （都不是机密），解锁页据此决定显不显示 Touch ID 按钮。两条一起写、一起删
/// - 没有正式签名的包（ad-hoc、`swift run`）没有钥匙串权限：不提供 Touch ID，只能输主密码
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

    /// 这个包有钥匙串权限（正式签名、带描述文件）。ad-hoc 签名和 `swift run` 的没有
    static let isSigned: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String]
        else { return false }
        return !groups.isEmpty
    }()

    /// 这台 Mac 能不能用 Touch ID：包有钥匙串权限，Mac 登记过指纹
    static var isAvailable: Bool {
        var error: NSError?
        return isSigned && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// 解锁页上 Touch ID 按钮变灰时，下面那行说明
    @MainActor static var unavailableReason: String {
        if !isSigned { return "这个版本没有正式签名，不能用 Touch ID，请输入主密码" }
        var error: NSError?
        if !LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return "这台 Mac 没有可用的 Touch ID（没有指纹识别，或还没在系统设置里录指纹）"
        }
        if enrolled() == nil { return "用主密码解锁一次后，下次就能用 Touch ID" }
        return Preferences.requirePasswordDays == 0
            ? "启动后第一次解锁需要输入主密码，之后可以用 Touch ID"
            : "已经有一段时间没有输入主密码了，这次请输入主密码，之后可以继续用 Touch ID"
    }

    /// 本机已经登记好、可以用 Touch ID 解锁（还要主密码没「过期」，见 `passwordIsFresh`）
    @MainActor static func isReady(_ repo: AccountRepository) -> Bool {
        enabledInSettings && isAvailable && enrolled() != nil && passwordIsFresh
    }

    /// 本机登记过 Touch ID，但距离上次输主密码太久，这次必须输主密码
    @MainActor static func needsPassword(_ repo: AccountRepository) -> Bool {
        enabledInSettings && isAvailable && enrolled() != nil && !passwordIsFresh
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

    // MARK: 钥匙串

    /// 秘密条目（带指纹保护）
    static let service = "cn.melonkid.1melon.touch-id"
    /// 说明条目（不带保护）：账户 id 和有没有登录密钥
    static let infoService = "cn.melonkid.1melon.touch-id.info"
    private static let withLoginKey = "with-login-key"

    private static func baseQuery(_ service: String = service) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecUseDataProtectionKeychain: true]
    }

    /// 登记了哪个账户、有没有存登录密钥（读说明条目，不弹 Touch ID）
    static func enrolled() -> (accountId: String, hasLoginKey: Bool)? {
        guard isSigned else { return nil }
        var query = baseQuery(infoService)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [CFString: Any], let accountId = attrs[kSecAttrAccount] as? String else { return nil }
        return (accountId, attrs[kSecAttrDescription] as? String == withLoginKey)
    }

    /// 登记：账户密钥（和同步登录密钥）存进钥匙串（主密码解锁成功后调用，不弹 Touch ID）。只留一份，旧的先删
    static func enroll(_ account: UnlockedAccount, loginKey: LoginKey?, repo: AccountRepository) throws {
        guard isAvailable else { throw Failure.unavailable }
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &cfError
        ) else { throw Failure.unavailable }
        disable(repo: repo)
        var query = baseQuery()
        query[kSecAttrAccount] = account.accountId
        query[kSecAttrLabel] = "1Melon Touch ID 解锁"
        query[kSecAttrDescription] = loginKey == nil ? "account-key" : withLoginKey
        query[kSecAttrAccessControl] = access
        query[kSecValueData] = LocalUnlockSecret(account: account, loginKey: loginKey).bytes
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        // 说明条目最后写：有了它才算登记好了
        var info = baseQuery(infoService)
        info[kSecAttrAccount] = account.accountId
        info[kSecAttrLabel] = "1Melon Touch ID 解锁（说明）"
        info[kSecAttrDescription] = query[kSecAttrDescription]
        info[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        info[kSecValueData] = Data()
        guard SecItemAdd(info as CFDictionary, nil) == errSecSuccess else {
            disable(repo: repo)
            throw Failure.unavailable
        }
    }

    /// 弹 Touch ID，成功后取出账户密钥和同步登录密钥（登记时存了的话）。失败时区分「取消」和「已作废」
    static func keys(repo: AccountRepository) async throws -> (accountKey: SymmetricKey, loginKey: LoginKey?) {
        guard let info = enrolled() else { throw Failure.invalidated }
        let context = LAContext()
        context.localizedCancelTitle = "输入主密码"
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "解锁 1Melon")
        } catch {
            throw Failure.cancelled
        }
        // 用刚才验证过的 context 读，不会再弹第二次
        var query = baseQuery()
        query[kSecAttrAccount] = info.accountId
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let secret = try? LocalUnlockSecret(bytes: data) else {
            // 指纹变了（条目已作废）或者条目坏了
            disable(repo: repo)
            throw Failure.invalidated
        }
        return (secret.accountKey, secret.loginKey)
    }

    /// 删掉两条钥匙串条目（和旧版本留下的本机文件）。说明条目先删：中途失败时也不会显示一个用不了的 Touch ID 按钮
    static func disable(repo: AccountRepository) {
        if isSigned {
            SecItemDelete(baseQuery(infoService) as CFDictionary)
            SecItemDelete(baseQuery() as CFDictionary)
        }
        repo.removeLegacyLocalUnlock()
    }
}

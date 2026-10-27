import Crypto
import Foundation

/// 本机快速解锁（Touch ID 等）要交给平台安全存储的那份秘密：账户密钥 AK，开着同步时再加同步登录密钥的种子。
/// **只在这台设备上，不进保险库格式、不同步、不落盘**。桌面端存进钥匙串（`MelonApp/TouchIDUnlock.swift`）：
/// 条目只有正式签名的 1Melon 能读，每次读都要过 Touch ID，指纹有增删时自动作废。
///
/// 字节：AK（32）‖ 登录密钥种子（32，可选）
public struct LocalUnlockSecret: Sendable {
    public let accountKey: SymmetricKey
    public let loginKey: LoginKey?

    public init(account: UnlockedAccount, loginKey: LoginKey?) {
        accountKey = account.accountKey
        self.loginKey = loginKey
    }

    /// 只交给平台安全存储，不能落盘或写日志
    public var bytes: Data {
        accountKey.withUnsafeBytes { Data($0) } + (loginKey?.seed ?? Data())
    }

    public init(bytes: Data) throws {
        guard bytes.count == 32 || bytes.count == 64 else { throw VaultError.invalidFormat("本机解锁数据长度不对") }
        accountKey = SymmetricKey(data: bytes.prefix(32))
        loginKey = bytes.count == 64 ? try LoginKey(seed: Data(bytes.suffix(32))) : nil
    }
}

public extension AccountRepository {
    /// 只属于这台设备的东西（Secret Key、同步状态）：**不同步、不备份**
    var deviceDirectory: URL { root.appendingPathComponent("device") }

    /// 旧版本（还没有正式签名时）的 Touch ID 文件：安全隔区密钥封着账户密钥。现在改存钥匙串，启动时删掉它
    var legacyLocalUnlockURL: URL { deviceDirectory.appendingPathComponent("local-unlock.json") }

    func removeLegacyLocalUnlock() {
        try? FileManager.default.removeItem(at: legacyLocalUnlockURL)
    }

    /// 用账户密钥直接解锁（本机快速解锁）。
    /// 账户密钥不对（比如账户重建过）时，保险库会全部打不开：这种情况按主密码错误处理，让用户输主密码。
    func unlock(accountKey: SymmetricKey) throws -> LoadedAccount {
        let account = try UnlockedAccount.open(try VaultStore.read(accountURL), accountKey: accountKey, secretKey: readSecretKey())
        let loaded = loadVaults(account)
        if loaded.vaults.isEmpty && !loaded.failures.isEmpty { throw VaultError.wrongPassword }
        return loaded
    }
}

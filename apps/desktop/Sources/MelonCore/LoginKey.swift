import Crypto
import Foundation

/// 同步用的登录密钥（spec/sync-api.md §3.1）：Ed25519，种子 = HKDF-SHA256(IKM = Argon2id 输出, salt = Secret Key,
/// info = "1melon:v2:auth:<accountId>", 32 字节)。和 KEK 来自同一次 Argon2id，但 info 不同，两者互相推不出来。
///
/// 服务端只拿到公钥；私钥平时只在内存里（每次用主密码解锁时重新派生）。唯一的例外是 Touch ID：
/// 种子和账户密钥一起存在钥匙串里（`LocalUnlockSecret`），这样用 Touch ID 解锁后也能同步。
public struct LoginKey: Sendable {
    private let box: SendableSigner
    var signer: Ed25519Signer { box.signer }

    /// 32 字节公钥：注册时上传，上传新账户文件时放进 `X-Auth-Public-Key`
    public var publicKey: Data { signer.publicKey.rawRepresentation }

    /// 从 32 字节种子还原（Touch ID 的本机文件里解出来的）
    init(seed: Data) throws {
        box = SendableSigner(signer: try Ed25519Signer(rawRepresentation: seed))
    }

    /// 32 字节种子：只交给平台安全存储（`LocalUnlockSecret`），不能落盘或写日志
    var seed: Data { signer.rawRepresentation }

    private init(box: SendableSigner) { self.box = box }

    static func derive(argon2Output: SymmetricKey, secretKey: SecretKey, accountId: String) -> LoginKey {
        // 种子固定 32 字节，不会失败
        LoginKey(box: SendableSigner(signer: seed(argon2Output: argon2Output, secretKey: secretKey, accountId: accountId)
            .withUnsafeBytes { try! Ed25519Signer(rawRepresentation: $0) }))
    }

    /// authSeed（sync-api §3.1）
    static func seed(argon2Output: SymmetricKey, secretKey: SecretKey, accountId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: argon2Output, salt: secretKey.bytes,
                               info: Data("1melon:v2:auth:\(accountId)".utf8), outputByteCount: 32)
    }

    /// 新设备还没有账户文件时用：KDF 参数来自登录挑战接口（sync-api §3.2）
    public static func derive(password: String, kdf: KDFParameters, secretKey: SecretKey, accountId: String) throws -> LoginKey {
        derive(argon2Output: try UnlockedAccount.deriveKEK(password: password, kdf: kdf), secretKey: secretKey, accountId: accountId)
    }

    // MARK: 签名（sync-api §3.2、§5.3）

    /// 登录：对 `1melon:v1:auth:<accountId>:<challenge 的 Base64 原文>` 签名
    public func signLogin(accountId: String, challenge: String) throws -> Data {
        try signer.signature(for: Self.loginMessage(accountId: accountId, challenge: challenge))
    }

    /// 上传账户文件：新登录私钥对 `1melon:v1:rotate:<accountId>:<文件的 sha256 hex>` 签名，放进 `X-Auth-Proof`
    public func signRotate(accountId: String, accountFile: Data) throws -> Data {
        try signer.signature(for: Self.rotateMessage(accountId: accountId, fileSHA256Hex: Self.sha256Hex(accountFile)))
    }

    static func loginMessage(accountId: String, challenge: String) -> Data {
        Data("1melon:v1:auth:\(accountId):\(challenge)".utf8)
    }

    static func rotateMessage(accountId: String, fileSHA256Hex: String) -> Data {
        Data("1melon:v1:rotate:\(accountId):\(fileSHA256Hex)".utf8)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// 同 `SendableKey`：Linux 上的 swift-crypto 没把 `Curve25519.Signing.PrivateKey` 标成 `Sendable`（CryptoKit 标了），
/// 它是不可变的值类型，跨线程传递是安全的。
private struct SendableSigner: @unchecked Sendable {
    let signer: Ed25519Signer
}

typealias Ed25519Signer = Curve25519.Signing.PrivateKey

public extension UnlockedAccount {
    /// 用主密码打开，同时派生登录密钥：Argon2id 只跑一次。账户必须带 Secret Key（同步要求 v2）。
    static func openWithLoginKey(_ data: Data, password: String, secretKey: SecretKey) throws -> (UnlockedAccount, LoginKey) {
        let file = try decodeFile(data)
        guard let sk = try checkSecretKey(file, secretKey) else { throw VaultError.secretKeyRequired }
        let argon = try deriveKEK(password: password, kdf: file.kdf)
        let account = try open(file, kek: sk.deriveKEK(argon2Output: argon, accountId: file.accountId), secretKey: sk)
        return (account, LoginKey.derive(argon2Output: argon, secretKey: sk, accountId: file.accountId))
    }
}

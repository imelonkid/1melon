import Crypto
import Foundation

/// 同步用的登录密钥（spec/sync-api.md §3.1）：Ed25519，种子 = HKDF-SHA256(IKM = Argon2id 输出, salt = Secret Key,
/// info = "1melon:v2:auth:<accountId>", 32 字节)。和 KEK 来自同一次 Argon2id，但 info 不同，两者互相推不出来。
///
/// 服务端只拿到公钥；私钥只在内存里，不落盘（每次解锁时重新派生）。
public struct LoginKey: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey

    /// 32 字节公钥：注册时上传，上传新账户文件时放进 `X-Auth-Public-Key`
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    static func derive(argon2Output: SymmetricKey, secretKey: SecretKey, accountId: String) -> LoginKey {
        // 种子固定 32 字节，不会失败
        LoginKey(privateKey: seed(argon2Output: argon2Output, secretKey: secretKey, accountId: accountId)
            .withUnsafeBytes { try! Curve25519.Signing.PrivateKey(rawRepresentation: $0) })
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
        try privateKey.signature(for: Self.loginMessage(accountId: accountId, challenge: challenge))
    }

    /// 上传账户文件：新登录私钥对 `1melon:v1:rotate:<accountId>:<文件的 sha256 hex>` 签名，放进 `X-Auth-Proof`
    public func signRotate(accountId: String, accountFile: Data) throws -> Data {
        try privateKey.signature(for: Self.rotateMessage(accountId: accountId, fileSHA256Hex: Self.sha256Hex(accountFile)))
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

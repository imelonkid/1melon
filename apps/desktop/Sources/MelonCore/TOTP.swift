import Crypto
import Foundation

/// RFC 6238 一次性验证码。各端必须通过 `spec/test-vectors/totp.json`。
public struct TOTP: Sendable, Equatable {
    public enum Algorithm: String, Sendable {
        case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
    }

    public enum ParseError: Error, Equatable {
        case empty
        case invalidSecret
        case invalidURL
        case unsupportedParameter(String)
    }

    public let secret: [UInt8]
    public let digits: Int
    public let period: Int
    public let algorithm: Algorithm

    public init(secret: [UInt8], digits: Int = 6, period: Int = 30, algorithm: Algorithm = .sha1) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// 解析条目里 `totp` 字段的值：Base32 密钥，或 `otpauth://totp/...` 链接。
    public static func parse(_ value: String) throws -> TOTP {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }
        guard text.lowercased().hasPrefix("otpauth://") else {
            return TOTP(secret: try decodeSecret(text))
        }
        guard let url = URLComponents(string: text), url.host?.lowercased() == "totp" else {
            throw ParseError.invalidURL
        }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }
        guard let secretText = query["secret"] else { throw ParseError.invalidSecret }

        var digits = 6, period = 30, algorithm = Algorithm.sha1
        if let d = query["digits"] {
            guard let n = Int(d), (6...8).contains(n) else { throw ParseError.unsupportedParameter("digits") }
            digits = n
        }
        if let p = query["period"] {
            guard let n = Int(p), (1...300).contains(n) else { throw ParseError.unsupportedParameter("period") }
            period = n
        }
        if let a = query["algorithm"] {
            guard let alg = Algorithm(rawValue: a.uppercased()) else { throw ParseError.unsupportedParameter("algorithm") }
            algorithm = alg
        }
        return TOTP(secret: try decodeSecret(secretText), digits: digits, period: period, algorithm: algorithm)
    }

    private static func decodeSecret(_ text: String) throws -> [UInt8] {
        guard let bytes = try? Base32.decode(text), !bytes.isEmpty else { throw ParseError.invalidSecret }
        return bytes
    }

    /// Unix 秒数 `time` 时刻的验证码（定长、左补零）。
    public func code(atUnixTime time: Int64) -> String {
        var counter = UInt64(time / Int64(period)).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset]) & 0x7F) << 24
            | UInt32(mac[offset + 1]) << 16
            | UInt32(mac[offset + 2]) << 8
            | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let code = String(binary % modulus)
        return String(repeating: "0", count: digits - code.count) + code
    }

    public func code(at date: Date = Date()) -> String {
        code(atUnixTime: Int64(date.timeIntervalSince1970.rounded(.down)))
    }

    /// 当前验证码还剩几秒失效（1...period）。
    public func secondsRemaining(at date: Date = Date()) -> Int {
        let t = Int64(date.timeIntervalSince1970.rounded(.down))
        return period - Int(t % Int64(period))
    }
}

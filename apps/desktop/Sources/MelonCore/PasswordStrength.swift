import Foundation

/// 密码强度估算（按字符池大小 × 长度估熵，再对短而单一的密码打折）。
/// 只是启发式，用来提示「弱 / 一般 / 强」，不是严格的破解难度评估。
public struct PasswordStrength: Sendable, Equatable {
    public enum Level: Sendable, Equatable, Comparable {
        case weak, fair, strong, veryStrong
    }

    public let bits: Int
    public let level: Level

    /// 安全报告用来判定「弱密码」的界限。
    public static let weakThreshold = 45

    public static func evaluate(_ password: String) -> PasswordStrength {
        let bits = estimateBits(password)
        let level: Level
        switch bits {
        case ..<weakThreshold: level = .weak
        case ..<65: level = .fair
        case ..<90: level = .strong
        default: level = .veryStrong
        }
        return PasswordStrength(bits: bits, level: level)
    }

    static func estimateBits(_ password: String) -> Int {
        guard !password.isEmpty else { return 0 }
        var hasLower = false, hasUpper = false, hasDigit = false, hasOther = false
        for scalar in password.unicodeScalars {
            switch scalar {
            case "a"..."z": hasLower = true
            case "A"..."Z": hasUpper = true
            case "0"..."9": hasDigit = true
            default: hasOther = true
            }
        }
        let length = Double(password.count)
        if hasDigit && !hasLower && !hasUpper && !hasOther {
            return Int((length * log2(10)).rounded())
        }
        var pool = 0
        if hasLower { pool += 26 }
        if hasUpper { pool += 26 }
        if hasDigit { pool += 10 }
        if hasOther { pool += 32 }
        var bits = length * log2(Double(pool))
        let classes = [hasLower, hasUpper, hasDigit, hasOther].filter { $0 }.count
        if classes <= 2 && password.count < 12 { bits *= 0.6 }
        return Int(bits.rounded())
    }
}

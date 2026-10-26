import Foundation

/// 密码生成器。随机源默认是系统 CSPRNG（`SystemRandomNumberGenerator`）；测试可以传入自己的生成器。
public enum PasswordGenerator {
    public static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    public static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    public static let digitChars = Array("0123456789")
    public static let symbolChars = Array("!@#$%^&*-_=+?")
    /// 容易看错的字符：0 O 1 l I
    public static let ambiguous: Set<Character> = ["0", "O", "1", "l", "I"]

    public static let lengthRange = 8...64
    public static let pinRange = 4...12
    public static let wordsRange = 3...10

    public struct RandomOptions: Sendable, Equatable {
        public var length: Int
        public var includeDigits: Bool
        public var includeSymbols: Bool
        public var excludeAmbiguous: Bool

        public init(length: Int = 20, includeDigits: Bool = true, includeSymbols: Bool = true, excludeAmbiguous: Bool = false) {
            self.length = length
            self.includeDigits = includeDigits
            self.includeSymbols = includeSymbols
            self.excludeAmbiguous = excludeAmbiguous
        }
    }

    /// 随机密码：每个启用的字符集至少出现一次，其余位置从全部字符里均匀抽取，最后打乱顺序。
    public static func random<R: RandomNumberGenerator>(_ options: RandomOptions, using rng: inout R) -> String {
        var sets = [lowercase, uppercase]
        if options.includeDigits { sets.append(digitChars) }
        if options.includeSymbols { sets.append(symbolChars) }
        if options.excludeAmbiguous { sets = sets.map { $0.filter { !ambiguous.contains($0) } } }

        let length = min(max(options.length, lengthRange.lowerBound), lengthRange.upperBound)
        let all = sets.flatMap { $0 }
        var chars = sets.map { $0.randomElement(using: &rng)! }
        while chars.count < length { chars.append(all.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }

    public static func random(_ options: RandomOptions = RandomOptions()) -> String {
        var rng = SystemRandomNumberGenerator()
        return random(options, using: &rng)
    }

    public static func pin<R: RandomNumberGenerator>(length: Int, using rng: inout R) -> String {
        let n = min(max(length, pinRange.lowerBound), pinRange.upperBound)
        return String((0..<n).map { _ in digitChars.randomElement(using: &rng)! })
    }

    public static func pin(length: Int = 6) -> String {
        var rng = SystemRandomNumberGenerator()
        return pin(length: length, using: &rng)
    }

    /// 易记密码：从词表里随机取 `words` 个单词，用 `-` 连接，可选首字母大写、插入一个两位数。
    /// 强度取决于词表大小：要用 EFF 长词表（7776 词）这一量级，几十个词的小词表不够安全。
    public static func memorable<R: RandomNumberGenerator>(
        words: Int, wordlist: [String] = EFFWordlist.words, capitalize: Bool = true, insertNumber: Bool = true, using rng: inout R
    ) -> String {
        precondition(!wordlist.isEmpty, "词表不能为空")
        let words = min(max(words, wordsRange.lowerBound), wordsRange.upperBound)
        var parts = (0..<words).map { _ -> String in
            let w = wordlist.randomElement(using: &rng)!
            return capitalize ? w.prefix(1).uppercased() + w.dropFirst() : w
        }
        if insertNumber {
            parts.insert(String(Int.random(in: 10...99, using: &rng)), at: Int.random(in: 0...parts.count, using: &rng))
        }
        return parts.joined(separator: "-")
    }

    public static func memorable(words: Int = 4, capitalize: Bool = true, insertNumber: Bool = true) -> String {
        var rng = SystemRandomNumberGenerator()
        return memorable(words: words, capitalize: capitalize, insertNumber: insertNumber, using: &rng)
    }

    /// 易记密码的真实强度：只算随机抽取带来的熵（攻击者知道词表和规则）。
    /// 首字母大写是固定规则，不加熵；插入数字 = 90 种数字 × (词数 + 1) 个位置。
    public static func memorableBits(words: Int, wordlistSize: Int = EFFWordlist.words.count, insertNumber: Bool) -> Int {
        let words = min(max(words, wordsRange.lowerBound), wordsRange.upperBound)
        var bits = Double(words) * log2(Double(wordlistSize))
        if insertNumber { bits += log2(90) + log2(Double(words + 1)) }
        return Int(bits.rounded(.down))
    }
}

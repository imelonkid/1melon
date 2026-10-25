/// RFC 4648 Base32（TOTP 密钥用）。解码时忽略大小写、空格、连字符和末尾的 `=`。
public enum Base32 {
    public enum DecodingError: Error, Equatable {
        case invalidCharacter(Character)
        case invalidLength
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func decode(_ string: String) throws -> [UInt8] {
        var buffer: UInt64 = 0
        var bitCount = 0
        var out: [UInt8] = []
        var symbols = 0
        for ch in string {
            if ch == " " || ch == "-" || ch == "=" { continue }
            guard let upper = ch.uppercased().first,
                  let value = alphabet.firstIndex(of: upper) else {
                throw DecodingError.invalidCharacter(ch)
            }
            buffer = (buffer << 5) | UInt64(value)
            bitCount += 5
            symbols += 1
            if bitCount >= 8 {
                bitCount -= 8
                out.append(UInt8((buffer >> UInt64(bitCount)) & 0xFF))
            }
        }
        // 合法的 Base32 每 8 个字符一组，组内只可能剩 0、2、4、5、7 个字符
        if [1, 3, 6].contains(symbols % 8) { throw DecodingError.invalidLength }
        return out
    }

    public static func encode(_ bytes: [UInt8]) -> String {
        var out = ""
        var buffer: UInt64 = 0
        var bitCount = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt64(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                out.append(alphabet[Int((buffer >> UInt64(bitCount)) & 0x1F)])
            }
        }
        if bitCount > 0 {
            out.append(alphabet[Int((buffer << UInt64(5 - bitCount)) & 0x1F)])
        }
        while out.count % 8 != 0 { out.append("=") }
        return out
    }
}

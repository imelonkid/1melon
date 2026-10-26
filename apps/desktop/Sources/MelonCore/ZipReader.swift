#if canImport(Compression)
import Compression
import Foundation

/// 只读的最小 ZIP 读取器：从中央目录找到指定文件，解出内容。**只在内存里**，不把明文写到磁盘上。
/// 只支持「不压缩（0）」和「DEFLATE（8）」两种方式，不支持加密和 ZIP64（.1pux 用不到）。
public enum ZipReader {
    public enum Failure: Error { case malformed, unsupported, tooLarge }

    /// 解压后最大 256 MB，防止恶意压缩包把内存撑爆
    static let maxUncompressed = 256 * 1024 * 1024

    static func entry(named name: String, in zip: Data) throws -> Data? {
        let bytes = [UInt8](zip)
        func u16(_ o: Int) throws -> Int {
            guard o + 2 <= bytes.count else { throw Failure.malformed }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int {
            guard o + 4 <= bytes.count else { throw Failure.malformed }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }

        // 从末尾往前找「中央目录结束」记录（签名 0x06054b50，后面最多 64 KB 注释）
        guard bytes.count >= 22 else { throw Failure.malformed }
        var eocd = -1
        for o in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1) where try u32(o) == 0x0605_4b50 {
            eocd = o
            break
        }
        guard eocd >= 0 else { throw Failure.malformed }
        let count = try u16(eocd + 10)
        var p = try u32(eocd + 16)

        for _ in 0..<count {
            guard try u32(p) == 0x0201_4b50 else { throw Failure.malformed }
            let flags = try u16(p + 8), method = try u16(p + 10)
            let compressed = try u32(p + 20), uncompressed = try u32(p + 24)
            let nameLen = try u16(p + 28), extraLen = try u16(p + 30), commentLen = try u16(p + 32)
            let localOffset = try u32(p + 42)
            guard p + 46 + nameLen <= bytes.count else { throw Failure.malformed }
            let entryName = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard entryName == name else { continue }

            guard flags & 0x1 == 0 else { throw Failure.unsupported } // 加密
            guard uncompressed <= maxUncompressed else { throw Failure.tooLarge }
            guard try u32(localOffset) == 0x0403_4b50 else { throw Failure.malformed }
            let start = localOffset + 30 + (try u16(localOffset + 26)) + (try u16(localOffset + 28))
            guard start + compressed <= bytes.count else { throw Failure.malformed }
            let payload = Array(bytes[start..<(start + compressed)])
            switch method {
            case 0:
                return Data(payload)
            case 8:
                return try inflate(payload, size: uncompressed)
            default:
                throw Failure.unsupported
            }
        }
        return nil
    }

    /// 原始 DEFLATE 解压（Apple 的 COMPRESSION_ZLIB 就是不带头的 DEFLATE）
    static func inflate(_ input: [UInt8], size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: size)
        let n = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, size, src.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw Failure.malformed }
        return Data(out)
    }
}
#endif

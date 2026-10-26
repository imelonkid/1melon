import Foundation

/// 对象存储上的版本清单 `latest.json`（项目基线「桌面应用 · 版本清单」，字段只增不改）。
public struct ReleaseManifest: Decodable, Equatable, Sendable {
    public let version: String
    public let tag: String
    public let date: String?
    public let notes: String?
    public let files: [String: String]
    public let sha256: [String: String]?

    /// arm64 安装包地址；只接受 https
    public var downloadURL: URL? {
        guard let s = files["arm64"] ?? files.values.first, let url = URL(string: s), url.scheme == "https" else { return nil }
        return url
    }
}

/// 语义化版本比较：只比 X.Y.Z 三段数字（清单和 App 的版本都由 tag 注入，没有预发布后缀）
public enum SemVer {
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let p = s.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
            return p + Array(repeating: 0, count: 3 - p.count)
        }
        return parts(b).lexicographicallyPrecedes(parts(a))
    }
}

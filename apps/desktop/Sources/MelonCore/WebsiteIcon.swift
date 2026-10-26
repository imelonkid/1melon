import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// 网站图标（spec §5.2「网站图标」）：直接向网站本身取，不经任何第三方服务。
/// - 只在保存条目、网址的主机变了时取一次（由界面层决定何时调用）
/// - 内网和本机地址一律不取：IP、localhost、.local 等，避免 App 去探测内网
/// - 只走 https、不带 cookie、不用缓存；页面最多读 300 KB，图标最多 200 KB；整个过程有超时
/// - 取回来后重新绘制成 64×64 的 PNG（不超过 16 KB）再存，不保留原始文件
public enum WebsiteIcon {
    public static let pixelSize = 64
    public static let maxStoredBytes = 16 * 1024
    static let maxPageBytes = 300 * 1024
    static let maxIconBytes = 200 * 1024

    // MARK: 能不能取

    /// 条目网址对应的、允许请求图标的主机（小写）。不允许就返回 nil。
    /// 没写协议的按 https；写了 http 的也只用 https 去取。
    public static func host(forURL raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let comps = URLComponents(string: withScheme),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              comps.port == nil || comps.port == 443 || comps.port == 80,
              let host = comps.host?.lowercased(), isPublicHostname(host) else { return nil }
        return host
    }

    /// 只放行看起来是公网域名的主机：不是 IP，不是本机 / 内网名字，至少有一个点
    static func isPublicHostname(_ host: String) -> Bool {
        let h = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !h.isEmpty, h.contains("."), !h.contains(":") else { return false } // 冒号：IPv6
        if h.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false } // IPv4
        let blockedSuffixes = [".local", ".localhost", ".lan", ".home", ".internal", ".intranet", ".corp", ".arpa", ".test", ".invalid"]
        if h == "localhost" || blockedSuffixes.contains(where: { h.hasSuffix($0) }) { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        return h.allSatisfy { allowed.contains($0) || !$0.isASCII } // 非 ASCII：国际化域名
    }

    /// 请求时也要过一遍同样的规则（重定向、页面里声明的图标地址都可能指到别处）
    static func isAllowedRequestURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return isPublicHostname(host) && (url.port == nil || url.port == 443)
    }

    // MARK: 从页面里找图标

    /// 页面里 `<link rel="…icon…" href="…">` 声明的图标地址，按清晰度从高到低排；最后补上 `/favicon.ico`。
    /// 不要 SVG（解不了）和 mask-icon（单色剪影）；只留 https 地址。
    static func candidates(html: String, pageURL: URL) -> [URL] {
        var scored: [(URL, Int)] = []
        let linkTag = try! NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
        let ns = html as NSString
        for m in linkTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask-icon"),
                  let href = attribute("href", in: tag), !href.isEmpty else { continue }
            let type = attribute("type", in: tag)?.lowercased() ?? ""
            if type.contains("svg") || href.lowercased().hasSuffix(".svg") || href.lowercased().hasPrefix("data:") { continue }
            guard let url = URL(string: href, relativeTo: pageURL)?.absoluteURL, isAllowedRequestURL(url) else { continue }
            var score = rel.contains("apple-touch-icon") ? 180 : 32
            if let sizes = attribute("sizes", in: tag),
               let n = sizes.lowercased().split(separator: "x").first.flatMap({ Int($0) }) {
                score = n
            }
            scored.append((url, score))
        }
        // 不小于 64px 的优先（缩小后清楚），其中越接近 64 越好；都太小的话越大越好（放大会糊）
        var result = scored.sorted { a, b in
            let (ak, bk) = (a.1 >= pixelSize, b.1 >= pixelSize)
            if ak != bk { return ak }
            return ak ? a.1 < b.1 : a.1 > b.1
        }.map(\.0)
        if let favicon = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL, isAllowedRequestURL(favicon) {
            result.append(favicon)
        }
        var seen = Set<URL>()
        return result.filter { seen.insert($0).inserted }
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1...3 where m.range(at: i).location != NSNotFound {
            return ns.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: 取回并规整

    /// 取 `urlString` 对应网站的图标：返回主机和 64×64 PNG；取不到返回 nil（不抛错，界面退回类型图标）。
    public static func fetch(forURL urlString: String?) async -> (host: String, png: Data)? {
        #if canImport(ImageIO)
        guard let host = host(forURL: urlString), let page = URL(string: "https://\(host)/") else { return nil }
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        var candidates: [URL] = []
        if let (data, finalURL) = await download(page, limit: maxPageBytes, session: session) {
            let html = String(decoding: data, as: UTF8.self)
            candidates = Self.candidates(html: html, pageURL: finalURL)
        } else if let favicon = URL(string: "https://\(host)/favicon.ico") {
            candidates = [favicon]
        }
        for url in candidates.prefix(4) {
            if let (data, _) = await download(url, limit: maxIconBytes, session: session), let png = normalize(data) {
                return (host, png)
            }
        }
        #endif
        return nil
    }

    #if canImport(ImageIO)
    /// 不带 cookie、不用缓存、不带凭据，短超时；重定向只允许去公网 https 地址
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "1Melon", "Accept": "text/html,image/*;q=0.9,*/*;q=0.5"]
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    /// 最多读 `limit` 字节，超过就放弃；只接受 2xx
    static func download(_ url: URL, limit: Int, session: URLSession) async -> (Data, URL)? {
        guard isAllowedRequestURL(url) else { return nil }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.expectedContentLength <= Int64(limit) else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
            return (data, http.url ?? url)
        } catch {
            return nil
        }
    }

    /// 解码任意常见格式（PNG、ICO、JPEG、GIF、WebP），等比缩放后居中画进 64×64 透明画布，编码成 PNG
    static func normalize(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        // ICO 里有多张：挑最大的一张来缩
        var best = 0, bestArea = 0
        for i in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if w * h > bestArea { bestArea = w * h; best = i }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary),
              image.width >= 8, image.height >= 8 else { return nil }

        let side = pixelSize
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        ctx.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }

        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest), buffer.length <= maxStoredBytes else { return nil }
        return buffer as Data
    }

    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, WebsiteIcon.isAllowedRequestURL(url) else { return nil }
            return request
        }
    }
    #endif
}

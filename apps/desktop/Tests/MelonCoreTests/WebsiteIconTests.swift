import Foundation
import XCTest
@testable import MelonCore
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

final class WebsiteIconTests: XCTestCase {
    func testOnlyPublicHostsAreAllowed() {
        XCTAssertEqual(WebsiteIcon.host(forURL: "github.com"), "github.com")
        XCTAssertEqual(WebsiteIcon.host(forURL: "https://WWW.Apple.com/cn/"), "www.apple.com")
        XCTAssertEqual(WebsiteIcon.host(forURL: "http://example.com/login"), "example.com")
        XCTAssertEqual(WebsiteIcon.host(forURL: " ecs.console.aliyun.com "), "ecs.console.aliyun.com")
        for blocked in ["192.168.31.1", "http://10.0.0.1:8080", "localhost", "https://localhost/x", "nas.local", "router",
                        "printer.lan", "svc.internal", "[::1]", "https://[fe80::1]/", "example.com:8443", "ftp://example.com",
                        "", "   ", "1.2.3.4.in-addr.arpa", "a.test"] {
            XCTAssertNil(WebsiteIcon.host(forURL: blocked), blocked)
        }
        XCTAssertNil(WebsiteIcon.host(forURL: nil))
    }

    func testCandidatesFromHTML() {
        let page = URL(string: "https://example.com/app/")!
        let html = """
        <html><head>
        <link rel="icon" href="/favicon-16.png" sizes="16x16">
        <LINK REL='apple-touch-icon' HREF='/apple-touch-icon.png'>
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <link rel="mask-icon" href="/mask.png">
        <link rel="icon" href="https://cdn.example.net/icon-96.png" sizes="96x96">
        <link rel="icon" href="http://insecure.example.com/i.png">
        <link rel="icon" href="https://192.168.1.1/i.png">
        <link rel="stylesheet" href="/style.css">
        </head></html>
        """
        let urls = WebsiteIcon.candidates(html: html, pageURL: page).map(\.absoluteString)
        XCTAssertEqual(urls, [
            "https://cdn.example.net/icon-96.png",
            "https://example.com/apple-touch-icon.png",
            "https://example.com/favicon-16.png",
            "https://example.com/favicon.ico",
        ])
    }

    func testRedirectTargetsAreChecked() {
        XCTAssertTrue(WebsiteIcon.isAllowedRequestURL(URL(string: "https://example.com/favicon.ico")!))
        XCTAssertFalse(WebsiteIcon.isAllowedRequestURL(URL(string: "http://example.com/favicon.ico")!))
        XCTAssertFalse(WebsiteIcon.isAllowedRequestURL(URL(string: "https://127.0.0.1/favicon.ico")!))
        XCTAssertFalse(WebsiteIcon.isAllowedRequestURL(URL(string: "https://example.com:8443/favicon.ico")!))
    }

    #if canImport(ImageIO)
    /// 任意尺寸、非正方形的图片都规整成 64×64 PNG，并且不超过 16 KB
    func testNormalizeProducesSmallSquarePNG() throws {
        let ctx = CGContext(data: nil, width: 300, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
        let buffer = NSMutableData()
        let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let png = try XCTUnwrap(WebsiteIcon.normalize(buffer as Data))
        XCTAssertLessThanOrEqual(png.count, WebsiteIcon.maxStoredBytes)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.png.identifier)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 64)
        XCTAssertNil(WebsiteIcon.normalize(Data("not an image".utf8)))
    }

    /// 真的去网站取：`MELON_NET_TEST=1` 才跑（会访问 github.com）
    func testLiveFetch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MELON_NET_TEST"] == "1", "设置 MELON_NET_TEST=1 才联网测试")
        let fetched = await WebsiteIcon.fetch(forURL: "github.com")
        let result = try XCTUnwrap(fetched)
        XCTAssertEqual(result.host, "github.com")
        XCTAssertLessThanOrEqual(result.png.count, WebsiteIcon.maxStoredBytes)
        let none = await WebsiteIcon.fetch(forURL: "192.168.31.1")
        XCTAssertNil(none)
        // 其他常见站点：只打印结果，不因为个别网站一时取不到就失败
        for site in ["apple.com", "aliyun.com", "taobao.com", "netflix.com", "figma.com", "openai.com"] {
            let r = await WebsiteIcon.fetch(forURL: site)
            print("ICON \(site): \(r.map { "\($0.png.count) 字节" } ?? "取不到")")
        }
    }
    #endif
}

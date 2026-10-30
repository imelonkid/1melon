import Foundation
import XCTest
@testable import MelonCore
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// 手动复现用：设了 `MELON_SEED_DIR` 才运行，在那个目录里建一个带 250 个虚构条目的账户（主密码 `demo-password`），
/// 然后 `MELON_DATA_DIR=<那个目录> swift run MelonApp` 打开看。没设就跳过。
///
///     MELON_SEED_DIR=/tmp/1melon-demo swift test --filter SeedDemoVault
final class SeedDemoVault: XCTestCase {
    func testSeed() throws {
        guard let dir = ProcessInfo.processInfo.environment["MELON_SEED_DIR"], !dir.isEmpty else {
            throw XCTSkip("没设 MELON_SEED_DIR")
        }
        let count = Int(ProcessInfo.processInfo.environment["MELON_SEED_COUNT"] ?? "") ?? 250
        let repo = AccountRepository(root: URL(fileURLWithPath: dir))
        let now = Date().unixMilliseconds
        var loaded = try repo.create(password: "demo-password", now: now)
        var vault = loaded.vaults[0]
        var items = PerformanceFixtures.items(count, withIcons: Self.demoIcon())
        for i in stride(from: 3, to: items.count, by: 25) {
            let (ref, file) = try AttachmentFile.seal(Data("演示附件 \(i)\n".utf8), accountId: loaded.account.accountId)
            try VaultStore.write(file, to: repo.attachmentURL(ref.id))
            PerformanceFixtures.attach(ref, to: &items[i])
        }
        for item in items { vault.save(item, now: item.modified) }
        try repo.save(&vault, now: now)
        loaded.vaults[0] = vault
        print("已在 \(dir) 建好 \(items.count) 个条目，主密码 demo-password")
    }

    /// 64×64 的纯色 PNG，和取回来的网站图标一样大
    static func demoIcon() -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
        #else
        return nil
        #endif
    }
}

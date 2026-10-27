import Crypto
import Foundation
import XCTest
@testable import MelonCore

// MARK: 按条目合并

final class VaultMergeTests: XCTestCase {
    /// 同一个保险库的两份副本（同一个保险库密钥），模拟两台设备
    func twoCopies(_ setup: (inout UnlockedVault) -> Void = { _ in }) throws -> (UnlockedVault, UnlockedVault) {
        var base = try newVault()
        setup(&base)
        let data = try base.serialized(now: t0)
        return (try UnlockedVault.open(data, account: testAccount), try UnlockedVault.open(data, account: testAccount))
    }

    func ids(_ v: UnlockedVault) -> [String: Int] { Dictionary(uniqueKeysWithValues: v.items.map { ($0.id, $0.rev) }) }

    func testDisjointChangesAreUnioned() throws {
        var (a, b) = try twoCopies()
        a.save(sampleLogin(t0, title: "甲"), now: t0 + 1)
        b.save(sampleLogin(t0, title: "乙"), now: t0 + 2)
        let (ab, report) = try VaultMerge.merge(local: a, remote: b)
        XCTAssertEqual(Set(ab.activeItems.map(\.title)), ["甲", "乙"])
        XCTAssertEqual(report, .init(fromRemote: 1, conflicts: 0))
        let (ba, _) = try VaultMerge.merge(local: b, remote: a)
        XCTAssertEqual(ids(ab), ids(ba))
    }

    func testHigherRevWins() throws {
        let item = sampleLogin(t0)
        var (a, b) = try twoCopies { $0.save(item, now: t0) }
        var edited = a.items[0]
        edited.title = "改过一次"
        a.save(edited, now: t0 + 10)
        edited.title = "改过两次"
        a.save(edited, now: t0 + 20)
        var other = b.items[0]
        other.title = "另一台改了一次，但更晚"
        b.save(other, now: t0 + 99)
        let (merged, report) = try VaultMerge.merge(local: b, remote: a)
        XCTAssertEqual(merged.items.first { $0.id == item.id }?.title, "改过两次")
        XCTAssertEqual(merged.items.first { $0.id == item.id }?.rev, 3)
        XCTAssertEqual(report.conflicts, 0)
    }

    func testSameRevDifferentContentKeepsLaterAndMakesSameCopyOnBothSides() throws {
        let item = sampleLogin(t0)
        var (a, b) = try twoCopies { $0.save(item, now: t0) }
        var x = a.items[0]; x.title = "甲改的"; a.save(x, now: t0 + 10)
        var y = b.items[0]; y.title = "乙改的"; b.save(y, now: t0 + 20)

        let (ab, r1) = try VaultMerge.merge(local: a, remote: b)
        let (ba, r2) = try VaultMerge.merge(local: b, remote: a)
        XCTAssertEqual(r1.conflicts, 1)
        XCTAssertEqual(r2.conflicts, 1)
        XCTAssertEqual(ab.items.first { $0.id == item.id }?.title, "乙改的")
        XCTAssertEqual(ba.items.first { $0.id == item.id }?.title, "乙改的")
        // 两边生成的冲突副本是同一个：id、内容都一样
        let copyA = try XCTUnwrap(ab.items.first { $0.id != item.id })
        let copyB = try XCTUnwrap(ba.items.first { $0.id != item.id })
        XCTAssertEqual(copyA.id, copyB.id)
        XCTAssertEqual(copyA.title, "甲改的" + VaultMerge.conflictSuffix)
        XCTAssertEqual(VaultMerge.canonical(copyA), VaultMerge.canonical(copyB))
        XCTAssertTrue(isLowercaseUUID(copyA.id))

        // 再合并一次不会再生副本（收敛）
        let (again, r3) = try VaultMerge.merge(local: ab, remote: ba)
        XCTAssertEqual(r3, .init(fromRemote: 0, conflicts: 0))
        XCTAssertEqual(again.items.count, 2)
    }

    func testDeleteVersusEditKeepsEditedCopy() throws {
        let item = sampleLogin(t0)
        var (a, b) = try twoCopies { $0.save(item, now: t0) }
        a.delete(id: item.id, now: t0 + 30)                 // 删除更晚，墓碑胜出
        var y = b.items[0]; y.title = "删之前改过"; b.save(y, now: t0 + 10)
        let (merged, report) = try VaultMerge.merge(local: a, remote: b)
        XCTAssertEqual(merged.items.first { $0.id == item.id }?.deleted, true)
        XCTAssertEqual(report.conflicts, 1)
        XCTAssertEqual(merged.activeItems.map(\.title), ["删之前改过" + VaultMerge.conflictSuffix])

        // 反过来：编辑更晚胜出，墓碑不留副本
        var (c, d) = try twoCopies { $0.save(item, now: t0) }
        c.delete(id: item.id, now: t0 + 10)
        var z = d.items[0]; z.title = "删之后改的"; d.save(z, now: t0 + 30)
        let (m2, r2) = try VaultMerge.merge(local: c, remote: d)
        XCTAssertEqual(m2.activeItems.map(\.title), ["删之后改的"])
        XCTAssertEqual(r2.conflicts, 0)
    }

    func testMergedSerializesAndReopens() throws {
        var (a, b) = try twoCopies { $0.save(sampleLogin(t0), now: t0) }
        a.save(sampleLogin(t0, title: "本机"), now: t0 + 1)
        b.save(sampleLogin(t0, title: "云端"), now: t0 + 2)
        b.meta.name = "改名了"
        _ = try b.serialized(now: t0 + 5)               // 云端写出得更晚：元数据用云端的
        var (merged, _) = try VaultMerge.merge(local: a, remote: b)
        let reopened = try UnlockedVault.open(try merged.serialized(now: t0 + 3), account: testAccount)
        XCTAssertEqual(Set(reopened.activeItems.map(\.title)), ["GitHub", "本机", "云端"])
        XCTAssertEqual(reopened.meta.name, "改名了")
        XCTAssertGreaterThan(reopened.updated, b.updated)  // 时钟比云端慢也只增不减
    }

    func testDifferentVaultIsRejected() throws {
        XCTAssertThrowsError(try VaultMerge.merge(local: try newVault(), remote: try newVault())) {
            XCTAssertEqual($0 as? VaultMerge.MergeError, .differentVault)
        }
    }

    func testUpdatedNeverGoesBackwards() throws {
        var v = try newVault()
        _ = try v.serialized(now: t0 + 100)
        _ = try v.serialized(now: t0)                   // 时钟往回拨
        XCTAssertEqual(v.updated, t0 + 101)
    }
}

// MARK: 同步引擎（内存里的假服务端）

/// 按 sync-api §5 的语义：每个文件一个 rev，If-Match / If-None-Match，删除留标记，`since` 按写入序号
actor FakeServer {
    struct Stored { var data: Data; var rev: Int; var deleted: Bool; var seq: Int }
    var files: [String: Stored] = [:]
    var seq = 0
    var uploads = 0
    /// 下一次上传前先让「别的设备」写一次（制造 412）
    var interfere: (@Sendable (inout [String: Stored], inout Int) -> Void)?

    func setInterfere(_ f: (@Sendable (inout [String: Stored], inout Int) -> Void)?) { interfere = f }

    func list(since: String?) -> ([RemoteFile], String) {
        let from = Int(since ?? "") ?? 0
        let changed = files.filter { $0.value.seq > from }.map {
            RemoteFile(name: $0.key, rev: $0.value.rev, sha256: LoginKey.sha256Hex($0.value.data), deleted: $0.value.deleted)
        }
        return (changed, String(seq))
    }

    func get(_ name: String) throws -> (Data, Int) {
        guard let f = files[name], !f.deleted else { throw SyncTransportError.notFound }
        return (f.data, f.rev)
    }

    func put(_ name: String, _ data: Data, base: Int?, proof: AccountUploadProof?) throws -> Int {
        if let f = interfere { interfere = nil; f(&files, &seq) }
        let cur = files[name]
        if let base {
            guard let cur, !cur.deleted, cur.rev == base else { throw SyncTransportError.conflict(rev: cur?.rev) }
        } else if let cur, !cur.deleted {
            throw SyncTransportError.conflict(rev: cur.rev)
        }
        if name == SyncEngine.accountFile, proof == nil { throw SyncTransportError.notFound }
        seq += 1
        uploads += 1
        let rev = (cur?.rev ?? 0) + 1
        files[name] = Stored(data: data, rev: rev, deleted: false, seq: seq)
        return rev
    }

    func del(_ name: String, base: Int) throws -> Int {
        guard let cur = files[name], !cur.deleted, cur.rev == base else { throw SyncTransportError.conflict(rev: files[name]?.rev) }
        seq += 1
        files[name] = Stored(data: Data(), rev: cur.rev + 1, deleted: true, seq: seq)
        return cur.rev + 1
    }

    /// 测试用：直接把云端文件换成指定内容（模拟篡改或回退）
    func replace(_ name: String, data: Data, rev: Int) {
        seq += 1
        files[name] = Stored(data: data, rev: rev, deleted: false, seq: seq)
    }
}

struct FakeTransport: SyncTransport {
    let server: FakeServer
    func listFiles(since cursor: String?) async throws -> (files: [RemoteFile], cursor: String) { await server.list(since: cursor) }
    func download(_ name: String) async throws -> (data: Data, rev: Int) { try await server.get(name) }
    func upload(_ name: String, data: Data, baseRev: Int?, proof: AccountUploadProof?) async throws -> Int {
        try await server.put(name, data, base: baseRev, proof: proof)
    }
    func delete(_ name: String, baseRev: Int) async throws -> Int { try await server.del(name, base: baseRev) }
}

/// 一台设备：自己的数据目录 + 同步状态
struct Device {
    let repo: AccountRepository
    var state: SyncState
    let engine: SyncEngine

    init(server: FakeServer, accountId: String) throws {
        repo = AccountRepository(root: FileManager.default.temporaryDirectory.appendingPathComponent("1melon-sync-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: repo.vaultsDirectory, withIntermediateDirectories: true)
        state = SyncState(server: "https://example.test", accountId: accountId)
        engine = SyncEngine(repository: repo, transport: FakeTransport(server: server))
    }

    mutating func sync(_ account: UnlockedAccount = testAccount, key: LoginKey? = nil, now: Int64 = t0) async throws -> SyncResult {
        try await engine.sync(account: account, state: &state, accountUploadKey: key, now: now)
    }

    func vaults(_ account: UnlockedAccount = testAccount) -> [UnlockedVault] { repo.loadVaults(account).vaults }

    func edit(_ vaultId: String, now: Int64, _ change: (inout UnlockedVault) -> Void) throws {
        var v = try UnlockedVault.open(try VaultStore.read(repo.vaultURL(vaultId)), account: testAccount)
        change(&v)
        try repo.save(&v, now: now)
    }
}

final class SyncEngineTests: XCTestCase {
    func titles(_ d: Device) -> Set<String> { Set(d.vaults().flatMap { $0.activeItems.map(\.title) }) }

    func testTwoDevicesConverge() async throws {
        let server = FakeServer()
        var a = try Device(server: server, accountId: testAccount.accountId)
        var b = try Device(server: server, accountId: testAccount.accountId)
        var v = try newVault()
        v.save(sampleLogin(t0, title: "共同"), now: t0)
        try a.repo.save(&v, now: t0)

        var r = try await a.sync()
        XCTAssertEqual(r.uploaded, 1)
        r = try await b.sync()
        XCTAssertEqual(r.updatedVaults, [v.vaultId])
        XCTAssertEqual(titles(b), ["共同"])

        // 两边各加一条，再各同步一次
        try a.edit(v.vaultId, now: t0 + 10) { $0.save(sampleLogin(t0, title: "甲加的"), now: t0 + 10) }
        try b.edit(v.vaultId, now: t0 + 20) { $0.save(sampleLogin(t0, title: "乙加的"), now: t0 + 20) }
        _ = try await a.sync()
        r = try await b.sync()                         // 两边都改了：合并后上传
        XCTAssertTrue(r.failures.isEmpty, "\(r.failures)")
        _ = try await a.sync()
        XCTAssertEqual(titles(a), ["共同", "甲加的", "乙加的"])
        XCTAssertEqual(titles(b), titles(a))

        // 都同步过以后，再同步一轮什么都不传
        let uploads = await server.uploads
        _ = try await a.sync()
        _ = try await b.sync()
        let after = await server.uploads
        XCTAssertEqual(after, uploads)
    }

    func testConflictOnUploadMergesAndRetries() async throws {
        let server = FakeServer()
        var a = try Device(server: server, accountId: testAccount.accountId)
        var b = try Device(server: server, accountId: testAccount.accountId)
        var v = try newVault()
        try a.repo.save(&v, now: t0)
        _ = try await a.sync()
        _ = try await b.sync()

        // b 写好了一版，在 a 列完文件、上传之前抢先传上去：a 的上传会 412，下载合并后重传
        try b.edit(v.vaultId, now: t0 + 5) { $0.save(sampleLogin(t0, title: "乙先写"), now: t0 + 5) }
        let bData = try VaultStore.read(b.repo.vaultURL(v.vaultId))
        let name = SyncEngine.fileName(vaultId: v.vaultId)
        await server.setInterfere { files, seq in
            seq += 1
            files[name] = FakeServer.Stored(data: bData, rev: files[name]!.rev + 1, deleted: false, seq: seq)
        }
        try a.edit(v.vaultId, now: t0 + 6) { $0.save(sampleLogin(t0, title: "甲后写"), now: t0 + 6) }
        let r = try await a.sync()
        XCTAssertTrue(r.failures.isEmpty, "\(r.failures)")
        XCTAssertEqual(r.uploaded, 1)
        XCTAssertEqual(titles(a), ["乙先写", "甲后写"])
    }

    func testRemoteDeletionRemovesUnchangedLocalVault() async throws {
        let server = FakeServer()
        var a = try Device(server: server, accountId: testAccount.accountId)
        var b = try Device(server: server, accountId: testAccount.accountId)
        var v = try newVault("临时")
        try a.repo.save(&v, now: t0)
        _ = try await a.sync()
        _ = try await b.sync()

        try FileManager.default.removeItem(at: a.repo.vaultURL(v.vaultId))   // a 删掉空保险库
        _ = try await a.sync()
        let r = try await b.sync()
        XCTAssertEqual(r.removedVaults, [v.vaultId])
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.repo.vaultURL(v.vaultId).path))
    }

    func testRollbackIsRejected() async throws {
        let server = FakeServer()
        var a = try Device(server: server, accountId: testAccount.accountId)
        var v = try newVault()
        try a.repo.save(&v, now: t0)
        let old = try VaultStore.read(a.repo.vaultURL(v.vaultId))
        _ = try await a.sync()
        try a.edit(v.vaultId, now: t0 + 50) { $0.save(sampleLogin(t0), now: t0 + 50) }
        _ = try await a.sync()

        // 有人把云端换成旧文件（修订号照样往上涨，但索引的 updated 是旧的）
        let name = SyncEngine.fileName(vaultId: v.vaultId)
        await server.replace(name, data: old, rev: 9)
        let r = try await a.sync()
        XCTAssertEqual(r.failures[name], .rollback)
        XCTAssertEqual(titles(a), ["GitHub"])           // 本机没被换掉
    }

    func testTamperedRemoteIsRejected() async throws {
        let server = FakeServer()
        var a = try Device(server: server, accountId: testAccount.accountId)
        var b = try Device(server: server, accountId: testAccount.accountId)
        var v = try newVault()
        try a.repo.save(&v, now: t0)
        _ = try await a.sync()
        let name = SyncEngine.fileName(vaultId: v.vaultId)
        let other = try newVault()                       // 别的保险库的内容冒充这个文件名
        var o = other
        await server.replace(name, data: try o.serialized(now: t0), rev: 2)
        let r = try await b.sync()
        XCTAssertNotNil(r.failures[name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.repo.vaultURL(v.vaultId).path))
    }

    func testAccountFileReplacedAndProofRequired() async throws {
        let sk = SecretKey.generate()
        var account = try UnlockedAccount.create(password: "旧主密码", kdf: testKDF, secretKey: sk)
        let server = FakeServer()
        var a = try Device(server: server, accountId: account.accountId)
        var b = try Device(server: server, accountId: account.accountId)
        let original = try account.serialized()
        await server.replace(SyncEngine.accountFile, data: original, rev: 1)  // 注册时传的
        try VaultStore.write(original, to: a.repo.accountURL)
        try VaultStore.write(original, to: b.repo.accountURL)
        _ = try await a.sync(account)
        _ = try await b.sync(account)

        // a 改主密码：没给登录密钥就传不了
        try account.changePassword(to: "新主密码", kdf: testKDF)
        try a.repo.saveAccount(account)
        var r = try await a.sync(account)
        XCTAssertEqual(r.failures[SyncEngine.accountFile], .accountProofMissing)
        let key = try LoginKey.derive(password: "新主密码", kdf: account.kdf, secretKey: sk, accountId: account.accountId)
        r = try await a.sync(account, key: key)
        XCTAssertTrue(r.failures.isEmpty)

        r = try await b.sync(account)
        XCTAssertTrue(r.accountReplaced)
        XCTAssertNoThrow(try UnlockedAccount.open(try VaultStore.read(b.repo.accountURL), password: "新主密码", secretKey: sk))
    }

    func testSyncStateRoundTrip() throws {
        let d = try Device(server: FakeServer(), accountId: testAccount.accountId)
        var s = d.state
        s.cursor = "7"
        s.files["vaults/x.1melon"] = .init(rev: 3, sha256: "ab", updated: t0)
        try d.repo.writeSyncState(s)
        XCTAssertEqual(d.repo.readSyncState(), s)
        d.repo.removeSyncState()
        XCTAssertNil(d.repo.readSyncState())
    }
}

/// 冲突副本 id 的跨端向量（spec §7 `sync-merge/`，由 verify-vectors.py 的独立实现生成）
final class ConflictCopyVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct Case: Decodable { let name, vaultId, id, sealed, copyId: String; let rev: Int }
        let suffix: String
        let cases: [Case]
    }

    func testConflictCopyIds() throws {
        let url = SpecVectorTests.dir.appendingPathComponent("sync-merge/conflict-copy.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(v.suffix, VaultMerge.conflictSuffix)
        XCTAssertFalse(v.cases.isEmpty)
        for c in v.cases {
            var item = sampleLogin(t0)
            item.id = c.id
            item.rev = c.rev
            let copy = VaultMerge.conflictCopy(of: item, sealed: Data(base64Encoded: c.sealed)!, vaultId: c.vaultId)
            XCTAssertEqual(copy.id, c.copyId, c.name)
            XCTAssertEqual(copy.rev, 1)
            XCTAssertEqual(copy.title, item.title + v.suffix)
        }
    }
}

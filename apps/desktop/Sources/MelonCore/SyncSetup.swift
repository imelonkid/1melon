import Foundation

/// 开启同步的两条路（sync-api §4.1、§7）：
/// - `register`：这台设备上已有的账户凭邀请码注册到服务端；
/// - `join`：新设备凭服务端地址、`accountId`、Secret Key 和主密码加入已有账户，下载账户文件和全部保险库。
public enum SyncSetup {
    public enum SetupError: Error, Equatable {
        /// 账户没启用 Secret Key（文件 v1），不能同步（sync-api §1）
        case secretKeyRequired
        /// 这台设备已经开了同步
        case alreadySyncing
        /// 这台设备上已经有账户：加入前要先移走
        case localAccountExists
        /// 服务端给的账户文件不属于这个账户，或者和登录挑战里的参数对不上
        case accountMismatch
        /// 这台设备没开同步
        case notSyncing
        /// 开着同步改主密码，新账户文件没能传上服务端：本机已恢复成原来的主密码
        case passwordChangeNotUploaded
        /// 改主密码的同时，别的设备也改了主密码并先传上去了：本机已换成那份，要用那边的新主密码解锁
        case accountChangedElsewhere
    }

    /// 注册：把本机的账户文件原样上传，成为服务端上这个账户的第一个文件（rev 1），写好 `device/sync.json`。
    /// 之后跑一轮同步就会把保险库都传上去。
    /// `loginKey` 必须和本机账户文件对应（解锁时用 `UnlockedAccount.openWithLoginKey` 得到）
    @discardableResult
    public static func register(server: URL, inviteCode: String, repository: AccountRepository, loginKey: LoginKey,
                                http: HTTPClient = URLSessionHTTPClient()) async throws -> SyncState {
        guard repository.readSyncState() == nil else { throw SetupError.alreadySyncing }
        let data = try VaultStore.read(repository.accountURL)
        let file = try UnlockedAccount.decodeFile(data)
        guard file.requiresSecretKey else { throw SetupError.secretKeyRequired }
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        try await SyncAPI.register(server: server, inviteCode: code, accountId: file.accountId,
                                   authPublicKey: loginKey.publicKey, accountFile: data, http: http)
        var state = SyncState(server: try canonicalServer(server), accountId: file.accountId)
        state.files[SyncEngine.accountFile] = .init(rev: 1, sha256: SyncEngine.sha256(data))
        try repository.writeSyncState(state)
        return state
    }

    public struct Joined: Sendable {
        public var loaded: LoadedAccount
        public var client: SyncClient
        public var loginKey: LoginKey
        public var result: SyncResult
    }

    /// 加入已有账户（新设备，本机还没有账户）：
    /// 登录挑战拿 KDF 参数 → 只跑一次 Argon2id 同时得到登录密钥和 KEK → 登录、下载账户文件并用主密码打开 →
    /// 存 Secret Key 和同步状态 → 最后写账户文件 → 同步一轮下载保险库。
    /// 主密码或 Secret Key 不对（或者没有这个账户）都是 `SyncAPIError.unauthorized`，服务端不区分。
    public static func join(server: URL, accountId: String, secretKey: SecretKey, password: String,
                            repository: AccountRepository, deviceName: String,
                            http: HTTPClient = URLSessionHTTPClient(), now: Int64) async throws -> Joined {
        guard !repository.exists else { throw SetupError.localAccountExists }
        let id = accountId.lowercased()
        let challenge = try await SyncAPI.challenge(server: server, accountId: id, http: http)
        let argon = try UnlockedAccount.deriveKEK(password: password, kdf: challenge.kdf)
        let loginKey = LoginKey.derive(argon2Output: argon, secretKey: secretKey, accountId: id)

        var state = SyncState(server: try canonicalServer(server), accountId: id)
        let client = try SyncClient(server: server, accountId: id, deviceId: state.deviceId, deviceName: deviceName,
                                    loginKey: loginKey, http: http)
        let (data, rev) = try await client.download(SyncEngine.accountFile)
        let file: AccountFile
        do { file = try UnlockedAccount.decodeFile(data) } catch { throw SetupError.accountMismatch }
        // 能登录说明公钥对得上；账户文件却换了参数（刚好有别的设备改了主密码）就让用户重试
        guard file.accountId == id, file.kdf == challenge.kdf,
              let sk = try UnlockedAccount.checkSecretKey(file, secretKey) else { throw SetupError.accountMismatch }
        let account = try UnlockedAccount.open(file, kek: sk.deriveKEK(argon2Output: argon, accountId: id), secretKey: sk)

        try FileManager.default.createDirectory(at: repository.vaultsDirectory, withIntermediateDirectories: true)
        try repository.writeSecretKey(sk, accountId: id)
        state.files[SyncEngine.accountFile] = .init(rev: rev, sha256: SyncEngine.sha256(data))
        try repository.writeSyncState(state)
        // 账户文件最后写：有了它才算「这台设备上有账户」
        try VaultStore.write(data, to: repository.accountURL)

        let result = try await SyncEngine(repository: repository, transport: client).sync(account: account, state: &state, now: now)
        try repository.writeSyncState(state)
        return Joined(loaded: repository.loadVaults(account), client: client, loginKey: loginKey, result: result)
    }

    /// 开着同步时改主密码（sync-api §3.1、§5.3）：新账户文件必须马上传上去，服务端才会换成新的登录公钥；
    /// 否则下次用新主密码就登录不了。所以先写本机、马上同步一轮，传不上就把本机账户文件恢复成原样再报错。
    /// `client` 用旧登录密钥登录（服务端这时还只认旧公钥），新公钥随账户文件一起上传。
    public static func changePassword(account: UnlockedAccount, to password: String, kdf: KDFParameters = .defaults(),
                                      repository: AccountRepository, client: SyncTransport,
                                      now: Int64) async throws -> (UnlockedAccount, LoginKey) {
        guard let sk = account.secretKey else { throw SetupError.secretKeyRequired }
        let old = try VaultStore.read(repository.accountURL)
        var updated = account
        try updated.changePassword(to: password, kdf: kdf)
        let newKey = try LoginKey.derive(password: password, kdf: updated.kdf, secretKey: sk, accountId: account.accountId)
        let new = try updated.serialized()
        try VaultStore.write(new, to: repository.accountURL)

        let result: SyncResult
        do {
            result = try await SyncEngine(repository: repository, transport: client)
                .syncAndSave(account: updated, accountUploadKey: newKey, now: now)
        } catch {
            try restore(old, over: new, repository: repository)
            throw error
        }
        if result.localAccountChangeDiscarded || result.accountReplaced { throw SetupError.accountChangedElsewhere }
        guard result.failures[SyncEngine.accountFile] == nil,
              repository.readSyncState()?.files[SyncEngine.accountFile]?.sha256 == SyncEngine.sha256(new) else {
            try restore(old, over: new, repository: repository)
            throw SetupError.passwordChangeNotUploaded
        }
        return (updated, newKey)
    }

    /// 本机账户文件还是刚写的那份才恢复（期间被同步换掉了就不动）
    private static func restore(_ old: Data, over new: Data, repository: AccountRepository) throws {
        guard (try? VaultStore.read(repository.accountURL)) == new else { return }
        try VaultStore.write(old, to: repository.accountURL)
    }

    /// 关掉这台设备的同步：只删本机的同步状态，服务端和本机的文件都不动
    public static func disconnect(repository: AccountRepository) {
        repository.removeSyncState()
    }

    /// 同步状态里存的服务端地址：先过 https 检查，去掉结尾的 `/`
    static func canonicalServer(_ server: URL) throws -> String {
        _ = try SyncAPI.baseURL(server: server)
        var s = server.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

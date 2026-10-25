import CArgon2

/// Argon2id v1.3（RFC 9106），封装官方参考实现。
public enum Argon2id {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let code: Int32
        public var description: String { String(cString: argon2_error_message(code)) }
    }

    /// 派生 `length` 字节的密钥。`secret` 和 `associatedData` 只给 RFC 测试向量用，保险库不用。
    public static func hash(
        password: [UInt8],
        salt: [UInt8],
        memoryKiB: UInt32,
        iterations: UInt32,
        parallelism: UInt32,
        length: Int = 32,
        secret: [UInt8] = [],
        associatedData: [UInt8] = []
    ) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        var pwd = password, slt = salt, sec = secret, ad = associatedData
        defer {
            // 密码副本用完清零
            for i in pwd.indices { pwd[i] = 0 }
        }
        let rc: Int32 = out.withUnsafeMutableBufferPointer { o in
            pwd.withUnsafeMutableBufferPointer { p in
                slt.withUnsafeMutableBufferPointer { s in
                    sec.withUnsafeMutableBufferPointer { k in
                        ad.withUnsafeMutableBufferPointer { a in
                            var ctx = Argon2_Context(
                                out: o.baseAddress, outlen: UInt32(o.count),
                                pwd: p.baseAddress, pwdlen: UInt32(p.count),
                                salt: s.baseAddress, saltlen: UInt32(s.count),
                                secret: k.count > 0 ? k.baseAddress : nil, secretlen: UInt32(k.count),
                                ad: a.count > 0 ? a.baseAddress : nil, adlen: UInt32(a.count),
                                t_cost: iterations, m_cost: memoryKiB,
                                lanes: parallelism, threads: parallelism,
                                version: UInt32(ARGON2_VERSION_13.rawValue),
                                allocate_cbk: nil, free_cbk: nil,
                                flags: 0 // ARGON2_DEFAULT_FLAGS（宏带 UINT32_C，Swift 导入不了）
                            )
                            return argon2_ctx(&ctx, Argon2_id)
                        }
                    }
                }
            }
        }
        guard rc == ARGON2_OK.rawValue else {
            for i in out.indices { out[i] = 0 }
            throw Failure(code: rc)
        }
        return out
    }
}

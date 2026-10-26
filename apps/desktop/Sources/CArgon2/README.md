# CArgon2

Argon2 官方参考实现（Password Hashing Competition），原样拷贝，**不要改动**。

- 来源：https://github.com/P-H-C/phc-winner-argon2
- 版本：tag `20190702`（commit `62358ba2123abd17fccf2a108a301d4b52c01a7c`）
- 许可：CC0 1.0 或 Apache 2.0 二选一（见 `LICENSE`）
- 只取了参考实现需要的文件：`argon2.c core.c encoding.c ref.c thread.c`、`blake2/`、`include/argon2.h`。没有拷 `opt.c`（x86 SSE 优化）、测试和基准程序。
- 编译时定义 `ARGON2_NO_THREADS`：保险库的 parallelism 固定为 1，用不到线程。

正确性由 `Tests/MelonCoreTests/Argon2Tests.swift` 里 RFC 9106 §5.3 的 Argon2id 测试向量保证。升级版本时整个目录替换，并更新本文的 commit。

为鸿蒙端预留：同一份 C 源码可以用 NDK 编译成 native 模块，两端用的是同一个实现。

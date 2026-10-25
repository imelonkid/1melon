#!/usr/bin/env python3
# spec 的第二个参考实现：只按 spec/vault-format.md 写，不依赖任何客户端代码。
# 用来证明 spec 足够让另一种语言独立实现（鸿蒙端照着做），也用来交叉验证桌面端生成的测试向量。
#
#   python3 spec/tools/verify-vectors.py            # 需要 cryptography >= 44（带 Argon2id）
#
# 只校验正常路径（解开 vault-v1.1melon、kdf.json）；篡改用例由各端自己的测试覆盖。
import base64, json, sys, unicodedata
from cryptography.hazmat.primitives.kdf.argon2 import Argon2id
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

import os
d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test-vectors")
f = json.load(open(f"{d}/vault-v1.1melon")); exp = json.load(open(f"{d}/vault-v1.json"))
b = lambda s: base64.b64decode(s)
k = f["kdf"]; vid = f["vaultId"]
pw = unicodedata.normalize("NFC", exp["password"]).encode()
kek = Argon2id(salt=b(k["salt"]), length=32, iterations=k["iterations"], lanes=k["parallelism"], memory_cost=k["memKiB"]).derive(pw)
op = lambda key, s, aad: AESGCM(key).decrypt(b(s["nonce"]), b(s["ct"]), aad.encode())
vk = op(kek, f["wrappedKey"], f"1melon:v1:key:{vid}")
index = json.loads(op(vk, f["index"], f"1melon:v1:index:{vid}"))
meta = json.loads(op(vk, f["meta"], f"1melon:v1:meta:{vid}"))
assert meta == exp["meta"], meta
assert index["items"] == {i["id"]: i["rev"] for i in f["items"]} and len(index["items"]) == len(f["items"])
items = []
for i in f["items"]:
    p = json.loads(op(vk, i, f"1melon:v1:item:{vid}:{i['id']}:{i['rev']}")); p["id"] = i["id"]; p["rev"] = i["rev"]
    items.append(p)
assert items == exp["items"], "条目明文不一致"
print(f"✓ 独立实现解开 vault-v1.1melon：{len(items)} 个条目（含 {sum(i['deleted'] for i in items)} 个墓碑），元数据「{meta['name']}」与期望一致")
kv = json.load(open(f"{d}/kdf.json"))
for c in kv["cases"]:
    got = Argon2id(salt=b(c["salt"]), length=32, iterations=c["iterations"], lanes=c["parallelism"], memory_cost=c["memKiB"]).derive(unicodedata.normalize("NFC", c["password"]).encode()).hex()
    assert got == c["kek"], c["name"]
print(f"✓ kdf.json {len(kv['cases'])} 个用例一致")

#!/usr/bin/env python3
# spec 的第二个参考实现：只按 spec/vault-format.md 写，不依赖任何客户端代码。
# 用来证明 spec 足够让另一种语言独立实现（鸿蒙端照着做），也用来交叉验证桌面端生成的测试向量。
#
#   python3 spec/tools/verify-vectors.py            # 需要 cryptography >= 44（带 Argon2id）
#
# 校验正常路径（kdf.json、example/ 的账户和全部保险库）和篡改用例（tamper/cases.json：每个都必须打不开）。
import base64, glob, json, os, sys, unicodedata, uuid
from cryptography.hazmat.primitives.kdf.argon2 import Argon2id
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test-vectors")
b = lambda s: base64.b64decode(s)


class Rejected(Exception):
    def __init__(self, kind):
        self.kind = kind


def kek_of(kdf, password):
    k = kdf
    if k["alg"] != "argon2id13" or k["parallelism"] != 1 or len(b(k["salt"])) != 16:
        raise Rejected("unsafeKDFParameters")
    if not (65536 <= k["memKiB"] <= 1048576) or not (2 <= k["iterations"] <= 10):
        raise Rejected("unsafeKDFParameters")
    pw = unicodedata.normalize("NFC", password).encode()
    return Argon2id(salt=b(k["salt"]), length=32, iterations=k["iterations"], lanes=1, memory_cost=k["memKiB"]).derive(pw)


def unseal(key, s, aad):
    if len(b(s["nonce"])) != 12 or len(b(s["ct"])) < 16:
        raise Rejected("tampered")
    return AESGCM(key).decrypt(b(s["nonce"]), b(s["ct"]), aad.encode())


def is_uuid(s):
    try:
        return str(uuid.UUID(s)) == s
    except ValueError:
        return False


def open_account(f, password):
    """spec §4「打开时的检查顺序」：账户文件 → 账户密钥 AK"""
    if f.get("format") != "1melon-account":
        raise Rejected("invalidFormat")
    if f["version"] > 1:
        raise Rejected("unsupportedVersion")
    if not is_uuid(f["accountId"]) or f["secretKey"] != "none":
        raise Rejected("invalidFormat")
    kek = kek_of(f["kdf"], password)
    try:
        return unseal(kek, f["wrappedKey"], f"1melon:v1:account:{f['accountId']}")
    except Exception:
        raise Rejected("wrongPassword")


def open_vault(f, account_id, ak):
    """账户密钥 AK → 保险库密钥 VK → 索引、元数据、条目"""
    if f.get("format") != "1melon-vault":
        raise Rejected("invalidFormat")
    if f["version"] > 1:
        raise Rejected("unsupportedVersion")
    vid = f["vaultId"]
    if not is_uuid(vid) or not is_uuid(f["accountId"]) or f["accountId"] != account_id:
        raise Rejected("invalidFormat")
    try:
        vk = unseal(ak, f["wrappedKey"], f"1melon:v1:key:{account_id}:{vid}")
        index = json.loads(unseal(vk, f["index"], f"1melon:v1:index:{vid}"))
        meta = json.loads(unseal(vk, f["meta"], f"1melon:v1:meta:{vid}"))
        if len(index["items"]) != len(f["items"]) or len({i["id"] for i in f["items"]}) != len(f["items"]):
            raise Rejected("tampered")
        items = []
        for i in f["items"]:
            if not is_uuid(i["id"]) or i["rev"] < 1 or index["items"].get(i["id"]) != i["rev"]:
                raise Rejected("tampered")
            p = json.loads(unseal(vk, i, f"1melon:v1:item:{vid}:{i['id']}:{i['rev']}"))
            p["id"], p["rev"] = i["id"], i["rev"]
            items.append(p)
    except Rejected:
        raise
    except Exception:
        raise Rejected("tampered")
    return meta, items


load = lambda p: json.load(open(p))

# kdf.json
kv = load(f"{d}/kdf.json")
for c in kv["cases"]:
    kdf = {k: c[k] for k in ("salt", "memKiB", "iterations", "parallelism")} | {"alg": "argon2id13"}
    assert kek_of(kdf, c["password"]).hex() == c["kek"], c["name"]
print(f"✓ kdf.json {len(kv['cases'])} 个用例一致")

# example/
exp = load(f"{d}/example/expected.json")
account = load(f"{d}/example/account.1melon")
ak = open_account(account, exp["password"])
assert account["accountId"] == exp["accountId"]
try:
    open_account(account, exp["wrongPassword"])
    raise AssertionError("错误密码居然打开了")
except Rejected as r:
    assert r.kind == "wrongPassword"
opened = []
for path in glob.glob(f"{d}/example/vaults/*.1melon"):
    meta, items = open_vault(load(path), account["accountId"], ak)
    opened.append({"file": os.path.basename(path), "vaultId": load(path)["vaultId"], "meta": meta, "items": items})
opened.sort(key=lambda v: (v["meta"]["order"], v["meta"]["created"]))
assert opened == exp["vaults"], "保险库明文与 expected.json 不一致"
n = sum(len(v["items"]) for v in opened)
print(f"✓ 独立实现解开 example/：{len(opened)} 个保险库（{'、'.join(v['meta']['name'] for v in opened)}），共 {n} 个条目，与期望一致")

# tamper/
cases = load(f"{d}/tamper/cases.json")
for c in cases:
    f = load(f"{d}/tamper/{c['file']}")
    try:
        if c["target"] == "account":
            open_account(f, exp["password"])
        else:
            open_vault(f, account["accountId"], ak)
        raise AssertionError(f"{c['file']} 居然打开了")
    except Rejected as r:
        assert r.kind == c["expect"], f"{c['file']}：期望 {c['expect']}，实际 {r.kind}"
print(f"✓ tamper/ {len(cases)} 个篡改用例都被拒绝，错误种类与期望一致")

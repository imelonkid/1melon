#!/usr/bin/env python3
# spec 的第二个参考实现：只按 spec/vault-format.md 写，不依赖任何客户端代码。
# 用来证明 spec 足够让另一种语言独立实现（鸿蒙端照着做），也用来交叉验证桌面端生成的测试向量。
#
#   python3 spec/tools/verify-vectors.py            # 需要 cryptography >= 44（带 Argon2id）
#
# 校验正常路径（kdf.json、example/ 的账户和全部保险库）、篡改用例（tamper/cases.json：每个都必须打不开），
# Secret Key（secret-key/：写法、KEK、v2 账户文件和它的篡改用例），同步登录密钥（sync-auth/，spec/sync-api.md §3），冲突副本 id（sync-merge/，§8），以及设置码（sync-setup/，sync-api.md §7）。
import base64, glob, hashlib, hmac, json, os, sys, unicodedata, urllib.parse, uuid
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.argon2 import Argon2id
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.exceptions import InvalidSignature

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


CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def secret_key_checksum(raw):
    bits = int.from_bytes(hashlib.sha256(raw).digest()[:2], "big") >> 6  # 前 10 比特
    return CROCKFORD[bits >> 5] + CROCKFORD[bits & 31]


def secret_key_text(raw):
    """spec §3.4：16 字节前补 2 个 0 比特 → 26 个字符 + 2 个校验字符，M1- 开头，每 7 个一组"""
    n = int.from_bytes(raw, "big")
    body = "".join(CROCKFORD[(n >> (5 * i)) & 31] for i in reversed(range(26))) + secret_key_checksum(raw)
    return "M1-" + "-".join(body[i:i + 7] for i in range(0, 28, 7))


def parse_secret_key(text):
    s = "".join(c for c in text.upper() if not c.isspace() and c != "-")
    if len(s) == 30 and s.startswith("M1"):
        s = s[2:]
    if len(s) != 28:
        raise ValueError("长度不对")
    s = s.replace("O", "0").replace("I", "1").replace("L", "1")
    if any(c not in CROCKFORD for c in s) or CROCKFORD.index(s[0]) >= 8:
        raise ValueError("字符不对")
    n = 0
    for c in s[:26]:
        n = n * 32 + CROCKFORD.index(c)
    raw = n.to_bytes(16, "big")
    if s[26:] != secret_key_checksum(raw):
        raise ValueError("校验不对")
    return raw


def secret_key_id(sk, account_id):
    return hmac.new(sk, f"1melon:v2:secret-key-id:{account_id}".encode(), hashlib.sha256).digest()[:8]


def kek_v2(argon, sk, account_id):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=sk, info=f"1melon:v2:kek:{account_id}".encode()).derive(argon)


def unseal(key, s, aad):
    if len(b(s["nonce"])) != 12 or len(b(s["ct"])) < 16:
        raise Rejected("tampered")
    return AESGCM(key).decrypt(b(s["nonce"]), b(s["ct"]), aad.encode())


def is_uuid(s):
    try:
        return str(uuid.UUID(s)) == s
    except ValueError:
        return False


def open_account(f, password, secret_key=None):
    """spec §4「打开时的检查顺序」：账户文件 → 账户密钥 AK。v2 要 Secret Key（16 字节）"""
    if f.get("format") != "1melon-account":
        raise Rejected("invalidFormat")
    if f["version"] > 2:
        raise Rejected("unsupportedVersion")
    if f["version"] < 1 or not is_uuid(f["accountId"]):
        raise Rejected("invalidFormat")
    aid = f["accountId"]
    if f["version"] == 2:
        if f["secretKey"] != "required" or "secretKeyId" not in f or len(b(f["secretKeyId"])) != 8:
            raise Rejected("invalidFormat")
    elif f["secretKey"] != "none" or "secretKeyId" in f:
        raise Rejected("invalidFormat")
    if f["version"] == 2:
        if secret_key is None:
            raise Rejected("secretKeyRequired")
        if not hmac.compare_digest(secret_key_id(secret_key, aid), b(f["secretKeyId"])):
            raise Rejected("wrongSecretKey")
        kek, aad = kek_v2(kek_of(f["kdf"], password), secret_key, aid), f"1melon:v2:account:{aid}"
    else:
        kek, aad = kek_of(f["kdf"], password), f"1melon:v1:account:{aid}"
    try:
        return unseal(kek, f["wrappedKey"], aad)
    except Exception:
        raise Rejected("wrongPassword")


def open_vault(f, account_id, ak):
    """账户密钥 AK → 保险库密钥 VK → 索引、元数据、条目"""
    if f.get("format") != "1melon-vault":
        raise Rejected("invalidFormat")
    # 版本 2 只比 1 多了字段类型 file（spec §3.2，内容在单独的附件文件里），两个都能读
    if f["version"] > 2:
        raise Rejected("unsupportedVersion")
    if f["version"] < 1:
        raise Rejected("invalidFormat")
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


def open_attachment(f, account_id, ref):
    """spec §3.5、§4「每个附件文件」：用字段里的引用（id、FK、size）解开附件"""
    if f.get("format") != "1melon-attachment":
        raise Rejected("invalidFormat")
    if f["version"] > 1:
        raise Rejected("unsupportedVersion")
    if f["version"] < 1 or not is_uuid(f["attachmentId"]) or not is_uuid(f["accountId"]) or f["accountId"] != account_id:
        raise Rejected("invalidFormat")
    if f["attachmentId"] != ref["id"] or len(b(ref["key"])) != 32:
        raise Rejected("tampered")
    try:
        plain = unseal(b(ref["key"]), f["content"], f"1melon:v1:attachment:{account_id}:{ref['id']}")
    except Exception:
        raise Rejected("tampered")
    if len(plain) != ref["size"]:
        raise Rejected("tampered")
    return plain


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
# 文件附件（spec §3.5、§5.4）：字段里只有引用，value 为空；每个引用的附件文件都能用引用里的密钥解开
files = [f for v in opened for it in v["items"] for sec in it.get("sections", []) for f in sec["fields"] if f["kind"] == "file"]
assert files, "example/ 里应该有文件附件"
refs = {f["attachment"]["id"]: f["attachment"] for f in files if "attachment" in f}
on_disk = {os.path.basename(p)[:-len(".1melon")] for p in glob.glob(f"{d}/example/attachments/*.1melon")}
assert set(refs) == on_disk == {a["ref"]["id"] for a in exp["attachments"]}, "附件文件和引用对不上"
for f in files:
    assert f["value"] == "" and "/" not in f.get("fileName", "")
for a in exp["attachments"]:
    plain = open_attachment(load(f"{d}/example/attachments/{a['file']}"), account["accountId"], refs[a["ref"]["id"]])
    assert plain == b(a["plaintext"]) and len(plain) <= 5242880 and a["ref"] == refs[a["ref"]["id"]]
assert all(load(p)["version"] == 2 for p in glob.glob(f"{d}/example/vaults/*.1melon")), "新写出的保险库应是版本 2"
n = sum(len(v["items"]) for v in opened)
print(f"✓ 独立实现解开 example/：{len(opened)} 个保险库（{'、'.join(v['meta']['name'] for v in opened)}），共 {n} 个条目、{len(refs)} 个附件，与期望一致")

# tamper/
cases = load(f"{d}/tamper/cases.json")
for c in cases:
    f = load(f"{d}/tamper/{c['file']}")
    try:
        if c["target"] == "account":
            open_account(f, exp["password"])
        elif c["target"] == "attachment":
            open_attachment(f, account["accountId"], refs[c["attachmentId"]])
        else:
            open_vault(f, account["accountId"], ak)
        raise AssertionError(f"{c['file']} 居然打开了")
    except Rejected as r:
        assert r.kind == c["expect"], f"{c['file']}：期望 {c['expect']}，实际 {r.kind}"
print(f"✓ tamper/ {len(cases)} 个篡改用例都被拒绝，错误种类与期望一致")

# secret-key/
sd = f"{d}/secret-key"
skv = load(f"{sd}/kdf.json")
for c in skv["cases"]:
    kdf = {k: c[k] for k in ("salt", "memKiB", "iterations", "parallelism")} | {"alg": "argon2id13"}
    sk = parse_secret_key(c["secretKey"])
    assert sk == b(c["secretKeyBytes"]) and secret_key_text(sk) == c["secretKey"], c["name"]
    argon = kek_of(kdf, c["password"])
    assert argon.hex() == c["argon2"], c["name"]
    assert kek_v2(argon, sk, c["accountId"]).hex() == c["kek"], c["name"]
    assert secret_key_id(sk, c["accountId"]) == b(c["secretKeyId"]), c["name"]
tv = load(f"{sd}/text.json")
for c in tv["valid"]:
    raw = parse_secret_key(c["input"])
    assert raw == b(c["bytes"]) and secret_key_text(raw) == c["canonical"], c["input"]
for c in tv["invalid"]:
    try:
        parse_secret_key(c["input"])
        raise AssertionError(f"不合法的写法居然解析成功：{c['why']}")
    except ValueError:
        pass
se = load(f"{sd}/expected.json")
sacc = load(f"{sd}/account.1melon")
sk = parse_secret_key(se["secretKey"])
assert open_account(sacc, se["password"], sk).hex() == se["accountKey"]
for args, kind in [((se["password"], None), "secretKeyRequired"),
                   ((se["password"], parse_secret_key(se["wrongSecretKey"])), "wrongSecretKey"),
                   ((se["wrongPassword"], sk), "wrongPassword")]:
    try:
        open_account(sacc, *args)
        raise AssertionError(f"期望 {kind}，居然打开了")
    except Rejected as r:
        assert r.kind == kind, f"期望 {kind}，实际 {r.kind}"
scases = load(f"{sd}/tamper/cases.json")
for c in scases:
    try:
        open_account(load(f"{sd}/tamper/{c['file']}"), se["password"], sk)
        raise AssertionError(f"{c['file']} 居然打开了")
    except Rejected as r:
        assert r.kind == c["expect"], f"{c['file']}：期望 {c['expect']}，实际 {r.kind}"
print(f"✓ secret-key/ KEK {len(skv['cases'])} 个、写法 {len(tv['valid'])}+{len(tv['invalid'])} 个、v2 账户和 {len(scases)} 个篡改用例都一致")

# sync-auth/（spec/sync-api.md §3.1）
av = load(f"{d}/sync-auth/auth.json")


def ed_verify(pub, msg, sig):
    try:
        Ed25519PublicKey.from_public_bytes(pub).verify(sig, msg)
        return True
    except InvalidSignature:
        return False


for c in av["cases"]:
    kdf = {k: c[k] for k in ("salt", "memKiB", "iterations", "parallelism")} | {"alg": "argon2id13"}
    sk = parse_secret_key(c["secretKey"])
    argon = kek_of(kdf, c["password"])
    assert argon.hex() == c["argon2"], c["name"]
    seed = HKDF(algorithm=hashes.SHA256(), length=32, salt=sk, info=f"1melon:v2:auth:{c['accountId']}".encode()).derive(argon)
    assert seed.hex() == c["authSeed"], c["name"]
    assert kek_v2(argon, sk, c["accountId"]).hex() == c["kek"] != c["authSeed"], c["name"]
    priv = Ed25519PrivateKey.from_private_bytes(seed)
    pub = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    assert pub == b(c["publicKey"]), c["name"]
    msg = f"1melon:v1:auth:{c['accountId']}:{av['login']['challenge']}".encode()
    assert ed_verify(pub, msg, priv.sign(msg)), c["name"]
lg = av["login"]
assert lg["message"] == f"1melon:v1:auth:{lg['accountId']}:{lg['challenge']}"
assert ed_verify(b(lg["publicKey"]), lg["message"].encode(), b(lg["signature"])), "login 签名验不过"
rt = av["rotate"]
f = b(rt["accountFile"])
assert hashlib.sha256(f).hexdigest() == rt["sha256"] and json.loads(f)["accountId"] == rt["accountId"]
assert rt["message"] == f"1melon:v1:rotate:{rt['accountId']}:{rt['sha256']}"
assert ed_verify(b(rt["publicKey"]), rt["message"].encode(), b(rt["signature"])), "rotate 签名验不过"
for c in av["invalid"]:
    assert not ed_verify(b(c["publicKey"]), c["message"].encode(), b(c["signature"])), f"居然验过了：{c['what']}"
print(f"✓ sync-auth/ 登录密钥 {len(av['cases'])} 个、登录和换钥签名、{len(av['invalid'])} 个反例都一致")

# sync-merge/（§8 冲突副本 id）
mv = load(f"{d}/sync-merge/conflict-copy.json")
for c in mv["cases"]:
    h = bytearray(hashlib.sha256(f"1melon:v1:conflict:{c['vaultId']}:{c['id']}:{c['rev']}:".encode() + b(c["sealed"])).digest()[:16])
    h[6] = (h[6] & 0x0F) | 0x40
    h[8] = (h[8] & 0x3F) | 0x80
    assert str(uuid.UUID(bytes=bytes(h))) == c["copyId"] and is_uuid(c["copyId"]), c["name"]
print(f"✓ sync-merge/ 冲突副本 id {len(mv['cases'])} 个一致")

# sync-setup/（spec/sync-api.md §7 设置码）
SETUP_PREFIX = "1MELON-SETUP1:"


def setup_code_encode(server, account_id, secret_key):
    body = json.dumps({"accountId": account_id, "secretKey": secret_key, "server": server.rstrip("/")},
                      sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return SETUP_PREFIX + base64.urlsafe_b64encode(body.encode()).decode().rstrip("=")


def setup_code_decode(text):
    s = "".join(c for c in text if not c.isspace())
    if not s.startswith(SETUP_PREFIX):
        raise ValueError("前缀不对")
    payload = s[len(SETUP_PREFIX):]
    stripped = payload.rstrip("=")
    if not stripped or len(payload) - len(stripped) > 2 or any(c not in
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" for c in stripped):
        raise ValueError("不是 Base64url")
    try:
        obj = json.loads(base64.urlsafe_b64decode(stripped + "=" * (-len(stripped) % 4)).decode())
    except Exception:
        raise ValueError("不是 JSON")
    if not isinstance(obj, dict) or not all(isinstance(obj.get(k), str) for k in ("server", "accountId", "secretKey")):
        raise ValueError("缺键")
    server = obj["server"]
    if "?" in server or "#" in server:
        raise ValueError("地址带查询或片段")
    u = urllib.parse.urlsplit(server)
    if u.scheme != "https" or not u.hostname or u.username is not None or u.password is not None:
        raise ValueError("地址不对")
    if not is_uuid(obj["accountId"]):
        raise ValueError("accountId 不对")
    return server.rstrip("/"), obj["accountId"], secret_key_text(parse_secret_key(obj["secretKey"]))


sv = load(f"{d}/sync-setup/setup-code.json")
for c in sv["valid"]:
    assert setup_code_encode(c["server"], c["accountId"], c["secretKey"]) == c["code"], c["name"]
    assert setup_code_decode(c["code"]) == (c["server"], c["accountId"], c["secretKey"]), c["name"]
for c in sv["parse"]:
    assert setup_code_decode(c["input"]) == (c["server"], c["accountId"], c["secretKey"]), c["name"]
for c in sv["invalid"]:
    try:
        setup_code_decode(c["input"])
        raise AssertionError(f"不合法的设置码居然解析成功：{c['why']}")
    except ValueError:
        pass
print(f"✓ sync-setup/ 设置码 {len(sv['valid'])} 个生成、{len(sv['parse'])} 个变体解析、{len(sv['invalid'])} 个反例都一致")

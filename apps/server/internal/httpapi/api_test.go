package httpapi

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/imelonkid/1melon/apps/server/internal/auth"
	"github.com/imelonkid/1melon/apps/server/internal/store"
)

// 全流程：邀请注册 → 挑战签名登录 → 上传 / 冲突 / 增量列表 / 下载 / 删除 → 换登录密钥 → 停用。数据全部虚构。

const (
	accountID = "11111111-2222-4333-8444-555555555555"
	vaultID   = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	deviceID  = "99999999-8888-4777-8666-555555555555"
)

type harness struct {
	t     *testing.T
	srv   *httptest.Server
	db    *store.Store
	key   ed25519.PrivateKey
	token string
}

func newHarness(t *testing.T, limits store.Limits) *harness {
	t.Helper()
	db, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	api := &Server{Version: "test", DB: db, Store: db, Limits: limits, Log: slog.New(slog.NewJSONHandler(io.Discard, nil))}
	srv := httptest.NewServer(api.Handler())
	t.Cleanup(srv.Close)
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	return &harness{t: t, srv: srv, db: db, key: key}
}

func accountFile(salt string) []byte {
	return []byte(fmt.Sprintf(`{"format":"1melon-account","version":2,"accountId":%q,"kdf":{"alg":"argon2id13","memKiB":262144,"iterations":3,"parallelism":1,"salt":%q},"secretKey":"required","secretKeyId":"AAAAAAAAAAA=","wrappedKey":{"nonce":"x","ct":"y"}}`, accountID, salt))
}

func vaultFile(n int) []byte {
	return []byte(fmt.Sprintf(`{"format":"1melon-vault","version":1,"vaultId":%q,"accountId":%q,"items":[],"n":%d}`, vaultID, accountID, n))
}

func (h *harness) do(method, path string, body []byte, headers map[string]string) (int, http.Header, []byte) {
	h.t.Helper()
	req, _ := http.NewRequest(method, h.srv.URL+path, bytes.NewReader(body))
	if h.token != "" {
		req.Header.Set("Authorization", "Bearer "+h.token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, out
}

func (h *harness) json(method, path string, v any) (int, map[string]any) {
	h.t.Helper()
	b, _ := json.Marshal(v)
	code, _, out := h.do(method, path, b, map[string]string{"Content-Type": "application/json"})
	var m map[string]any
	_ = json.Unmarshal(out, &m)
	return code, m
}

func errCode(m map[string]any) string {
	e, _ := m["error"].(map[string]any)
	s, _ := e["code"].(string)
	return s
}

func (h *harness) register(invite string) (int, map[string]any) {
	return h.json("POST", "/api/v1/accounts", map[string]any{
		"inviteCode": invite, "accountId": accountID,
		"authPublicKey": base64.StdEncoding.EncodeToString(h.key.Public().(ed25519.PublicKey)),
		"account":       base64.StdEncoding.EncodeToString(accountFile("c2FsdHNhbHRzYWx0c2FsdA==")),
	})
}

func (h *harness) login(key ed25519.PrivateKey) (int, map[string]any) {
	h.t.Helper()
	h.token = ""
	code, ch := h.json("POST", "/api/v1/auth/challenge", map[string]any{"accountId": accountID})
	if code != 200 {
		h.t.Fatalf("challenge %d %v", code, ch)
	}
	challenge := ch["challenge"].(string)
	code, m := h.json("POST", "/api/v1/auth/session", map[string]any{
		"accountId": accountID, "challenge": challenge,
		"signature": base64.StdEncoding.EncodeToString(ed25519.Sign(key, auth.LoginMessage(accountID, challenge))),
		"device":    map[string]any{"id": deviceID, "name": "测试 Mac", "platform": "macos"},
	})
	if code == 200 {
		h.token = m["token"].(string)
	}
	return code, m
}

func TestRegisterAndLogin(t *testing.T) {
	h := newHarness(t, store.Limits{})
	ctx := context.Background()
	if err := h.db.CreateInvite(ctx, "INVITE-1", "测试", time.Hour); err != nil {
		t.Fatal(err)
	}
	if code, m := h.register("WRONG"); code != 403 || errCode(m) != "forbidden" {
		t.Fatalf("错误邀请码 %d %v", code, m)
	}
	if code, _ := h.register("INVITE-1"); code != 201 {
		t.Fatalf("注册 %d", code)
	}
	if code, m := h.register("INVITE-1"); code != 409 && code != 403 {
		t.Fatalf("重复注册 %d %v", code, m)
	}

	// 挑战返回账户文件里的 kdf；不存在的账户也返回一套固定的假参数
	_, ch := h.json("POST", "/api/v1/auth/challenge", map[string]any{"accountId": accountID})
	if kdf := ch["kdf"].(map[string]any); kdf["salt"] != "c2FsdHNhbHRzYWx0c2FsdA==" {
		t.Fatalf("kdf %v", kdf)
	}
	other := "22222222-2222-4333-8444-555555555555"
	_, a := h.json("POST", "/api/v1/auth/challenge", map[string]any{"accountId": other})
	_, b := h.json("POST", "/api/v1/auth/challenge", map[string]any{"accountId": other})
	if a["kdf"].(map[string]any)["salt"] != b["kdf"].(map[string]any)["salt"] {
		t.Fatal("假 kdf 每次应一样，不然能看出账户不存在")
	}

	// 签名不对
	_, wrong, _ := ed25519.GenerateKey(rand.Reader)
	if code, m := h.login(wrong); code != 401 {
		t.Fatalf("错误密钥 %d %v", code, m)
	}
	if code, _ := h.login(h.key); code != 200 {
		t.Fatalf("登录 %d", code)
	}

	// 挑战只能用一次
	_, ch = h.json("POST", "/api/v1/auth/challenge", map[string]any{"accountId": accountID})
	sign := func() (int, map[string]any) {
		return h.json("POST", "/api/v1/auth/session", map[string]any{
			"accountId": accountID, "challenge": ch["challenge"],
			"signature": base64.StdEncoding.EncodeToString(ed25519.Sign(h.key, auth.LoginMessage(accountID, ch["challenge"].(string)))),
			"device":    map[string]any{"id": deviceID, "name": "测试 Mac", "platform": "macos"},
		})
	}
	if code, _ := sign(); code != 200 {
		t.Fatal("第一次应成功")
	}
	if code, _ := sign(); code != 401 {
		t.Fatal("同一个挑战第二次应拒绝")
	}

	// 设备列表
	code, m := h.json("GET", "/api/v1/devices", nil)
	devices := m["devices"].([]any)
	if code != 200 || len(devices) != 1 || devices[0].(map[string]any)["current"] != true {
		t.Fatalf("设备 %d %v", code, m)
	}
}

func TestFilesConflictsAndDeletion(t *testing.T) {
	h := newHarness(t, store.Limits{})
	_ = h.db.CreateInvite(context.Background(), "INVITE-1", "", time.Hour)
	h.register("INVITE-1")
	h.login(h.key)
	name := "/api/v1/files/vaults/" + vaultID + ".1melon"

	if code, _, _ := h.do("PUT", name, vaultFile(1), nil); code != 400 {
		t.Fatal("没带前提条件应 400")
	}
	if code, _, _ := h.do("PUT", name, vaultFile(1), map[string]string{"If-Match": `"1"`}); code != 412 {
		t.Fatal("不存在的文件用 If-Match 应 412")
	}
	code, hdr, _ := h.do("PUT", name, vaultFile(1), map[string]string{"If-None-Match": "*"})
	if code != 200 || hdr.Get("ETag") != `"1"` {
		t.Fatalf("新建 %d %s", code, hdr.Get("ETag"))
	}
	if code, _, _ := h.do("PUT", name, vaultFile(1), map[string]string{"If-None-Match": "*"}); code != 412 {
		t.Fatal("重复新建应 412")
	}
	if code, _, _ := h.do("PUT", name, vaultFile(2), map[string]string{"If-Match": `"1"`}); code != 200 {
		t.Fatal("更新应成功")
	}
	// 另一台设备还拿着 rev 1：谁先写谁赢
	code, _, body := h.do("PUT", name, vaultFile(3), map[string]string{"If-Match": `"1"`})
	var conflict map[string]any
	_ = json.Unmarshal(body, &conflict)
	if code != 412 || errCode(conflict) != "conflict" || conflict["rev"] != float64(2) {
		t.Fatalf("冲突 %d %v", code, conflict)
	}

	code, hdr, body = h.do("GET", name, nil, nil)
	if code != 200 || !bytes.Equal(body, vaultFile(2)) || hdr.Get("ETag") != `"2"` {
		t.Fatalf("下载 %d %s", code, body)
	}

	// 内容和文件名、账户对不上
	bad := bytes.ReplaceAll(vaultFile(4), []byte(vaultID), []byte("bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
	if code, _, _ := h.do("PUT", name, bad, map[string]string{"If-Match": `"2"`}); code != 400 {
		t.Fatal("vaultId 和文件名不一致应 400")
	}
	if code, _, _ := h.do("GET", "/api/v1/files/../etc/passwd", nil, nil); code != 400 && code != 404 {
		t.Fatalf("非法文件名 %d", code)
	}

	// 增量列表
	_, list := h.json("GET", "/api/v1/files", nil)
	cursor := list["cursor"].(string)
	if n := len(list["files"].([]any)); n != 2 {
		t.Fatalf("应有账户文件 + 保险库 %d", n)
	}
	_, list = h.json("GET", "/api/v1/files?since="+cursor, nil)
	if n := len(list["files"].([]any)); n != 0 {
		t.Fatalf("游标之后没有变化 %d", n)
	}

	// 删除留标记，增量列表能看到
	if code, _, _ := h.do("DELETE", name, nil, map[string]string{"If-Match": `"1"`}); code != 412 {
		t.Fatal("旧 rev 删除应 412")
	}
	if code, _, _ := h.do("DELETE", name, nil, map[string]string{"If-Match": `"2"`}); code != 200 {
		t.Fatal("删除")
	}
	_, list = h.json("GET", "/api/v1/files?since="+cursor, nil)
	files := list["files"].([]any)
	if len(files) != 1 || files[0].(map[string]any)["deleted"] != true || files[0].(map[string]any)["rev"] != float64(3) {
		t.Fatalf("删除标记 %v", files)
	}
	if code, _, _ := h.do("GET", name, nil, nil); code != 404 {
		t.Fatal("删除后下载应 404")
	}
	if code, _, _ := h.do("PUT", name, vaultFile(5), map[string]string{"If-None-Match": "*"}); code != 200 {
		t.Fatal("删除后可以重建")
	}
	if code, _, _ := h.do("DELETE", "/api/v1/files/account.1melon", nil, map[string]string{"If-Match": `"1"`}); code != 400 {
		t.Fatal("账户文件不能删")
	}
}

func TestAccountFileRotatesLoginKey(t *testing.T) {
	h := newHarness(t, store.Limits{})
	_ = h.db.CreateInvite(context.Background(), "INVITE-1", "", time.Hour)
	h.register("INVITE-1")
	h.login(h.key)

	_, newKey, _ := ed25519.GenerateKey(rand.Reader)
	file := accountFile("bmV3c2FsdG5ld3NhbHRuZQ==")
	pub := base64.StdEncoding.EncodeToString(newKey.Public().(ed25519.PublicKey))
	proof := func(k ed25519.PrivateKey) string {
		return base64.StdEncoding.EncodeToString(ed25519.Sign(k, auth.RotateMessage(accountID, sha256Hex(file))))
	}
	if code, _, _ := h.do("PUT", "/api/v1/files/account.1melon", file, map[string]string{"If-Match": `"1"`}); code != 400 {
		t.Fatal("没带新公钥应 400")
	}
	if code, _, _ := h.do("PUT", "/api/v1/files/account.1melon", file, map[string]string{
		"If-Match": `"1"`, "X-Auth-Public-Key": pub, "X-Auth-Proof": proof(h.key),
	}); code != 400 {
		t.Fatal("证明不是新私钥签的应 400")
	}
	v1 := bytes.Replace(file, []byte(`"version":2`), []byte(`"version":1`), 1)
	if code, _, _ := h.do("PUT", "/api/v1/files/account.1melon", v1, map[string]string{"If-Match": `"1"`}); code != 400 {
		t.Fatal("同步账户不能降成 v1")
	}
	if code, _, _ := h.do("PUT", "/api/v1/files/account.1melon", file, map[string]string{
		"If-Match": `"1"`, "X-Auth-Public-Key": pub, "X-Auth-Proof": proof(newKey),
	}); code != 200 {
		t.Fatal("换登录密钥")
	}
	if code, _ := h.login(h.key); code != 401 {
		t.Fatal("旧密钥（旧主密码）应登录不了")
	}
	if code, _ := h.login(newKey); code != 200 {
		t.Fatal("新密钥应能登录")
	}
	_, ch := h.json("POST", "/api/v1/auth/challenge", map[string]any{"accountId": accountID})
	if ch["kdf"].(map[string]any)["salt"] != "bmV3c2FsdG5ld3NhbHRuZQ==" {
		t.Fatal("挑战接口应返回新的 kdf")
	}
}

func TestQuotaDisableAndRateLimit(t *testing.T) {
	h := newHarness(t, store.Limits{MaxFileBytes: 1024, MaxAccountBytes: 4096, MaxFiles: 2})
	ctx := context.Background()
	_ = h.db.CreateInvite(ctx, "INVITE-1", "", time.Hour)
	h.register("INVITE-1")
	h.login(h.key)

	big := append(vaultFile(1), bytes.Repeat([]byte(" "), 2000)...)
	if code, _, _ := h.do("PUT", "/api/v1/files/vaults/"+vaultID+".1melon", big, map[string]string{"If-None-Match": "*"}); code != 413 {
		t.Fatalf("单个文件超限应 413，实际 %d", code)
	}
	if code, _, _ := h.do("PUT", "/api/v1/files/vaults/"+vaultID+".1melon", vaultFile(1), map[string]string{"If-None-Match": "*"}); code != 200 {
		t.Fatal("正常大小")
	}
	other := "cccccccc-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	third := bytes.ReplaceAll(vaultFile(1), []byte(vaultID), []byte(other))
	if code, _, _ := h.do("PUT", "/api/v1/files/vaults/"+other+".1melon", third, map[string]string{"If-None-Match": "*"}); code != 413 {
		t.Fatalf("超过文件数应 413，实际 %d", code)
	}

	// 停用：已发出的令牌立即失效，也不能再登录
	if err := h.db.SetDisabled(ctx, accountID, true); err != nil {
		t.Fatal(err)
	}
	if code, _ := h.json("GET", "/api/v1/files", nil); code != 401 {
		t.Fatalf("停用后令牌应失效 %d", code)
	}
	if code, m := h.login(h.key); code != 403 {
		t.Fatalf("停用后登录应 403 %d %v", code, m)
	}

	// 不用登录的接口按 IP 限流
	h.token = ""
	limited := false
	for i := 0; i < 40; i++ {
		if code, _ := h.json("POST", "/api/v1/auth/challenge", map[string]any{"accountId": accountID}); code == 429 {
			limited = true
			break
		}
	}
	if !limited {
		t.Fatal("应该被限流")
	}
}

func TestUnauthenticatedRequestsAreRejected(t *testing.T) {
	h := newHarness(t, store.Limits{})
	for _, p := range []string{"/api/v1/files", "/api/v1/devices"} {
		if code, m := h.json("GET", p, nil); code != 401 || errCode(m) != "unauthorized" {
			t.Fatalf("%s %d %v", p, code, m)
		}
	}
	h.token = "made-up"
	if code, _ := h.json("GET", "/api/v1/files", nil); code != 401 {
		t.Fatal("伪造令牌")
	}
}

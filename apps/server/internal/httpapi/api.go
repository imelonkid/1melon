package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/imelonkid/1melon/apps/server/internal/auth"
	"github.com/imelonkid/1melon/apps/server/internal/store"
)

// SessionTTL：会话令牌有效 1 小时（spec §3.2）
const SessionTTL = time.Hour

// 不带文件内容的 JSON 请求体上限；注册请求里带账户文件（几百字节），给足余量
const maxJSONBody = 256 << 10

func (s *Server) routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/auth/challenge", s.public(s.challenge))
	mux.HandleFunc("POST /api/v1/auth/session", s.public(s.session))
	mux.HandleFunc("POST /api/v1/accounts", s.public(s.register))
	mux.HandleFunc("GET /api/v1/devices", s.authed(s.listDevices))
	mux.HandleFunc("DELETE /api/v1/devices/{id}", s.authed(s.removeDevice))
	mux.HandleFunc("GET /api/v1/files", s.authed(s.listFiles))
	mux.HandleFunc("GET /api/v1/files/{name...}", s.authed(s.getFile))
	mux.HandleFunc("PUT /api/v1/files/{name...}", s.authed(s.putFile))
	mux.HandleFunc("DELETE /api/v1/files/{name...}", s.authed(s.deleteFile))
}

// MARK: 中间件：限流与认证

// public：不用登录的接口，按来源 IP 限流（防暴力尝试、刷邀请码）
func (s *Server) public(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if wait := s.publicLimit.allow(clientIP(r, s.TrustedProxyHeader), time.Now()); wait > 0 {
			tooMany(w, r, wait)
			return
		}
		h(w, r)
	}
}

type sessionKey struct{}

// authed：要 Bearer 会话令牌；按账户限流
func (s *Server) authed(h func(http.ResponseWriter, *http.Request, store.Session)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			writeError(w, r, http.StatusUnauthorized, "unauthorized", "要先登录")
			return
		}
		sess, err := s.Store.SessionFor(r.Context(), token)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, r, http.StatusUnauthorized, "unauthorized", "登录已过期，请重新登录")
			return
		} else if err != nil {
			s.internal(w, r, err)
			return
		}
		if wait := s.accountLimit.allow(sess.AccountID, time.Now()); wait > 0 {
			tooMany(w, r, wait)
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), sessionKey{}, sess)), sess)
	}
}

func tooMany(w http.ResponseWriter, r *http.Request, wait int) {
	w.Header().Set("Retry-After", strconv.Itoa(wait))
	writeError(w, r, http.StatusTooManyRequests, "rate_limited", "请求太频繁，稍后再试")
}

func (s *Server) internal(w http.ResponseWriter, r *http.Request, err error) {
	s.Log.Error("internal error", "trace_id", traceID(r), "path", r.URL.Path, "err", err.Error())
	writeError(w, r, http.StatusInternalServerError, "internal", "服务端出错了")
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxJSONBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeError(w, r, http.StatusBadRequest, "bad_request", "请求体不是合法的 JSON")
		return false
	}
	return true
}

func b64(s string) []byte {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil
	}
	return b
}

// MARK: 登录（spec §3.2）

func (s *Server) challenge(w http.ResponseWriter, r *http.Request) {
	var req struct {
		AccountID string `json:"accountId"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !auth.IsUUID(req.AccountID) {
		writeError(w, r, http.StatusBadRequest, "bad_request", "accountId 不是小写 UUID")
		return
	}
	key, err := s.Store.ServerKey(r.Context())
	if err != nil {
		s.internal(w, r, err)
		return
	}
	challenge, exp := auth.NewChallenge(key, req.AccountID, time.Now())
	var kdf any
	if raw, err := s.Store.AccountKDF(r.Context(), req.AccountID); err == nil {
		kdf = raw
	} else if errors.Is(err, store.ErrNotFound) {
		kdf = auth.FakeKDF(key, req.AccountID) // 不暴露账户是否存在
	} else {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"challenge": challenge, "expiresAt": exp, "kdf": kdf})
}

func (s *Server) session(w http.ResponseWriter, r *http.Request) {
	var req struct {
		AccountID string `json:"accountId"`
		Challenge string `json:"challenge"`
		Signature string `json:"signature"`
		Device    struct {
			ID       string `json:"id"`
			Name     string `json:"name"`
			Platform string `json:"platform"`
		} `json:"device"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	d := req.Device
	if !auth.IsUUID(req.AccountID) || !auth.IsUUID(d.ID) || d.Name == "" || len(d.Name) > 100 || d.Platform == "" || len(d.Platform) > 20 {
		writeError(w, r, http.StatusBadRequest, "bad_request", "参数不对")
		return
	}
	key, err := s.Store.ServerKey(r.Context())
	if err != nil {
		s.internal(w, r, err)
		return
	}
	nonce, exp, err := auth.VerifyChallenge(key, req.AccountID, req.Challenge, time.Now())
	if err != nil {
		writeError(w, r, http.StatusUnauthorized, "unauthorized", "挑战无效或已过期，请重新登录")
		return
	}
	account, err := s.Store.Account(r.Context(), req.AccountID)
	// 账户不存在和签名不对返回同样的结果，不暴露账户是否存在
	if errors.Is(err, store.ErrNotFound) || err == nil && !auth.Verify(account.AuthPublicKey, auth.LoginMessage(req.AccountID, req.Challenge), b64(req.Signature)) {
		writeError(w, r, http.StatusUnauthorized, "unauthorized", "主密码或 Secret Key 不对")
		return
	} else if err != nil {
		s.internal(w, r, err)
		return
	}
	if fresh, err := s.Store.UseChallenge(r.Context(), nonce, exp); err != nil {
		s.internal(w, r, err)
		return
	} else if !fresh {
		writeError(w, r, http.StatusUnauthorized, "unauthorized", "挑战已经用过，请重新登录")
		return
	}
	token, expiresAt, err := s.Store.CreateSession(r.Context(), req.AccountID, d.ID, d.Name, d.Platform, SessionTTL)
	if errors.Is(err, store.ErrDisabled) {
		writeError(w, r, http.StatusForbidden, "forbidden", "账户已被停用")
		return
	} else if err != nil {
		s.internal(w, r, err)
		return
	}
	s.Log.Info("login", "event", "auth.session", "trace_id", traceID(r), "account_id", req.AccountID, "device_id", d.ID)
	writeJSON(w, http.StatusOK, map[string]any{"token": token, "expiresAt": expiresAt, "deviceId": d.ID})
}

// MARK: 注册（spec §4.1）

func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	var req struct {
		InviteCode    string `json:"inviteCode"`
		AccountID     string `json:"accountId"`
		AuthPublicKey string `json:"authPublicKey"`
		Account       string `json:"account"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	pub, file := b64(req.AuthPublicKey), b64(req.Account)
	if !auth.IsUUID(req.AccountID) || len(pub) != 32 || req.InviteCode == "" {
		writeError(w, r, http.StatusBadRequest, "bad_request", "参数不对")
		return
	}
	if _, err := auth.CheckFile(store.AccountFileName, req.AccountID, file); err != nil {
		writeError(w, r, http.StatusBadRequest, "bad_request", "账户文件不对：要 v2（带 Secret Key）且属于这个账户")
		return
	}
	switch err := s.Store.Register(r.Context(), req.InviteCode, req.AccountID, pub, file); {
	case errors.Is(err, store.ErrInviteDenied):
		writeError(w, r, http.StatusForbidden, "forbidden", "邀请码无效、已用过或已过期")
	case errors.Is(err, store.ErrExists):
		writeError(w, r, http.StatusConflict, "exists", "这个账户已经注册过")
	case err != nil:
		s.internal(w, r, err)
	default:
		s.Log.Info("registered", "event", "account.register", "trace_id", traceID(r), "account_id", req.AccountID)
		writeJSON(w, http.StatusCreated, map[string]any{"accountId": req.AccountID})
	}
}

// MARK: 设备（spec §4.2）

func (s *Server) listDevices(w http.ResponseWriter, r *http.Request, sess store.Session) {
	devices, err := s.Store.Devices(r.Context(), sess.AccountID)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	type view struct {
		store.Device
		Current bool `json:"current"`
	}
	out := make([]view, 0, len(devices))
	for _, d := range devices {
		out = append(out, view{d, d.ID == sess.DeviceID})
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

func (s *Server) removeDevice(w http.ResponseWriter, r *http.Request, sess store.Session) {
	if err := s.Store.RemoveDevice(r.Context(), sess.AccountID, r.PathValue("id")); errors.Is(err, store.ErrNotFound) {
		writeError(w, r, http.StatusNotFound, "not_found", "没有这台设备")
	} else if err != nil {
		s.internal(w, r, err)
	} else {
		writeJSON(w, http.StatusOK, map[string]any{})
	}
}

// MARK: 文件（spec §5）

func (s *Server) listFiles(w http.ResponseWriter, r *http.Request, sess store.Session) {
	var since int64
	if v := r.URL.Query().Get("since"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			writeError(w, r, http.StatusBadRequest, "bad_request", "since 不对")
			return
		}
		since = n
	}
	files, cursor, err := s.Store.ListFiles(r.Context(), sess.AccountID, since)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"files": files, "cursor": strconv.FormatInt(cursor, 10)})
}

func (s *Server) fileName(w http.ResponseWriter, r *http.Request) (string, bool) {
	name := r.PathValue("name")
	if _, ok := auth.VaultIDFromName(name); !ok {
		writeError(w, r, http.StatusBadRequest, "bad_request", "文件名只能是 account.1melon 或 vaults/<小写 UUID>.1melon")
		return "", false
	}
	return name, true
}

func (s *Server) getFile(w http.ResponseWriter, r *http.Request, sess store.Session) {
	name, ok := s.fileName(w, r)
	if !ok {
		return
	}
	info, content, err := s.Store.GetFile(r.Context(), sess.AccountID, name)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, r, http.StatusNotFound, "not_found", "没有这个文件")
		return
	} else if err != nil {
		s.internal(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("ETag", strconv.Quote(strconv.FormatInt(info.Rev, 10)))
	w.Header().Set("X-Content-SHA256", info.SHA256)
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(content)
}

// precondition：If-None-Match: * = 新建；If-Match: "<rev>" = 更新；都没有就 400
func precondition(r *http.Request) (store.Precondition, bool) {
	if r.Header.Get("If-None-Match") == "*" {
		return store.Precondition{Create: true}, true
	}
	v := strings.Trim(strings.TrimSpace(r.Header.Get("If-Match")), `"`)
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 1 {
		return store.Precondition{}, false
	}
	return store.Precondition{IfMatch: n}, true
}

func (s *Server) putFile(w http.ResponseWriter, r *http.Request, sess store.Session) {
	name, ok := s.fileName(w, r)
	if !ok {
		return
	}
	pre, ok := precondition(r)
	if !ok {
		writeError(w, r, http.StatusBadRequest, "bad_request", "要带 If-Match: \"<rev>\" 或 If-None-Match: *")
		return
	}
	content, err := io.ReadAll(http.MaxBytesReader(w, r.Body, s.Limits.MaxFileBytes))
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		writeError(w, r, http.StatusRequestEntityTooLarge, "too_large", "文件太大")
		return
	} else if err != nil {
		writeError(w, r, http.StatusBadRequest, "bad_request", "读不到请求体")
		return
	}
	header, err := auth.CheckFile(name, sess.AccountID, content)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, "bad_request", "文件内容和文件名、账户对不上，或账户文件不是 v2")
		return
	}
	var newAuthKey []byte
	if header != nil {
		// 账户文件：要带新的登录公钥，并用新私钥证明（spec §5.3）
		pub := b64(r.Header.Get("X-Auth-Public-Key"))
		info := sha256Hex(content)
		if len(pub) != 32 || !auth.Verify(pub, auth.RotateMessage(sess.AccountID, info), b64(r.Header.Get("X-Auth-Proof"))) {
			writeError(w, r, http.StatusBadRequest, "bad_request", "上传账户文件要带 X-Auth-Public-Key 和有效的 X-Auth-Proof")
			return
		}
		newAuthKey = pub
	}
	info, err := s.Store.PutFile(r.Context(), sess.AccountID, name, content, pre, newAuthKey, s.Limits)
	switch {
	case errors.Is(err, store.ErrConflict):
		writeJSON(w, http.StatusPreconditionFailed, map[string]any{
			"error": map[string]string{"code": "conflict", "message": "文件已经被别的设备更新，先下载最新的再合并"},
			"rev":   info.Rev, "traceId": traceID(r),
		})
	case errors.Is(err, store.ErrQuota):
		writeError(w, r, http.StatusRequestEntityTooLarge, "too_large", "超过文件数或空间上限")
	case err != nil:
		s.internal(w, r, err)
	default:
		w.Header().Set("ETag", strconv.Quote(strconv.FormatInt(info.Rev, 10)))
		writeJSON(w, http.StatusOK, map[string]any{"rev": info.Rev, "sha256": info.SHA256})
	}
}

func (s *Server) deleteFile(w http.ResponseWriter, r *http.Request, sess store.Session) {
	name, ok := s.fileName(w, r)
	if !ok {
		return
	}
	if name == store.AccountFileName {
		writeError(w, r, http.StatusBadRequest, "bad_request", "账户文件不能删除")
		return
	}
	pre, ok := precondition(r)
	if !ok || pre.Create {
		writeError(w, r, http.StatusBadRequest, "bad_request", "要带 If-Match: \"<rev>\"")
		return
	}
	info, err := s.Store.DeleteFile(r.Context(), sess.AccountID, name, pre.IfMatch)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, r, http.StatusNotFound, "not_found", "没有这个文件")
	case errors.Is(err, store.ErrConflict):
		writeJSON(w, http.StatusPreconditionFailed, map[string]any{
			"error": map[string]string{"code": "conflict", "message": "文件已经被别的设备更新"},
			"rev":   info.Rev, "traceId": traceID(r),
		})
	case err != nil:
		s.internal(w, r, err)
	default:
		writeJSON(w, http.StatusOK, map[string]any{"rev": info.Rev})
	}
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

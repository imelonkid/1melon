package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"errors"
	"time"
)

// 业务层能识别的错误
var (
	ErrNotFound     = errors.New("not found")
	ErrExists       = errors.New("exists")
	ErrConflict     = errors.New("conflict")
	ErrInviteDenied = errors.New("invite invalid")
	ErrDisabled     = errors.New("disabled")
	ErrQuota        = errors.New("quota")
)

func nowMs() int64 { return time.Now().UnixMilli() }

func hash(b []byte) []byte {
	h := sha256.Sum256(b)
	return h[:]
}

// ServerKey：服务端自己的 32 字节随机密钥（签登录挑战、生成假 KDF 参数），第一次用时生成并存在库里。
// 它不能解密任何用户数据，泄露的后果只是能伪造挑战（仍然要用户的登录私钥签名）。
func (s *Store) ServerKey(ctx context.Context) ([]byte, error) {
	var key []byte
	err := s.db.QueryRowContext(ctx, "SELECT value FROM meta WHERE key = 'server_key'").Scan(&key)
	if err == nil {
		return key, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	key = make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO meta (key, value) VALUES ('server_key', ?)", key); err != nil {
		return nil, err
	}
	return s.ServerKey(ctx)
}

// MARK: 邀请码

type Invite struct {
	Note      string
	CreatedAt int64
	ExpiresAt int64
	UsedBy    string
	UsedAt    int64
}

func (s *Store) CreateInvite(ctx context.Context, code string, note string, ttl time.Duration) error {
	now := nowMs()
	_, err := s.db.ExecContext(ctx, "INSERT INTO invites (code_hash, note, created_at, expires_at) VALUES (?, ?, ?, ?)",
		hash([]byte(code)), note, now, now+ttl.Milliseconds())
	return err
}

func (s *Store) ListInvites(ctx context.Context) ([]Invite, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT note, created_at, expires_at, COALESCE(used_by, ''), COALESCE(used_at, 0) FROM invites ORDER BY created_at DESC")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Invite
	for rows.Next() {
		var i Invite
		if err := rows.Scan(&i.Note, &i.CreatedAt, &i.ExpiresAt, &i.UsedBy, &i.UsedAt); err != nil {
			return nil, err
		}
		out = append(out, i)
	}
	return out, rows.Err()
}

// MARK: 账户

type Account struct {
	ID            string
	AuthPublicKey []byte
	CreatedAt     int64
	Disabled      bool
}

// Register：在一个事务里用掉邀请码、建账户、存第一份账户文件（rev = 1）。
func (s *Store) Register(ctx context.Context, inviteCode, accountID string, authPublicKey, accountFile []byte) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := nowMs()
	var exists int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM accounts WHERE id = ?", accountID).Scan(&exists); err != nil {
		return err
	}
	if exists > 0 {
		return ErrExists
	}
	res, err := tx.ExecContext(ctx, `UPDATE invites SET used_by = NULL, used_at = ? WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?`,
		now, hash([]byte(inviteCode)), now)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return ErrInviteDenied
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO accounts (id, auth_public_key, created_at) VALUES (?, ?, ?)", accountID, authPublicKey, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "UPDATE invites SET used_by = ? WHERE code_hash = ?", accountID, hash([]byte(inviteCode))); err != nil {
		return err
	}
	if _, err := putFile(ctx, tx, accountID, AccountFileName, accountFile, now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) Account(ctx context.Context, id string) (Account, error) {
	var a Account
	var disabled int
	err := s.db.QueryRowContext(ctx, "SELECT id, auth_public_key, created_at, disabled FROM accounts WHERE id = ?", id).
		Scan(&a.ID, &a.AuthPublicKey, &a.CreatedAt, &disabled)
	if errors.Is(err, sql.ErrNoRows) {
		return a, ErrNotFound
	}
	a.Disabled = disabled != 0
	return a, err
}

type AccountUsage struct {
	Account
	Files   int
	Bytes   int64
	Devices int
}

func (s *Store) ListAccounts(ctx context.Context) ([]AccountUsage, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT a.id, a.created_at, a.disabled,
		(SELECT COUNT(*) FROM files f WHERE f.account_id = a.id AND f.deleted = 0),
		(SELECT COALESCE(SUM(size), 0) FROM files f WHERE f.account_id = a.id),
		(SELECT COUNT(*) FROM devices d WHERE d.account_id = a.id)
		FROM accounts a ORDER BY a.created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AccountUsage
	for rows.Next() {
		var u AccountUsage
		var disabled int
		if err := rows.Scan(&u.ID, &u.CreatedAt, &disabled, &u.Files, &u.Bytes, &u.Devices); err != nil {
			return nil, err
		}
		u.Disabled = disabled != 0
		out = append(out, u)
	}
	return out, rows.Err()
}

// SetDisabled：封禁时同时删掉这个账户的全部会话，已发出的令牌立即失效
func (s *Store) SetDisabled(ctx context.Context, id string, disabled bool) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	v := 0
	if disabled {
		v = 1
	}
	res, err := tx.ExecContext(ctx, "UPDATE accounts SET disabled = ? WHERE id = ?", v, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return ErrNotFound
	}
	if disabled {
		if _, err := tx.ExecContext(ctx, "DELETE FROM sessions WHERE account_id = ?", id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// MARK: 登录挑战与会话

// UseChallenge：挑战只能换一次会话。用过返回 false。顺手清掉过期的记录
func (s *Store) UseChallenge(ctx context.Context, nonce []byte, expiresAt int64) (bool, error) {
	if _, err := s.db.ExecContext(ctx, "DELETE FROM used_challenges WHERE expires_at < ?", nowMs()); err != nil {
		return false, err
	}
	res, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO used_challenges (nonce, expires_at) VALUES (?, ?)", nonce, expiresAt)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// CreateSession：登记（或更新）设备，发一个新令牌。账户被封禁返回 ErrDisabled
func (s *Store) CreateSession(ctx context.Context, accountID, deviceID, deviceName, platform string, ttl time.Duration) (token string, expiresAt int64, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback()
	var disabled int
	if err := tx.QueryRowContext(ctx, "SELECT disabled FROM accounts WHERE id = ?", accountID).Scan(&disabled); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", 0, ErrNotFound
		}
		return "", 0, err
	}
	if disabled != 0 {
		return "", 0, ErrDisabled
	}
	now := nowMs()
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices (account_id, id, name, platform, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT (account_id, id) DO UPDATE SET name = excluded.name, platform = excluded.platform, last_seen_at = excluded.last_seen_at`,
		accountID, deviceID, deviceName, platform, now, now); err != nil {
		return "", 0, err
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM sessions WHERE expires_at < ?", now); err != nil {
		return "", 0, err
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", 0, err
	}
	token = encodeToken(raw)
	expiresAt = now + ttl.Milliseconds()
	if _, err := tx.ExecContext(ctx, "INSERT INTO sessions (token_hash, account_id, device_id, expires_at) VALUES (?, ?, ?, ?)",
		hash([]byte(token)), accountID, deviceID, expiresAt); err != nil {
		return "", 0, err
	}
	return token, expiresAt, tx.Commit()
}

type Session struct {
	AccountID string
	DeviceID  string
}

// SessionFor：令牌 → 会话。过期、不存在或账户被封禁都返回 ErrNotFound
func (s *Store) SessionFor(ctx context.Context, token string) (Session, error) {
	var sess Session
	err := s.db.QueryRowContext(ctx, `SELECT s.account_id, s.device_id FROM sessions s JOIN accounts a ON a.id = s.account_id
		WHERE s.token_hash = ? AND s.expires_at > ? AND a.disabled = 0`, hash([]byte(token)), nowMs()).Scan(&sess.AccountID, &sess.DeviceID)
	if errors.Is(err, sql.ErrNoRows) {
		return sess, ErrNotFound
	}
	return sess, err
}

// MARK: 设备

type Device struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	CreatedAt  int64  `json:"createdAt"`
	LastSeenAt int64  `json:"lastSeenAt"`
}

func (s *Store) Devices(ctx context.Context, accountID string) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id, name, platform, created_at, last_seen_at FROM devices WHERE account_id = ? ORDER BY created_at", accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		var d Device
		if err := rows.Scan(&d.ID, &d.Name, &d.Platform, &d.CreatedAt, &d.LastSeenAt); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// RemoveDevice：删设备和它的全部会话
func (s *Store) RemoveDevice(ctx context.Context, accountID, deviceID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, "DELETE FROM devices WHERE account_id = ? AND id = ?", accountID, deviceID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM sessions WHERE account_id = ? AND device_id = ?", accountID, deviceID); err != nil {
		return err
	}
	return tx.Commit()
}

package store

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
)

const AccountFileName = "account.1melon"

// 上限（spec/sync-api.md §2）
type Limits struct {
	MaxFileBytes    int64
	MaxAccountBytes int64
	MaxFiles        int
}

var DefaultLimits = Limits{MaxFileBytes: 16 << 20, MaxAccountBytes: 256 << 20, MaxFiles: 1000}

type FileInfo struct {
	Name      string `json:"name"`
	Rev       int64  `json:"rev"`
	SHA256    string `json:"sha256"`
	Size      int64  `json:"size"`
	UpdatedAt int64  `json:"updatedAt"`
	Deleted   bool   `json:"deleted"`
	seq       int64
}

func encodeToken(raw []byte) string { return base64.RawURLEncoding.EncodeToString(raw) }

// ListFiles：since > 0 时只返回 seq 大于它的；返回新的游标（当前最大 seq）
func (s *Store) ListFiles(ctx context.Context, accountID string, since int64) ([]FileInfo, int64, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT name, rev, sha256, size, updated_at, deleted, seq FROM files
		WHERE account_id = ? AND seq > ? ORDER BY seq`, accountID, since)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []FileInfo{}
	cursor := since
	for rows.Next() {
		var f FileInfo
		var sum []byte
		var deleted int
		if err := rows.Scan(&f.Name, &f.Rev, &sum, &f.Size, &f.UpdatedAt, &deleted, &f.seq); err != nil {
			return nil, 0, err
		}
		f.SHA256 = hexString(sum)
		f.Deleted = deleted != 0
		if f.seq > cursor {
			cursor = f.seq
		}
		out = append(out, f)
	}
	return out, cursor, rows.Err()
}

// GetFile：已删除的文件当作不存在
func (s *Store) GetFile(ctx context.Context, accountID, name string) (FileInfo, []byte, error) {
	var f FileInfo
	var sum, content []byte
	var deleted int
	err := s.db.QueryRowContext(ctx, `SELECT name, rev, sha256, size, updated_at, deleted, content FROM files WHERE account_id = ? AND name = ?`,
		accountID, name).Scan(&f.Name, &f.Rev, &sum, &f.Size, &f.UpdatedAt, &deleted, &content)
	if errors.Is(err, sql.ErrNoRows) || deleted != 0 {
		return f, nil, ErrNotFound
	}
	if err != nil {
		return f, nil, err
	}
	f.SHA256 = hexString(sum)
	return f, content, nil
}

// Precondition：上传 / 删除时客户端声明自己见过的版本。Create = If-None-Match: *；否则 IfMatch = 见过的 rev
type Precondition struct {
	Create  bool
	IfMatch int64
}

// PutFile：「谁先写谁赢」：前提不满足返回 ErrConflict 和当前 rev。
// newAuthKey 不为空时（上传账户文件），在同一个事务里换上新的登录公钥。
func (s *Store) PutFile(ctx context.Context, accountID, name string, content []byte, pre Precondition, newAuthKey []byte, limits Limits) (FileInfo, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return FileInfo{}, err
	}
	defer tx.Rollback()
	cur, err := currentRev(ctx, tx, accountID, name)
	if err != nil {
		return FileInfo{}, err
	}
	if pre.Create && cur.rev > 0 && !cur.deleted || !pre.Create && (cur.rev == 0 || cur.deleted || cur.rev != pre.IfMatch) {
		return FileInfo{Rev: cur.rev}, ErrConflict
	}
	if int64(len(content)) > limits.MaxFileBytes {
		return FileInfo{}, ErrQuota
	}
	var files int
	var bytes int64
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(SUM(size), 0) FROM files WHERE account_id = ? AND deleted = 0 AND name != ?`,
		accountID, name).Scan(&files, &bytes); err != nil {
		return FileInfo{}, err
	}
	if files+1 > limits.MaxFiles || bytes+int64(len(content)) > limits.MaxAccountBytes {
		return FileInfo{}, ErrQuota
	}
	info, err := putFile(ctx, tx, accountID, name, content, nowMs())
	if err != nil {
		return FileInfo{}, err
	}
	if newAuthKey != nil {
		if _, err := tx.ExecContext(ctx, "UPDATE accounts SET auth_public_key = ? WHERE id = ?", newAuthKey, accountID); err != nil {
			return FileInfo{}, err
		}
	}
	return info, tx.Commit()
}

// DeleteFile：留删除标记（rev 加 1，内容清空），其他设备据此删掉本地的保险库
func (s *Store) DeleteFile(ctx context.Context, accountID, name string, ifMatch int64) (FileInfo, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return FileInfo{}, err
	}
	defer tx.Rollback()
	cur, err := currentRev(ctx, tx, accountID, name)
	if err != nil {
		return FileInfo{}, err
	}
	if cur.rev == 0 || cur.deleted {
		return FileInfo{}, ErrNotFound
	}
	if cur.rev != ifMatch {
		return FileInfo{Rev: cur.rev}, ErrConflict
	}
	now := nowMs()
	empty := hash(nil)
	if _, err := tx.ExecContext(ctx, `UPDATE files SET rev = rev + 1, seq = (SELECT COALESCE(MAX(seq), 0) + 1 FROM files),
		sha256 = ?, size = 0, content = x'', deleted = 1, updated_at = ? WHERE account_id = ? AND name = ?`,
		empty, now, accountID, name); err != nil {
		return FileInfo{}, err
	}
	if err := tx.Commit(); err != nil {
		return FileInfo{}, err
	}
	return FileInfo{Name: name, Rev: cur.rev + 1, SHA256: hexString(empty), UpdatedAt: now, Deleted: true}, nil
}

type revState struct {
	rev     int64
	deleted bool
}

func currentRev(ctx context.Context, tx *sql.Tx, accountID, name string) (revState, error) {
	var r revState
	var deleted int
	err := tx.QueryRowContext(ctx, "SELECT rev, deleted FROM files WHERE account_id = ? AND name = ?", accountID, name).Scan(&r.rev, &deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return r, nil
	}
	r.deleted = deleted != 0
	return r, err
}

func putFile(ctx context.Context, tx *sql.Tx, accountID, name string, content []byte, now int64) (FileInfo, error) {
	sum := hash(content)
	var rev int64
	err := tx.QueryRowContext(ctx, `INSERT INTO files (account_id, name, rev, seq, sha256, size, content, deleted, updated_at)
		VALUES (?, ?, 1, (SELECT COALESCE(MAX(seq), 0) + 1 FROM files), ?, ?, ?, 0, ?)
		ON CONFLICT (account_id, name) DO UPDATE SET rev = files.rev + 1, seq = excluded.seq, sha256 = excluded.sha256,
			size = excluded.size, content = excluded.content, deleted = 0, updated_at = excluded.updated_at
		RETURNING rev`, accountID, name, sum, len(content), content, now).Scan(&rev)
	if err != nil {
		return FileInfo{}, err
	}
	return FileInfo{Name: name, Rev: rev, SHA256: hexString(sum), Size: int64(len(content)), UpdatedAt: now}, nil
}

func hexString(b []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, len(b)*2)
	for i, c := range b {
		out[i*2], out[i*2+1] = digits[c>>4], digits[c&15]
	}
	return string(out)
}

// AccountKDF：账户文件里的 kdf 原文（登录挑战接口返回给新设备）
func (s *Store) AccountKDF(ctx context.Context, accountID string) (json.RawMessage, error) {
	_, content, err := s.GetFile(ctx, accountID, AccountFileName)
	if err != nil {
		return nil, err
	}
	var h struct {
		KDF json.RawMessage `json:"kdf"`
	}
	if err := json.Unmarshal(content, &h); err != nil || len(h.KDF) == 0 {
		return nil, ErrNotFound
	}
	return h.KDF, nil
}

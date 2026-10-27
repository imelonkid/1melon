// Package store：SQLite（WAL）。账户、设备、邀请码和各账户上传的密文文件都在这一个库里，
// 灾备由 Litestream 持续复制到另一朵云（注册表 assets）。服务端不解密任何内容。
package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

const fileName = "1melon.db"

type Store struct {
	db *sql.DB
}

// Open 打开（没有就新建）数据目录里的库，并执行还没执行过的迁移。
func Open(dataDir string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("建数据目录：%w", err)
	}
	dsn := "file:" + filepath.Join(dataDir, fileName) +
		"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// SQLite 同一时刻只有一个写者；单连接写最简单，读也足够快
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

// Ping：/health 用，确认库能读
func (s *Store) Ping(ctx context.Context) error {
	var one int
	return s.db.QueryRowContext(ctx, "SELECT 1").Scan(&one)
}

// SchemaVersion 当前已执行到第几个迁移
func (s *Store) SchemaVersion(ctx context.Context) (int, error) {
	var v int
	err := s.db.QueryRowContext(ctx, "SELECT COALESCE(MAX(version), 0) FROM schema_migrations").Scan(&v)
	return v, err
}

// 迁移只增不改：已发布的迁移不能修改，要变就加新的（保证回滚到上一个 tag 还能跑：先扩展、再收缩）
var migrations = []string{
	// 1：只有迁移表本身（骨架）
	`SELECT 1`,
	// 2：协议 v1 的表（spec/sync-api.md）
	`CREATE TABLE meta (
		key   TEXT PRIMARY KEY,
		value BLOB NOT NULL
	);
	CREATE TABLE accounts (
		id              TEXT PRIMARY KEY,               -- 小写 UUID
		auth_public_key BLOB NOT NULL,                  -- Ed25519 公钥 32 字节
		created_at      INTEGER NOT NULL,               -- 毫秒
		disabled        INTEGER NOT NULL DEFAULT 0
	);
	CREATE TABLE invites (
		code_hash  BLOB PRIMARY KEY,                    -- SHA-256(邀请码)，不存明文
		note       TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL,
		expires_at INTEGER NOT NULL,
		used_by    TEXT REFERENCES accounts(id),
		used_at    INTEGER
	);
	CREATE TABLE devices (
		account_id   TEXT NOT NULL REFERENCES accounts(id),
		id           TEXT NOT NULL,
		name         TEXT NOT NULL,
		platform     TEXT NOT NULL,
		created_at   INTEGER NOT NULL,
		last_seen_at INTEGER NOT NULL,
		PRIMARY KEY (account_id, id)
	);
	CREATE TABLE sessions (
		token_hash BLOB PRIMARY KEY,                    -- SHA-256(令牌)，不存明文
		account_id TEXT NOT NULL REFERENCES accounts(id),
		device_id  TEXT NOT NULL,
		expires_at INTEGER NOT NULL
	);
	CREATE INDEX sessions_account ON sessions(account_id);
	CREATE TABLE used_challenges (
		nonce      BLOB PRIMARY KEY,
		expires_at INTEGER NOT NULL
	);
	CREATE TABLE files (
		account_id TEXT NOT NULL REFERENCES accounts(id),
		name       TEXT NOT NULL,
		rev        INTEGER NOT NULL,                    -- 服务端修订号，每次写入加 1
		seq        INTEGER NOT NULL,                    -- 全局递增，GET /files?since= 用
		sha256     BLOB NOT NULL,
		size       INTEGER NOT NULL,
		content    BLOB NOT NULL,                       -- 客户端上传的密文，原样保存
		deleted    INTEGER NOT NULL DEFAULT 0,
		updated_at INTEGER NOT NULL,
		PRIMARY KEY (account_id, name)
	);
	CREATE INDEX files_seq ON files(account_id, seq);`,
}

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version INTEGER PRIMARY KEY,
		applied_at INTEGER NOT NULL DEFAULT (unixepoch())
	)`); err != nil {
		return fmt.Errorf("建迁移表：%w", err)
	}
	current, err := s.SchemaVersion(ctx)
	if err != nil {
		return err
	}
	for i := current; i < len(migrations); i++ {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, migrations[i]); err != nil {
			tx.Rollback()
			return fmt.Errorf("迁移 %d：%w", i+1, err)
		}
		if _, err := tx.ExecContext(ctx, "INSERT INTO schema_migrations (version) VALUES (?)", i+1); err != nil {
			tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

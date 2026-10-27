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
	// 1：只有迁移表本身。账户、设备、邀请码、文件的表等协议（spec/sync-api.md）确认后再加
	`SELECT 1`,
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

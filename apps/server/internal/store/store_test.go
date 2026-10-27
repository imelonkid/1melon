package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestOpenMigratesAndReopens(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(filepath.Join(dir, "data"))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Ping(context.Background()); err != nil {
		t.Fatal(err)
	}
	v, err := s.SchemaVersion(context.Background())
	if err != nil || v != len(migrations) {
		t.Fatalf("schema %d %v", v, err)
	}
	s.Close()

	// 再开一次：迁移不会重复执行
	s, err = Open(filepath.Join(dir, "data"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if v2, _ := s.SchemaVersion(context.Background()); v2 != v {
		t.Fatalf("schema %d → %d", v, v2)
	}
	info, err := os.Stat(filepath.Join(dir, "data"))
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("数据目录权限 %v %v", info.Mode().Perm(), err)
	}
}

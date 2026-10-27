// 1melon-server：1Melon 的同步服务端，只保存各端上传的密文（spec/sync-api.md）。
//
//	1melon-server            启动服务（默认）
//	1melon-server version    打印版本
//	1melon-server help       管理命令（邀请码、账户），见 admin.go
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/imelonkid/1melon/apps/server/internal/config"
	"github.com/imelonkid/1melon/apps/server/internal/httpapi"
	"github.com/imelonkid/1melon/apps/server/internal/logging"
	"github.com/imelonkid/1melon/apps/server/internal/store"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(os.Getenv("APP_VERSION"))
		return
	}
	if handled, err := admin(os.Args[1:], os.Stdout); handled {
		if err != nil {
			fmt.Fprintln(os.Stderr, "1melon-server:", err)
			os.Exit(1)
		}
		return
	}
	if err := serve(); err != nil {
		fmt.Fprintln(os.Stderr, "1melon-server:", err)
		os.Exit(1)
	}
}

func serve() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	log := logging.New(cfg.LogLevel, cfg.Version)
	db, err := store.Open(cfg.DataDir)
	if err != nil {
		return fmt.Errorf("打开数据库：%w", err)
	}
	defer db.Close()

	api := &httpapi.Server{Version: cfg.Version, DB: db, Store: db, Log: log, TrustedProxyHeader: cfg.TrustedProxyHeader}
	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           api.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	errc := make(chan error, 1)
	go func() {
		log.Info("listening", "event", "server.start", "addr", cfg.Addr, "env", cfg.Env)
		errc <- srv.ListenAndServe()
	}()
	select {
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		log.Info("shutting down", "event", "server.stop")
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return srv.Shutdown(shutdown)
	}
	return nil
}

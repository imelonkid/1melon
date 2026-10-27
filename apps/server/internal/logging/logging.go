// Package logging：stdout 一行一条 JSON（运维规范 §8）：必带 ts / level / service / version / msg，请求内带 trace_id。
// 不记录任何请求体和令牌；文件内容是密文，也不记。
package logging

import (
	"log/slog"
	"os"
	"strings"
)

const Service = "1melon-server"

func New(level, version string) *slog.Logger {
	var l slog.Level
	switch strings.ToLower(level) {
	case "debug":
		l = slog.LevelDebug
	case "warn":
		l = slog.LevelWarn
	case "error":
		l = slog.LevelError
	default:
		l = slog.LevelInfo
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: l,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.TimeKey:
				a.Key = "ts"
			case slog.LevelKey:
				a.Value = slog.StringValue(strings.ToLower(a.Value.String()))
			}
			return a
		},
	})
	return slog.New(h).With("service", Service, "version", version)
}

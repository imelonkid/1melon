// Package config 从环境变量读配置（.env 由 compose 的 env_file 注入；真实值在 1Password「ops/1melon/prod」）。
package config

import (
	"fmt"
	"net"
	"os"
	"strconv"
)

type Config struct {
	// 运行环境：dev | prod
	Env string
	// 监听地址：BIND_ADDR:PORT，容器里是 :8790（所有网卡，由 compose 映射到宿主机 127.0.0.1）
	Addr string
	// 数据目录：SQLite 库在这里（compose 挂 ./data）
	DataDir string
	// 日志级别：debug | info | warn | error
	LogLevel string
	// 发布 tag（镜像构建时烘进去），/health 返回它
	Version string
	// 反向代理写真实客户端 IP 的请求头（线上 openresty 写 X-Real-IP）；为空 = 用连接地址（限流按 IP 算）
	TrustedProxyHeader string
}

func Load() (Config, error) {
	c := Config{
		Env:      get("APP_ENV", "dev"),
		DataDir:  get("DATA_DIR", "/data"),
		LogLevel: get("LOG_LEVEL", "info"),
		Version:  get("APP_VERSION", "dev"),

		TrustedProxyHeader: get("TRUSTED_PROXY_HEADER", ""),
	}
	port := get("PORT", "8790")
	if _, err := strconv.Atoi(port); err != nil {
		return c, fmt.Errorf("PORT 不是数字：%q", port)
	}
	// 监听的 IP；留空 = 所有网卡。本机直接 go run 时设 127.0.0.1，免得局域网也能连
	bind := get("BIND_ADDR", "")
	if bind != "" && net.ParseIP(bind) == nil {
		return c, fmt.Errorf("BIND_ADDR 不是 IP 地址：%q", bind)
	}
	c.Addr = net.JoinHostPort(bind, port)
	if c.Env != "dev" && c.Env != "prod" {
		return c, fmt.Errorf("APP_ENV 只能是 dev 或 prod：%q", c.Env)
	}
	return c, nil
}

func get(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

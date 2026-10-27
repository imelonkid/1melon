// Package config 从环境变量读配置（.env 由 compose 的 env_file 注入；真实值在 1Password「ops/1melon/prod」）。
package config

import (
	"fmt"
	"os"
	"strconv"
)

type Config struct {
	// 运行环境：dev | prod
	Env string
	// 监听地址，容器里是 :8790
	Addr string
	// 数据目录：SQLite 库在这里（compose 挂 ./data）
	DataDir string
	// 日志级别：debug | info | warn | error
	LogLevel string
	// 发布 tag（镜像构建时烘进去），/health 返回它
	Version string
}

func Load() (Config, error) {
	c := Config{
		Env:      get("APP_ENV", "dev"),
		DataDir:  get("DATA_DIR", "/data"),
		LogLevel: get("LOG_LEVEL", "info"),
		Version:  get("APP_VERSION", "dev"),
	}
	port := get("PORT", "8790")
	if _, err := strconv.Atoi(port); err != nil {
		return c, fmt.Errorf("PORT 不是数字：%q", port)
	}
	c.Addr = ":" + port
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

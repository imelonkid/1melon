#!/usr/bin/env bash
# 项目基线 · CI 测试入口（melon-ci pr-check：scripts/ci-test.sh 存在就跑；本机也能跑）。多端：桌面端 + 服务端。
# 技术选型例外（原生 Swift）：PR 检查跑在 Linux 上，只测不依赖界面的 MelonCore（Package.swift 在 Linux 上不含 MelonApp）；
# SwiftUI 界面只能在 macOS 编译，交给发布流水线（scripts/package-desktop.sh）。
# 服务端（Go，技术选型例外）：单测 + 起一个真实进程做 /health 冒烟。不碰外网（依赖除外）和真实数据。
set -euo pipefail
cd "$(dirname "$0")/.."

command -v swift >/dev/null || { echo "✗ 构建机没有 Swift 工具链" >&2; exit 1; }
swift --version

echo "▸ 脚本语法"
for f in scripts/*.sh; do bash -n "$f"; done

echo "▸ MelonCore 单测（含 spec/test-vectors 跨端测试向量）"
swift test --package-path apps/desktop

echo "▸ 服务端（apps/server）：go vet、单测、/health 冒烟"
command -v go >/dev/null || { echo "✗ 构建机没有 Go 工具链" >&2; exit 1; }
(
  cd apps/server
  go version
  test -z "$(gofmt -l .)" || { echo "✗ 有没格式化的 Go 文件：$(gofmt -l .)" >&2; exit 1; }
  go vet ./...
  go test ./...
  tmp="$(mktemp -d)"
  trap 'kill "${pid:-}" 2>/dev/null || true; rm -rf "$tmp"' EXIT
  go build -o "$tmp/1melon-server" ./cmd/1melon-server
  APP_VERSION=server-v0.0.0-ci DATA_DIR="$tmp/data" PORT=18790 LOG_LEVEL=warn "$tmp/1melon-server" & pid=$!
  for _ in $(seq 1 50); do
    body="$(curl -fsS http://127.0.0.1:18790/health 2>/dev/null)" && break
    sleep 0.2
  done
  echo "  /health → ${body:-没有响应}"
  [[ "$body" == *'"ok":true'* && "$body" == *'"version":"server-v0.0.0-ci"'* ]] || { echo "✗ /health 不对" >&2; exit 1; }
)

echo "▸ 用独立的 Python 实现交叉验证测试向量（spec/tools/verify-vectors.py）"
if python3 -c 'from cryptography.hazmat.primitives.kdf.argon2 import Argon2id' 2>/dev/null; then
  python3 -I spec/tools/verify-vectors.py
else
  echo "  跳过：构建机的 python3 没有带 Argon2id 的 cryptography（>= 44）"
fi

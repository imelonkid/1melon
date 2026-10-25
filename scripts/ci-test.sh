#!/usr/bin/env bash
# 项目基线 · 桌面应用的 CI 测试入口（melon-ci pr-check：scripts/ci-test.sh 存在就跑；本机也能跑）。
# 技术选型例外（原生 Swift）：PR 检查跑在 Linux 上，只测不依赖界面的 MelonCore（Package.swift 在 Linux 上不含 MelonApp）；
# SwiftUI 界面只能在 macOS 编译，交给发布流水线（scripts/package-desktop.sh）。不碰外网（依赖除外）和真实数据。
set -euo pipefail
cd "$(dirname "$0")/.."

command -v swift >/dev/null || { echo "✗ 构建机没有 Swift 工具链" >&2; exit 1; }
swift --version

echo "▸ 脚本语法"
for f in scripts/*.sh; do bash -n "$f"; done

echo "▸ MelonCore 单测（含 spec/test-vectors 跨端测试向量）"
swift test --package-path apps/desktop

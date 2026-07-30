#!/usr/bin/env bash
# ──────────────────────────────────────────────────
# MIX Agent 打包脚本
# 在构建机上运行，打包 Python + Hermes Agent + 依赖
# 产物放到 android/app/src/main/assets/ 下
# ──────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ASSETS_DIR="$PROJECT_DIR/android/app/src/main/assets"
FILES_DIR="$PROJECT_DIR/build/mix-agent-bundle"

mkdir -p "$FILES_DIR" "$ASSETS_DIR"

echo "=== 下载 Python 3.11 ARM64 Android 编译版 ==="
# 从 Termux 社区 CI 产物获取（或自行交叉编译）
# 这里用官方 termux-packages 的编译产物
PYTHON_URL="https://github.com/termux/termux-packages/releases/download/python-3.11.11/python_3.11.11_arm64.tar.gz"
if [ ! -f "$FILES_DIR/python-arm64.tar.gz" ]; then
  curl -Lo "$FILES_DIR/python-arm64.tar.gz" "$PYTHON_URL"
fi

echo "=== 下载 Hermes Agent ==="
HERMES_DIR="$FILES_DIR/hermes"
if [ ! -d "$HERMES_DIR" ]; then
  git clone --depth 1 --branch v0.18.0 \
    https://github.com/NousResearch/hermes-agent.git "$HERMES_DIR"
fi

echo "=== 安装 Hermes 依赖（锁版本） ==="
# 使用打包机的 pip 安装到指定目录
pip3 install --target="$FILES_DIR/hermes-packages" \
  -r "$HERMES_DIR/requirements.txt" \
  aiohttp==3.9.5 \
  pydantic==2.7.4 \
  pyyaml==6.0.1

echo "=== 复制 MIX 插件 ==="
mkdir -p "$FILES_DIR/hermes/plugins/mix"
cp -r "$PROJECT_DIR/mix-plugin/"* "$FILES_DIR/hermes/plugins/mix/"

echo "=== 生成配置文件 ==="
cat > "$FILES_DIR/hermes/config.yaml" << 'YAML'
# MIX Agent 配置 — 自动生成，请勿手动修改
server:
  host: "127.0.0.1"
  port: 0  # 随机端口

model: "claude-sonnet-4-20250514"

tools:
  enabled: true

plugins:
  - "mix"
YAML

echo "=== 打包资产 ==="
cd "$FILES_DIR"
tar czf "$ASSETS_DIR/mix-agent-bundle.tar.gz" \
  python-arm64.tar.gz \
  hermes/ \
  hermes-packages/

echo "=== 完成 ==="
echo "产物: $ASSETS_DIR/mix-agent-bundle.tar.gz"
echo "大小: $(du -h "$ASSETS_DIR/mix-agent-bundle.tar.gz" | cut -f1)"

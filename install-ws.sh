#!/usr/bin/env bash
# Xray VLESS + WebSocket 安装脚本（调用 install.sh 的 ws 模式）
exec "$(cd "$(dirname "$0")" && pwd)/install.sh" -mode ws "$@"

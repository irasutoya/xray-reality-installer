#!/usr/bin/env bash

# Xray VLESS + WebSocket 安装脚本

set -Eeuo pipefail

BASE_DIR="/root/xray"
INSTALL_DIR="${BASE_DIR}/bin"
CONFIG_DIR="${BASE_DIR}/config"
SERVICE_FILE="/etc/systemd/system/xray.service"
CONFIG_FILE="${CONFIG_DIR}/config.json"
PORT=80
UUID=""
UNINSTALL=false
TEMP_DIR=""

GREEN="\033[1;32m"
RED="\033[1;31m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
NC="\033[0m"

log() {
  echo -e "${GREEN}[+]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[*]${NC} $1" >&2
}

error() {
  echo -e "${RED}[!]${NC} $1" >&2
}

fail() {
  error "$1"
  exit 1
}

show_help() {
  echo -e "${BLUE}Xray VLESS + WebSocket 安装脚本${NC}"
  echo "用法: $0 [选项]"
  echo
  echo "选项:"
  echo -e "  ${GREEN}-port${NC}        设置监听端口 (默认: 80)"
  echo -e "  ${GREEN}-uuid${NC}        设置 VLESS UUID (默认: 随机生成)"
  echo -e "  ${GREEN}-uninstall${NC}   卸载 Xray 服务及所有相关文件"
  echo -e "  ${GREEN}-help${NC}        显示帮助信息"
}

validate_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    fail "端口必须是 1-65535 之间的数字"
  fi
}

validate_uuid() {
  local uuid="$1"
  if [[ ! "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
    fail "UUID 格式无效"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -port)
        [[ -n "${2:-}" ]] || fail "-port 需要指定端口"
        validate_port "$2"
        PORT="$2"
        shift 2
        ;;
      -uuid)
        [[ -n "${2:-}" ]] || fail "-uuid 需要指定 UUID"
        validate_uuid "$2"
        UUID="$2"
        shift 2
        ;;
      -uninstall)
        UNINSTALL=true
        shift
        ;;
      -help)
        show_help
        exit 0
        ;;
      *)
        error "未知参数: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "请使用 root 用户运行此脚本"
  fi
}

cleanup_temp() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

handle_interrupt() {
  echo
  warn "操作被中断"
  exit 1
}

uninstall() {
  log "开始卸载 Xray 服务和相关文件..."
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$BASE_DIR"
}

install_dependencies() {
  log "安装必要的依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl wget jq unzip
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl wget jq unzip
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl wget jq unzip
  else
    fail "不支持的包管理器，请手动安装 curl、wget、jq 和 unzip"
  fi
  log "依赖安装完成！"
}

verify_dependencies() {
  local deps=(curl wget jq unzip)
  local dep
  for dep in "${deps[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || fail "缺少依赖: $dep"
  done
}

generate_uuid() {
  if [[ -n "$UUID" ]]; then
    return
  fi

  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
  elif command -v uuidgen >/dev/null 2>&1; then
    UUID=$(uuidgen)
  else
    fail "无法生成 UUID，请使用 -uuid 手动指定"
  fi
}

determine_architecture() {
  log "检测系统架构..."
  local machine
  machine=$(uname -m)
  case "$machine" in
    x86_64) ARCH="64" ;;
    aarch64) ARCH="arm64-v8a" ;;
    armv7l) ARCH="arm32-v7a" ;;
    armv6l) ARCH="arm32-v6" ;;
    i386 | i686) ARCH="32" ;;
    mips64le) ARCH="mips64le" ;;
    mipsle) ARCH="mipsle" ;;
    *) fail "不支持的架构：$machine" ;;
  esac
  log "检测到架构：$ARCH"
}

fetch_latest_version() {
  local version
  version=$(curl -fsSLm 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
  if [[ -z "$version" ]]; then
    warn "获取最新版本失败，尝试读取 tags..."
    version=$(curl -fsSLm 10 https://api.github.com/repos/XTLS/Xray-core/tags 2>/dev/null | jq -r '.[0].name // empty' 2>/dev/null || true)
  fi
  printf '%s' "$version"
}

install_xray() {
  log "下载并安装 Xray..."
  mkdir -p "$INSTALL_DIR"

  local latest_version download_url archive extract_dir
  latest_version=$(fetch_latest_version)
  if [[ -z "$latest_version" ]]; then
    warn "无法获取版本信息，将使用 GitHub latest 下载链接"
    download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
    log "下载版本: latest, 架构: ${ARCH}"
  else
    download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_version}/Xray-linux-${ARCH}.zip"
    log "下载版本: ${latest_version}, 架构: ${ARCH}"
  fi

  TEMP_DIR=$(mktemp -d)
  archive="${TEMP_DIR}/xray.zip"
  extract_dir="${TEMP_DIR}/xray"

  wget -q -O "$archive" "$download_url" || fail "下载 Xray 失败，请检查网络连接"
  [[ -s "$archive" ]] || fail "下载的文件为空，请检查网络连接或下载链接"

  mkdir -p "$extract_dir"
  unzip -q "$archive" -d "$extract_dir" || fail "解压 Xray 失败"
  [[ -f "${extract_dir}/xray" ]] || fail "压缩包中未找到 xray 可执行文件"

  mv "${extract_dir}/xray" "${INSTALL_DIR}/xray" || fail "安装 Xray 失败"
  chmod +x "${INSTALL_DIR}/xray"
  log "Xray 已安装到 ${INSTALL_DIR}/xray"
}

create_config_file() {
  log "创建配置文件..."
  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
  log "配置文件已生成：$CONFIG_FILE"
}

create_systemd_service() {
  log "创建 systemd 服务文件..."
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xray run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || fail "重新加载 systemd 失败"
  log "systemd 服务文件已创建：$SERVICE_FILE"
}

print_client_config() {
  log "获取服务器 IP 地址..."
  local server_ip vless_url mihomo_config
  server_ip=$(curl -fsSLm 10 https://api.ipify.org 2>/dev/null || true)
  if [[ -z "$server_ip" ]]; then
    warn "无法获取服务器 IP 地址，将使用 localhost 代替"
    server_ip="localhost"
  fi

  vless_url="vless://${UUID}@${server_ip}:${PORT}?type=ws&security=none&path=/#${server_ip}"
  mihomo_config="proxies:
  - name: ${server_ip}
    server: ${server_ip}
    port: ${PORT}
    type: vless
    uuid: ${UUID}
    tls: false
    udp: true
    ws-opts:
      path: /
    network: ws"

  echo
  echo -e "${BLUE}====== 客户端配置 (VLESS URL) ======${NC}"
  echo "$vless_url"
  echo
  echo -e "${BLUE}====== 客户端配置 (Mihomo 配置) ======${NC}"
  echo "$mihomo_config"
  echo
}

start_service() {
  log "启动 Xray 服务..."
  systemctl start xray || fail "启动 Xray 服务失败，请检查日志: journalctl -u xray"

  systemctl enable xray || warn "设置 Xray 服务开机启动失败"

  if systemctl is-active --quiet xray; then
    log "Xray 服务已成功启动并设置为开机启动！"
  else
    fail "Xray 服务启动失败，请检查日志: journalctl -u xray"
  fi
}

show_status() {
  if [[ ! -f "$SERVICE_FILE" ]]; then
    warn "Xray 未安装"
    return
  fi
  if systemctl is-active --quiet xray 2>/dev/null; then
    log "Xray 服务状态：${GREEN}运行中${NC}"
  else
    warn "Xray 服务状态：${RED}未运行${NC}"
  fi
}

menu_header() {
  echo
  echo -e "${BLUE} >> 操作菜单${NC}"
  echo -e "   ${GREEN}1)${NC} 安装"
  echo -e "   ${GREEN}2)${NC} 卸载"
  echo -e "   ${GREEN}3)${NC} 查看状态"
  echo -e "   ${GREEN}0)${NC} 退出"
}

main() {
  require_root

  while true; do
    menu_header
    echo
    printf "${YELLOW}[?]${NC} 请选择 [0-3]: "
    read choice || true

    case "$choice" in
      1)
        echo
        printf "${YELLOW}[?]${NC} 监听端口 (默认: 80): "
        read input_port || true
        PORT="${input_port:-80}"
        validate_port "$PORT"

        printf "${YELLOW}[?]${NC} VLESS UUID (留空自动生成): "
        read input_uuid || true
        UUID="${input_uuid:-}"

        install_dependencies
        verify_dependencies
        generate_uuid
        validate_uuid "$UUID"
        determine_architecture
        install_xray
        create_config_file
        create_systemd_service
        start_service
        echo -e "${GREEN}[+]${NC} Xray 安装完成！文件路径：$BASE_DIR"
        print_client_config
        ;;
      2)
        echo
        printf "${YELLOW}[?]${NC} 确认卸载？[y/N]: "
        read confirm || true
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
          uninstall
          echo -e "${GREEN}[+]${NC} Xray 已卸载"
        else
          warn "取消卸载"
        fi
        ;;
      3)
        show_status
        ;;
      0)
        echo -e "${GREEN}[+]${NC} 再见"
        exit 0
        ;;
      *)
        echo -e "${RED}[!]${NC} 无效选择，请重新输入"
        ;;
    esac
  done
}

trap cleanup_temp EXIT
trap handle_interrupt INT TERM

main "$@"

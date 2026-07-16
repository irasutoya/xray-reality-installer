#!/usr/bin/env bash
# VLESS + Vision + REALITY installer for Xray-core

# 不启用 `set -e`：systemctl 的“未运行/未启用”也是非零状态，不能把它误当成脚本异常。
# 所有会修改系统的关键命令都在调用处显式检查。
set -uo pipefail

SCRIPT_NAME="${0##*/}"

PORT="443"
DOMAIN="itunes.apple.com"
FINGERPRINT="chrome"
UUID=""
VERSION="latest"
ACTION="menu"
FORCE=0

XRAY_BIN="/usr/local/bin/xray"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLIENT_FILE="${CONFIG_DIR}/client.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
LEGACY_DIR="/root/xray"

ARCH=""
SERVICE_GROUP=""
TEMP_DIR=""
STAGED_BIN=""
STAGED_CONFIG=""
STAGED_CLIENT=""
STAGED_SERVICE=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

TRANSACTION_ACTIVE=0
HAD_BIN=0
HAD_CONFIG=0
HAD_CLIENT=0
HAD_SERVICE=0
WAS_ACTIVE=0
WAS_ENABLED=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN='\033[1;32m'
  RED='\033[1;31m'
  BLUE='\033[1;34m'
  YELLOW='\033[1;33m'
  NC='\033[0m'
else
  GREEN=''
  RED=''
  BLUE=''
  YELLOW=''
  NC=''
fi

info()  { printf '%b\n' "${GREEN}[+]${NC} $*"; }
warn()  { printf '%b\n' "${YELLOW}[*]${NC} $*" >&2; }
error() { printf '%b\n' "${RED}[!]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

show_help() {
  printf '%b\n' "${BLUE}Xray REALITY 一键安装脚本${NC}"
  cat <<EOF
用法:
  ${SCRIPT_NAME}                         打开交互菜单
  ${SCRIPT_NAME} --install [选项]        非交互安装
  ${SCRIPT_NAME} --uninstall             卸载
  ${SCRIPT_NAME} --status                查看服务状态
  ${SCRIPT_NAME} --show-config           输出客户端配置

安装选项:
  -p, --port PORT          监听端口（默认 443）
  -u, --uuid UUID          VLESS UUID（默认由 Xray 生成）
  -d, --domain DOMAIN      REALITY 目标域名（默认 ${DOMAIN}）
  -f, --fingerprint FP     客户端指纹（默认 ${FINGERPRINT}）
  -v, --version VERSION    Xray 版本，例如 v26.3.27（默认 latest）
  -y, --force              覆盖已有安装，不再确认

兼容旧参数:
  -port -uuid -domain -fingerprint -uninstall -help

其他:
  -h, --help               显示帮助
EOF
}

select_action() {
  local requested="$1"
  if [[ "$ACTION" != "menu" && "$ACTION" != "$requested" ]]; then
    die "一次只能执行一个操作（当前: ${ACTION}，请求: ${requested}）"
  fi
  ACTION="$requested"
  return 0
}

require_value() {
  [[ -n "${2:-}" ]] || die "$1 需要一个值"
  return 0
}

validate_port() {
  local value="$1" number
  [[ "$value" =~ ^[0-9]+$ ]] || die "端口必须是 1-65535 之间的数字"
  number=$((10#$value))
  ((number >= 1 && number <= 65535)) || die "端口必须是 1-65535 之间的数字"
  return 0
}

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] \
    || die "UUID 格式无效"
  return 0
}

validate_domain() {
  local domain="$1" label remaining
  [[ ${#domain} -le 253 && "$domain" == *.* ]] || die "域名格式无效: ${domain}"
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "域名只能包含字母、数字、点和连字符"

  remaining="$domain"
  while [[ "$remaining" == *.* ]]; do
    label="${remaining%%.*}"
    remaining="${remaining#*.}"
    [[ -n "$label" && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] \
      || die "域名标签格式无效: ${domain}"
  done
  [[ -n "$remaining" && ${#remaining} -le 63 && "$remaining" != -* && "$remaining" != *- ]] \
    || die "域名标签格式无效: ${domain}"
  return 0
}

validate_fingerprint() {
  case "$1" in
    chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) return 0 ;;
    *) die "不支持的客户端指纹: $1" ;;
  esac
}

validate_version() {
  [[ "$1" == "latest" || "$1" =~ ^v?[0-9]+([.][0-9]+){1,2}([.-][0-9A-Za-z]+)*$ ]] \
    || die "Xray 版本格式无效: $1"
  return 0
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --install)
        select_action install
        shift
        ;;
      -p|--port|-port)
        require_value "$1" "${2:-}"
        validate_port "$2"
        PORT="$2"
        select_action install
        shift 2
        ;;
      -u|--uuid|-uuid)
        require_value "$1" "${2:-}"
        validate_uuid "$2"
        UUID="$2"
        select_action install
        shift 2
        ;;
      -d|--domain|-domain)
        require_value "$1" "${2:-}"
        validate_domain "$2"
        DOMAIN="$2"
        select_action install
        shift 2
        ;;
      -f|--fingerprint|-fingerprint)
        require_value "$1" "${2:-}"
        validate_fingerprint "$2"
        FINGERPRINT="$2"
        select_action install
        shift 2
        ;;
      -v|--version)
        require_value "$1" "${2:-}"
        validate_version "$2"
        VERSION="$2"
        select_action install
        shift 2
        ;;
      -y|--force)
        FORCE=1
        select_action install
        shift
        ;;
      --uninstall|-uninstall)
        select_action uninstall
        shift
        ;;
      --status)
        select_action status
        shift
        ;;
      --show-config)
        select_action show-config
        shift
        ;;
      -h|--help|-help)
        select_action help
        shift
        ;;
      --)
        shift
        (($# == 0)) || die "不支持位置参数: $*"
        ;;
      *) die "未知参数: $1（使用 --help 查看帮助）" ;;
    esac
  done
  return 0
}

require_supported_system() {
  [[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux"
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 用户运行"
  command -v systemctl >/dev/null 2>&1 || die "系统未安装 systemctl"
  [[ -d /run/systemd/system || -d /.dockerenv ]] || die "当前系统似乎未使用 systemd"
  id nobody >/dev/null 2>&1 || die "系统不存在 nobody 用户"
  SERVICE_GROUP=$(id -gn nobody) || die "无法读取 nobody 用户组"
  return 0
}

add_package() {
  local candidate="$1" item
  for item in "${PACKAGES[@]:-}"; do
    [[ "$item" == "$candidate" ]] && return 0
  done
  PACKAGES+=("$candidate")
  return 0
}

install_dependencies() {
  local command_name package_name
  local required=(curl jq unzip openssl sha256sum install)
  PACKAGES=()

  for command_name in "${required[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      case "$command_name" in
        sha256sum|install) package_name="coreutils" ;;
        *) package_name="$command_name" ;;
      esac
      add_package "$package_name"
    fi
  done

  if ((${#PACKAGES[@]} == 0)); then
    info "系统依赖已满足"
    return 0
  fi

  info "安装依赖: ${PACKAGES[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || die "apt-get update 失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${PACKAGES[@]}" \
      || die "依赖安装失败"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "${PACKAGES[@]}" || die "依赖安装失败"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "${PACKAGES[@]}" || die "依赖安装失败"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install -y "${PACKAGES[@]}" || die "依赖安装失败"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed "${PACKAGES[@]}" || die "依赖安装失败"
  else
    die "找不到受支持的包管理器，请手动安装: ${PACKAGES[*]}"
  fi

  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || die "依赖安装后仍找不到: ${command_name}"
  done
  return 0
}

map_architecture() {
  case "$1" in
    i386|i686)        printf '%s\n' 32 ;;
    amd64|x86_64)    printf '%s\n' 64 ;;
    armv5tel)        printf '%s\n' arm32-v5 ;;
    armv6l)          printf '%s\n' arm32-v6 ;;
    armv7|armv7l)    printf '%s\n' arm32-v7a ;;
    armv8|aarch64)   printf '%s\n' arm64-v8a ;;
    mips)            printf '%s\n' mips32 ;;
    mipsle)          printf '%s\n' mips32le ;;
    mips64|mips64le|ppc64|ppc64le|riscv64|s390x) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

determine_architecture() {
  local machine
  machine=$(uname -m)
  ARCH=$(map_architecture "$machine") || die "不支持的系统架构: ${machine}"
  if [[ "$machine" == "armv6l" || "$machine" == "armv7" || "$machine" == "armv7l" ]]; then
    if ! grep -qw vfp /proc/cpuinfo 2>/dev/null; then
      ARCH="arm32-v5"
    fi
  fi
  if [[ "$machine" == "mips64" ]] && command -v lscpu >/dev/null 2>&1; then
    if lscpu | grep -qi 'little endian'; then
      ARCH="mips64le"
    fi
  fi
  info "系统架构: ${machine} -> ${ARCH}"
  return 0
}

make_temp_dir() {
  TEMP_DIR=$(mktemp -d) || die "无法创建临时目录"
  STAGED_CONFIG="${TEMP_DIR}/config.json"
  STAGED_CLIENT="${TEMP_DIR}/client.json"
  STAGED_SERVICE="${TEMP_DIR}/xray.service"
  return 0
}

fetch_latest_version() {
  curl -fsSL --connect-timeout 10 --max-time 20 \
    -H 'Accept: application/vnd.github+json' \
    'https://api.github.com/repos/XTLS/Xray-core/releases/latest' 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null
}

download_file() {
  local url="$1" destination="$2"
  curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 10 --max-time 300 \
    -o "$destination" "$url"
}

download_xray() {
  local release="$VERSION" url archive digest expected actual extract_dir

  if [[ "$release" == "latest" ]]; then
    release=$(fetch_latest_version || true)
  fi
  if [[ -n "$release" ]]; then
    release="v${release#v}"
    url="https://github.com/XTLS/Xray-core/releases/download/${release}/Xray-linux-${ARCH}.zip"
  else
    release="latest"
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
  fi

  archive="${TEMP_DIR}/xray.zip"
  digest="${archive}.dgst"
  extract_dir="${TEMP_DIR}/archive"
  info "下载 Xray ${release} (${ARCH})"

  download_file "$url" "$archive" || die "下载 Xray 失败: ${url}"
  download_file "${url}.dgst" "$digest" || die "下载 Xray 校验文件失败"
  [[ -s "$archive" && -s "$digest" ]] || die "下载文件为空"

  # 与 XTLS/Xray-install 官方脚本相同：从 .dgst 读取 SHA2-256。
  expected=$(awk -F '= ' '/256=/ {print tolower($2); exit}' "$digest")
  actual=$(sha256sum "$archive" | awk '{print tolower($1)}')
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "官方校验文件格式无效"
  [[ "$actual" == "$expected" ]] || die "Xray 压缩包 SHA-256 校验失败"
  info "SHA-256 校验通过"

  mkdir -p "$extract_dir" || die "无法创建解压目录"
  unzip -q "$archive" -d "$extract_dir" || die "解压 Xray 失败"
  STAGED_BIN="${extract_dir}/xray"
  [[ -f "$STAGED_BIN" ]] || die "压缩包中没有 xray"
  chmod 755 "$STAGED_BIN" || die "无法设置 Xray 可执行权限"
  "$STAGED_BIN" -version >/dev/null 2>&1 || die "下载的 Xray 无法执行"
  return 0
}

extract_private_key() {
  awk -F: 'tolower($1) ~ /private/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "$1"
}

extract_public_key() {
  awk -F: 'tolower($1) ~ /public|password/ && tolower($1) !~ /private/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "$1"
}

generate_credentials() {
  local keypair

  if [[ -z "$UUID" ]]; then
    UUID=$("$STAGED_BIN" uuid) || die "Xray 生成 UUID 失败"
  fi
  validate_uuid "$UUID"

  SHORT_ID=$(openssl rand -hex 8) || die "生成 short ID 失败"
  [[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || die "生成的 short ID 无效"

  keypair=$("$STAGED_BIN" x25519) || die "Xray 生成 REALITY 密钥失败"
  PRIVATE_KEY=$(extract_private_key "$keypair")
  PUBLIC_KEY=$(extract_public_key "$keypair")
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "无法解析 Xray x25519 输出"
  info "UUID、short ID 和 REALITY 密钥已生成"
  return 0
}

write_staged_files() {
  cat > "$STAGED_CONFIG" <<EOF || die "写入临时 Xray 配置失败"
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
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${DOMAIN}:443",
          "serverNames": ["${DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
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

  cat > "$STAGED_CLIENT" <<EOF || die "写入临时客户端配置失败"
{
  "fingerprint": "${FINGERPRINT}",
  "publicKey": "${PUBLIC_KEY}"
}
EOF

  cat > "$STAGED_SERVICE" <<EOF || die "写入临时 systemd 服务失败"
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=nobody
Group=${SERVICE_GROUP}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23
RestartSec=3s
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

  chmod 640 "$STAGED_CONFIG" || die "无法设置配置文件权限"
  chmod 600 "$STAGED_CLIENT" || die "无法设置客户端文件权限"
  chmod 644 "$STAGED_SERVICE" || die "无法设置服务文件权限"
  jq -e . "$STAGED_CONFIG" >/dev/null || die "生成的配置不是有效 JSON"
  "$STAGED_BIN" run -test -config "$STAGED_CONFIG" >/dev/null \
    || die "Xray 配置预检失败"
  info "Xray 配置预检通过"
  return 0
}

reset_snapshot() {
  HAD_BIN=0
  HAD_CONFIG=0
  HAD_CLIENT=0
  HAD_SERVICE=0
  WAS_ACTIVE=0
  WAS_ENABLED=0
  return 0
}

snapshot_existing_install() {
  local backup="${TEMP_DIR}/backup"
  reset_snapshot
  mkdir -p "$backup" || die "无法创建备份目录"

  if [[ -e "$XRAY_BIN" ]]; then
    cp -a "$XRAY_BIN" "${backup}/xray" || die "备份旧 Xray 失败"
    HAD_BIN=1
  fi
  if [[ -e "$CONFIG_FILE" ]]; then
    cp -a "$CONFIG_FILE" "${backup}/config.json" || die "备份旧配置失败"
    HAD_CONFIG=1
  fi
  if [[ -e "$CLIENT_FILE" ]]; then
    cp -a "$CLIENT_FILE" "${backup}/client.json" || die "备份客户端配置失败"
    HAD_CLIENT=1
  fi
  if [[ -e "$SERVICE_FILE" ]]; then
    cp -a "$SERVICE_FILE" "${backup}/xray.service" || die "备份服务文件失败"
    HAD_SERVICE=1
  fi
  if systemctl is-active --quiet xray 2>/dev/null; then
    WAS_ACTIVE=1
  fi
  if systemctl is-enabled --quiet xray 2>/dev/null; then
    WAS_ENABLED=1
  fi
  return 0
}

restore_file() {
  local destination="$1" backup_name="$2" existed="$3"
  if ((existed == 1)); then
    rm -f "$destination"
    cp -a "${TEMP_DIR}/backup/${backup_name}" "$destination"
  else
    rm -f "$destination"
  fi
  return 0
}

rollback_install() {
  ((TRANSACTION_ACTIVE == 1)) || return 0
  TRANSACTION_ACTIVE=0
  error "安装失败，正在恢复安装前状态..."

  systemctl stop xray >/dev/null 2>&1 || true
  restore_file "$XRAY_BIN" xray "$HAD_BIN"
  restore_file "$CONFIG_FILE" config.json "$HAD_CONFIG"
  restore_file "$CLIENT_FILE" client.json "$HAD_CLIENT"
  restore_file "$SERVICE_FILE" xray.service "$HAD_SERVICE"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if ((WAS_ENABLED == 1)); then
    systemctl enable xray >/dev/null 2>&1 || true
  else
    systemctl disable xray >/dev/null 2>&1 || true
  fi
  if ((WAS_ACTIVE == 1)); then
    systemctl start xray >/dev/null 2>&1 || true
  fi
  rmdir "$CONFIG_DIR" >/dev/null 2>&1 || true
  warn "回滚完成"
  return 0
}

on_exit() {
  local exit_code="$1"
  trap - EXIT
  set +u
  if ((exit_code != 0)); then
    rollback_install
  fi
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
  exit "$exit_code"
}

handle_signal() {
  printf '\n' >&2
  error "操作被中断"
  exit 130
}

install_staged_files() {
  snapshot_existing_install
  TRANSACTION_ACTIVE=1

  install -d -m 750 -o root -g "$SERVICE_GROUP" "$CONFIG_DIR" \
    || die "创建配置目录失败"
  install -m 755 -o root -g root "$STAGED_BIN" "$XRAY_BIN" \
    || die "安装 Xray 二进制失败"
  install -m 640 -o root -g "$SERVICE_GROUP" "$STAGED_CONFIG" "$CONFIG_FILE" \
    || die "安装 Xray 配置失败"
  install -m 600 -o root -g root "$STAGED_CLIENT" "$CLIENT_FILE" \
    || die "安装客户端配置失败"
  install -m 644 -o root -g root "$STAGED_SERVICE" "$SERVICE_FILE" \
    || die "安装 systemd 服务失败"

  systemctl daemon-reload || die "systemd daemon-reload 失败"
  systemctl enable xray >/dev/null 2>&1 || die "设置 Xray 开机启动失败"
  if ! systemctl restart xray; then
    journalctl -u xray -n 30 --no-pager 2>/dev/null || true
    die "Xray 服务启动失败"
  fi
  sleep 1
  if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 30 --no-pager 2>/dev/null || true
    die "Xray 服务未保持运行"
  fi

  TRANSACTION_ACTIVE=0
  info "Xray 服务已启动并设置为开机启动"
  return 0
}

validate_install_options() {
  validate_port "$PORT"
  validate_domain "$DOMAIN"
  validate_fingerprint "$FINGERPRINT"
  validate_version "$VERSION"
  return 0
}

is_installed() {
  if [[ -e "$XRAY_BIN" || -e "$CONFIG_FILE" || -e "$SERVICE_FILE" || -d "$LEGACY_DIR" ]]; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl cat xray >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

ask_yes_no() {
  local answer=""
  printf '%b' "${YELLOW}[?]${NC} $1 [y/N]: "
  read -r answer || true
  [[ "$answer" == [yY] ]]
}

confirm_overwrite() {
  local interactive="$1"
  if ! is_installed; then
    return 0
  fi

  warn "检测到已有 Xray 安装，继续会替换现有服务和配置"
  if ((FORCE == 1)); then
    return 0
  fi
  if ((interactive == 1)); then
    ask_yes_no "确认覆盖？"
    return $?
  fi
  die "已有安装；确认覆盖请添加 --force"
}

get_server_ip() {
  local endpoint ip
  for endpoint in 'https://api.ipify.org' 'https://ipv4.icanhazip.com'; do
    ip=$(curl -4 -fsSL --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null \
      | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^[0-9]{1,3}([.][0-9]{1,3}){3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  warn "无法获取公网 IPv4，请手动替换 YOUR_SERVER_IP"
  printf '%s\n' YOUR_SERVER_IP
  return 0
}

print_client_output() {
  local server="$1" port="$2" uuid="$3" domain="$4"
  local fingerprint="$5" public_key="$6" short_id="$7"
  local vless_url

  vless_url="vless://${uuid}@${server}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${short_id}&type=tcp#Xray-REALITY"

  printf '\n%b\n%s\n\n' "${BLUE}====== 客户端配置 (VLESS URL) ======${NC}" "$vless_url"
  printf '%b\n' "${BLUE}====== 客户端配置 (Mihomo) ======${NC}"
  cat <<EOF
proxies:
  - name: "Xray-REALITY"
    type: vless
    server: "${server}"
    port: ${port}
    uuid: "${uuid}"
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: "${domain}"
    client-fingerprint: "${fingerprint}"
    reality-opts:
      public-key: "${public_key}"
      short-id: "${short_id}"
EOF
  printf '\n'
  return 0
}

print_new_client_config() {
  local server
  server=$(get_server_ip)
  print_client_output "$server" "$PORT" "$UUID" "$DOMAIN" \
    "$FINGERPRINT" "$PUBLIC_KEY" "$SHORT_ID"
  return 0
}

derive_public_key() {
  local private_key="$1" output public_key
  [[ -x "$XRAY_BIN" && -n "$private_key" ]] || return 1
  output=$("$XRAY_BIN" x25519 -i "$private_key" 2>/dev/null) || return 1
  public_key=$(extract_public_key "$output")
  [[ -n "$public_key" ]] || return 1
  printf '%s\n' "$public_key"
  return 0
}

show_client_config() {
  local port uuid security domain private_key short_id fingerprint public_key server derived
  [[ -f "$CONFIG_FILE" ]] || die "配置文件不存在: ${CONFIG_FILE}"
  command -v jq >/dev/null 2>&1 || die "查看配置需要 jq"

  port=$(jq -r '.inbounds[0].port // empty' "$CONFIG_FILE")
  uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$CONFIG_FILE")
  security=$(jq -r '.inbounds[0].streamSettings.security // empty' "$CONFIG_FILE")
  [[ -n "$port" && -n "$uuid" && "$security" == "reality" ]] \
    || die "当前配置不是有效的 VLESS REALITY 配置"

  domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG_FILE")
  private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$CONFIG_FILE")
  short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$CONFIG_FILE")
  fingerprint="chrome"
  public_key=""
  if [[ -f "$CLIENT_FILE" ]]; then
    fingerprint=$(jq -r '.fingerprint // "chrome"' "$CLIENT_FILE")
    public_key=$(jq -r '.publicKey // empty' "$CLIENT_FILE")
  fi
  derived=$(derive_public_key "$private_key" || true)
  [[ -z "$derived" ]] || public_key="$derived"
  [[ -n "$domain" && -n "$short_id" && -n "$public_key" ]] \
    || die "REALITY 客户端参数不完整"

  server=$(get_server_ip)
  print_client_output "$server" "$port" "$uuid" "$domain" \
    "$fingerprint" "$public_key" "$short_id"
  return 0
}

install_reality() {
  validate_install_options
  require_supported_system
  install_dependencies
  determine_architecture
  make_temp_dir
  download_xray
  generate_credentials
  write_staged_files
  install_staged_files

  # 旧版本脚本使用 /root/xray；新安装成功后再清理，失败回滚不触碰它。
  if [[ -d "$LEGACY_DIR" ]]; then
    rm -rf "$LEGACY_DIR" || warn "无法清理旧目录: ${LEGACY_DIR}"
  fi
  print_new_client_config
  rm -rf "$TEMP_DIR"
  TEMP_DIR=""
  return 0
}

show_status() {
  local version="未知"
  if [[ -x "$XRAY_BIN" ]]; then
    version=$("$XRAY_BIN" -version 2>/dev/null | awk 'NR == 1 {print $2}')
  fi
  if systemctl is-active --quiet xray 2>/dev/null; then
    info "Xray 正在运行（版本: ${version}）"
    return 0
  fi
  warn "Xray 未运行（版本: ${version}）"
  systemctl status xray --no-pager -l 2>/dev/null || true
  return 1
}

uninstall_xray() {
  info "卸载 Xray"
  systemctl disable --now xray >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" || die "删除 systemd 服务失败"
  rm -f "$XRAY_BIN" || die "删除 Xray 二进制失败"
  rm -rf "$CONFIG_DIR" "$LEGACY_DIR" || die "删除 Xray 配置失败"
  systemctl daemon-reload || die "systemd daemon-reload 失败"
  systemctl reset-failed xray >/dev/null 2>&1 || true
  info "Xray 已卸载"
  return 0
}

interactive_install() {
  local input=""
  if ! confirm_overwrite 1; then
    warn "已取消"
    return 0
  fi

  printf '\n%b' "${YELLOW}[?]${NC} 监听端口 [${PORT}]: "
  read -r input || true
  PORT="${input:-$PORT}"
  validate_port "$PORT"

  input=""
  printf '%b' "${YELLOW}[?]${NC} 目标域名 [${DOMAIN}]: "
  read -r input || true
  DOMAIN="${input:-$DOMAIN}"
  validate_domain "$DOMAIN"

  printf '%s\n' "可用指纹: chrome, firefox, safari, ios, android, edge, 360, qq, random, randomized"
  input=""
  printf '%b' "${YELLOW}[?]${NC} 客户端指纹 [${FINGERPRINT}]: "
  read -r input || true
  FINGERPRINT="${input:-$FINGERPRINT}"
  validate_fingerprint "$FINGERPRINT"

  input=""
  printf '%b' "${YELLOW}[?]${NC} VLESS UUID [留空由 Xray 生成]: "
  read -r input || true
  UUID="$input"
  [[ -z "$UUID" ]] || validate_uuid "$UUID"

  install_reality
  return 0
}

menu_header() {
  printf '\n%b\n' "${BLUE} >> 操作菜单${NC}"
  printf '   %b\n' "${GREEN}1)${NC} 安装 / 重装"
  printf '   %b\n' "${GREEN}2)${NC} 卸载"
  printf '   %b\n' "${GREEN}3)${NC} 查看状态"
  printf '   %b\n' "${GREEN}4)${NC} 查看客户端配置"
  printf '   %b\n' "${GREEN}0)${NC} 退出"
  return 0
}

interactive_menu() {
  local choice=""
  [[ -t 0 ]] || die "没有交互终端；请使用 --install 或 --help"

  while true; do
    menu_header
    printf '\n%b' "${YELLOW}[?]${NC} 请选择 [0-4]: "
    read -r choice || return 0
    case "$choice" in
      1) interactive_install ;;
      2)
        if ask_yes_no "确认卸载？"; then
          uninstall_xray
        else
          warn "已取消"
        fi
        ;;
      3) show_status || true ;;
      4) show_client_config || true ;;
      0) info "再见"; return 0 ;;
      *) error "无效选择，请重新输入" ;;
    esac
  done
}

main() {
  parse_args "$@"
  if [[ "$ACTION" == "help" ]]; then
    show_help
    return 0
  fi

  require_supported_system
  case "$ACTION" in
    menu) interactive_menu ;;
    install)
      confirm_overwrite 0
      install_reality
      ;;
    uninstall) uninstall_xray ;;
    status)
      show_status
      return $?
      ;;
    show-config) show_client_config ;;
    *) die "内部错误: 未知操作 ${ACTION}" ;;
  esac
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap 'on_exit $?' EXIT
  trap handle_signal INT TERM
  main "$@"
fi

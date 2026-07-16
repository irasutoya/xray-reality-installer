#!/usr/bin/env bash
# Xray VLESS + Vision + REALITY 一键安装脚本

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
PORT="443"
DOMAIN="itunes.apple.com"
UUID=""
FINGERPRINT="chrome"
VERSION="latest"
ACTION="menu"
FORCE=false

PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
ARCH=""
TEMP_DIR=""
STAGED_BINARY=""
STAGED_CONFIG=""
STAGED_CLIENT=""
STAGED_SERVICE=""

BASE_DIR="/root/xray"
INSTALL_DIR="${BASE_DIR}/bin"
CONFIG_DIR="${BASE_DIR}/config"
XRAY_BIN="${INSTALL_DIR}/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLIENT_FILE="${CONFIG_DIR}/client.json"
SERVICE_FILE="/etc/systemd/system/xray.service"

INSTALL_IN_PROGRESS=false
HAD_BINARY=false
HAD_CONFIG=false
HAD_CLIENT=false
HAD_SERVICE=false
WAS_ACTIVE=false
WAS_ENABLED=false

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

log()   { printf '%b\n' "${GREEN}[+]${NC} $*"; }
warn()  { printf '%b\n' "${YELLOW}[*]${NC} $*" >&2; }
error() { printf '%b\n' "${RED}[!]${NC} $*" >&2; }
fail()  { error "$*"; exit 1; }

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
  -u, --uuid UUID          VLESS UUID（默认随机生成）
  -d, --domain DOMAIN      REALITY 目标域名（默认 ${DOMAIN}）
  -f, --fingerprint FP     客户端指纹（默认 ${FINGERPRINT}）
  -v, --version VERSION    指定 Xray 版本，例如 v26.3.27（默认 latest）
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
    fail "一次只能执行一个操作（当前: ${ACTION}，请求: ${requested}）"
  fi
  ACTION="$requested"
}

require_value() {
  local option="$1" value="${2:-}"
  [[ -n "$value" ]] || fail "${option} 需要一个值"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || fail "端口必须是 1-65535 之间的数字"
  port=$((10#$port))
  ((port >= 1 && port <= 65535)) || fail "端口必须是 1-65535 之间的数字"
}

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] \
    || fail "UUID 格式无效"
}

validate_domain() {
  local domain="$1" label rest
  [[ ${#domain} -le 253 && "$domain" == *.* ]] || fail "域名格式无效: ${domain}"
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || fail "域名只能包含字母、数字、点和连字符"
  rest="$domain"
  while [[ "$rest" == *.* ]]; do
    label="${rest%%.*}"
    rest="${rest#*.}"
    [[ -n "$label" && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] \
      || fail "域名标签格式无效: ${domain}"
  done
  [[ -n "$rest" && ${#rest} -le 63 && "$rest" != -* && "$rest" != *- ]] \
    || fail "域名标签格式无效: ${domain}"
}

validate_fingerprint() {
  case "$1" in
    chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) ;;
    *) fail "不支持的客户端指纹: $1" ;;
  esac
}

validate_version() {
  [[ "$1" == "latest" || "$1" =~ ^v?[0-9]+([.][0-9]+){1,2}([.-][0-9A-Za-z]+)*$ ]] \
    || fail "Xray 版本格式无效: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
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
        FORCE=true
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
        [[ $# -eq 0 ]] || fail "不支持位置参数: $*"
        ;;
      *)
        fail "未知参数: $1（使用 --help 查看帮助）"
        ;;
    esac
  done
}

require_supported_system() {
  [[ "$(uname -s)" == "Linux" ]] || fail "仅支持 Linux 系统"
  [[ "${EUID}" -eq 0 ]] || fail "请使用 root 用户运行此脚本"
  command -v systemctl >/dev/null 2>&1 || fail "系统未安装 systemd/systemctl"
  if [[ ! -d /run/systemd/system && ! -d /.dockerenv ]]; then
    fail "当前系统似乎未使用 systemd"
  fi
}

add_unique_package() {
  local candidate="$1" item
  for item in "${PACKAGES[@]:-}"; do
    [[ "$item" == "$candidate" ]] && return
  done
  PACKAGES+=("$candidate")
}

install_dependencies() {
  local command_name package_name
  local required=(curl jq unzip sha256sum install openssl)
  PACKAGES=()

  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 && continue
    case "$command_name" in
      sha256sum|install) package_name="coreutils" ;;
      *) package_name="$command_name" ;;
    esac
    add_unique_package "$package_name"
  done

  if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    log "系统依赖已满足"
    return
  fi

  log "安装缺少的依赖: ${PACKAGES[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${PACKAGES[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "${PACKAGES[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "${PACKAGES[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install -y "${PACKAGES[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed "${PACKAGES[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${PACKAGES[@]}"
  else
    fail "找不到受支持的包管理器，请手动安装: ${PACKAGES[*]}"
  fi

  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || fail "依赖安装后仍找不到命令: ${command_name}"
  done
}

generate_uuid() {
  local hex
  [[ -n "$UUID" ]] && return
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    UUID=$(< /proc/sys/kernel/random/uuid)
  elif command -v uuidgen >/dev/null 2>&1; then
    UUID=$(uuidgen)
  elif [[ -n "$STAGED_BINARY" && -x "$STAGED_BINARY" ]]; then
    UUID=$("$STAGED_BINARY" uuid)
  elif command -v openssl >/dev/null 2>&1; then
    hex=$(openssl rand -hex 16)
    UUID="${hex:0:8}-${hex:8:4}-4${hex:13:3}-8${hex:17:3}-${hex:20:12}"
  else
    fail "无法生成 UUID，请使用 --uuid 手动指定"
  fi
  validate_uuid "$UUID"
}

generate_short_id() {
  SHORT_ID=$(openssl rand -hex 8) || fail "生成 REALITY short ID 失败"
  [[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || fail "生成的 REALITY short ID 无效"
}

map_architecture() {
  case "$1" in
    i386|i686)          printf '%s\n' "32" ;;
    amd64|x86_64)      printf '%s\n' "64" ;;
    armv5tel)          printf '%s\n' "arm32-v5" ;;
    armv6l)            printf '%s\n' "arm32-v6" ;;
    armv7|armv7l)      printf '%s\n' "arm32-v7a" ;;
    armv8|aarch64)     printf '%s\n' "arm64-v8a" ;;
    mips)              printf '%s\n' "mips32" ;;
    mipsle)            printf '%s\n' "mips32le" ;;
    mips64|mips64le)   printf '%s\n' "$1" ;;
    ppc64|ppc64le)     printf '%s\n' "$1" ;;
    riscv64|s390x)     printf '%s\n' "$1" ;;
    *)                 return 1 ;;
  esac
}

determine_architecture() {
  local machine
  machine=$(uname -m)
  ARCH=$(map_architecture "$machine") || fail "不支持的系统架构: ${machine}"
  if [[ "$machine" == "mips64" ]] && command -v lscpu >/dev/null 2>&1 \
    && lscpu | grep -qi 'little endian'; then
    ARCH="mips64le"
  fi
  log "系统架构: ${machine} -> ${ARCH}"
}

fetch_latest_version() {
  local version
  version=$(curl -fsSL --connect-timeout 10 --max-time 20 \
    -H 'Accept: application/vnd.github+json' \
    'https://api.github.com/repos/XTLS/Xray-core/releases/latest' 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null || true)
  printf '%s\n' "$version"
}

download_file() {
  local url="$1" destination="$2"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 \
    -o "$destination" "$url"
}

download_xray() {
  local release="$VERSION" base_url archive digest expected actual extract_dir
  [[ "$release" == "latest" ]] && release=$(fetch_latest_version)

  if [[ -n "$release" ]]; then
    release="v${release#v}"
    base_url="https://github.com/XTLS/Xray-core/releases/download/${release}/Xray-linux-${ARCH}.zip"
  else
    warn "无法读取最新版本号，改用 GitHub latest 下载地址"
    base_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
  fi

  archive="${TEMP_DIR}/xray.zip"
  digest="${archive}.dgst"
  extract_dir="${TEMP_DIR}/archive"
  log "下载 Xray ${release:-latest} (${ARCH})"
  download_file "$base_url" "$archive" || fail "下载 Xray 失败: ${base_url}"
  download_file "${base_url}.dgst" "$digest" || fail "下载校验文件失败"
  [[ -s "$archive" && -s "$digest" ]] || fail "下载文件为空"

  expected=$(awk -F '= ' 'tolower($1) ~ /sha2-256|sha256/ {print tolower($2); exit}' "$digest")
  actual=$(sha256sum "$archive" | awk '{print tolower($1)}')
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "无法从官方校验文件读取 SHA-256"
  [[ "$actual" == "$expected" ]] || fail "Xray 压缩包 SHA-256 校验失败"
  log "下载文件 SHA-256 校验通过"

  mkdir -p "$extract_dir"
  unzip -q "$archive" -d "$extract_dir" || fail "解压 Xray 失败"
  STAGED_BINARY="${extract_dir}/xray"
  [[ -f "$STAGED_BINARY" ]] || fail "压缩包中未找到 xray 可执行文件"
  chmod 755 "$STAGED_BINARY"
  "$STAGED_BINARY" -version >/dev/null 2>&1 || fail "下载的 Xray 无法执行"
}

extract_private_key() {
  awk -F: 'tolower($1) ~ /private/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "$1"
}

extract_public_key() {
  awk -F: 'tolower($1) ~ /public|password/ && tolower($1) !~ /private/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "$1"
}

generate_reality_keypair() {
  local keypair
  log "生成 REALITY 密钥对"
  keypair=$("$STAGED_BINARY" x25519) || fail "生成 REALITY 密钥对失败"
  PRIVATE_KEY=$(extract_private_key "$keypair")
  PUBLIC_KEY=$(extract_public_key "$keypair")
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || fail "无法解析 Xray 输出的 REALITY 密钥对"
}

warn_reality_target() {
  warn "REALITY 目标域名应优先选择与本机同 ASN、支持 TLS 1.3 的站点；当前: ${DOMAIN}"
}

create_staged_config() {
  STAGED_CONFIG="${TEMP_DIR}/config.json"
  STAGED_CLIENT="${TEMP_DIR}/client.json"
  STAGED_SERVICE="${TEMP_DIR}/xray.service"

  cat > "$STAGED_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "::",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
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
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF

  cat > "$STAGED_CLIENT" <<EOF
{
  "fingerprint": "${FINGERPRINT}",
  "publicKey": "${PUBLIC_KEY}"
}
EOF

  cat > "$STAGED_SERVICE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  chmod 600 "$STAGED_CONFIG" "$STAGED_CLIENT"
  chmod 644 "$STAGED_SERVICE"
  jq -e . "$STAGED_CONFIG" >/dev/null || fail "生成的 Xray 配置不是有效 JSON"
  "$STAGED_BINARY" run -test -config "$STAGED_CONFIG" >/dev/null \
    || fail "Xray 拒绝生成的配置，未修改现有安装"
  log "Xray 配置预检通过"
}

backup_one() {
  local source="$1" name="$2" flag_name="$3"
  if [[ -e "$source" ]]; then
    cp -p "$source" "${TEMP_DIR}/backup/${name}"
    printf -v "$flag_name" '%s' true
  fi
}

backup_existing_install() {
  mkdir -p "${TEMP_DIR}/backup"
  backup_one "$XRAY_BIN" xray HAD_BINARY
  backup_one "$CONFIG_FILE" config.json HAD_CONFIG
  backup_one "$CLIENT_FILE" client.json HAD_CLIENT
  backup_one "$SERVICE_FILE" xray.service HAD_SERVICE
  systemctl is-active --quiet xray 2>/dev/null && WAS_ACTIVE=true
  systemctl is-enabled --quiet xray 2>/dev/null && WAS_ENABLED=true
}

restore_one() {
  local destination="$1" name="$2" existed="$3"
  if [[ "$existed" == true ]]; then
    mkdir -p "${destination%/*}"
    cp -p "${TEMP_DIR}/backup/${name}" "$destination"
  else
    rm -f "$destination"
  fi
}

rollback_install() {
  [[ "$INSTALL_IN_PROGRESS" == true ]] || return
  INSTALL_IN_PROGRESS=false
  error "安装失败，正在恢复原有版本..."
  systemctl stop xray >/dev/null 2>&1 || true
  restore_one "$XRAY_BIN" xray "$HAD_BINARY"
  restore_one "$CONFIG_FILE" config.json "$HAD_CONFIG"
  restore_one "$CLIENT_FILE" client.json "$HAD_CLIENT"
  restore_one "$SERVICE_FILE" xray.service "$HAD_SERVICE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ "$WAS_ENABLED" == true ]]; then
    systemctl enable xray >/dev/null 2>&1 || true
  else
    systemctl disable xray >/dev/null 2>&1 || true
  fi
  [[ "$WAS_ACTIVE" == true ]] && systemctl start xray >/dev/null 2>&1 || true
  rmdir "$CONFIG_DIR" "$INSTALL_DIR" "$BASE_DIR" >/dev/null 2>&1 || true
  warn "已完成回滚"
}

cleanup() {
  local status="$1"
  set +e
  [[ "$status" -ne 0 ]] && rollback_install
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  return "$status"
}

handle_interrupt() {
  printf '\n' >&2
  warn "操作被中断"
  exit 130
}

apply_staged_install() {
  backup_existing_install
  INSTALL_IN_PROGRESS=true

  install -d -m 700 "$BASE_DIR" "$INSTALL_DIR" "$CONFIG_DIR"
  install -m 755 "$STAGED_BINARY" "$XRAY_BIN"
  install -m 600 "$STAGED_CONFIG" "$CONFIG_FILE"
  install -m 600 "$STAGED_CLIENT" "$CLIENT_FILE"
  install -m 644 "$STAGED_SERVICE" "$SERVICE_FILE"

  systemctl daemon-reload || fail "systemd daemon-reload 失败"
  systemctl enable xray >/dev/null || fail "设置 Xray 开机启动失败"
  if ! systemctl restart xray; then
    journalctl -u xray -n 30 --no-pager 2>/dev/null || true
    fail "Xray 服务启动失败"
  fi

  local attempt
  for attempt in 1 2 3 4 5; do
    systemctl is-active --quiet xray && break
    sleep 1
  done
  if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 30 --no-pager 2>/dev/null || true
    fail "Xray 服务未能保持运行"
  fi

  INSTALL_IN_PROGRESS=false
  log "Xray 服务已启动并设置为开机启动"
}

prepare_install_values() {
  [[ -n "$PORT" ]] || PORT=443
  validate_port "$PORT"
  validate_version "$VERSION"
  validate_domain "$DOMAIN"
  validate_fingerprint "$FINGERPRINT"
  warn_reality_target
}

is_installed() {
  [[ -e "$XRAY_BIN" || -e "$CONFIG_FILE" || -e "$SERVICE_FILE" ]] && return 0
  command -v systemctl >/dev/null 2>&1 && systemctl cat xray >/dev/null 2>&1
}

ask_yes_no() {
  local prompt="$1" answer=""
  printf '%b' "${YELLOW}[?]${NC} ${prompt} [y/N]: "
  read -r answer || true
  [[ "$answer" == [yY] ]]
}

ensure_overwrite_allowed() {
  local interactive="$1"
  is_installed || return
  warn "检测到已有 Xray 安装，继续会替换二进制和配置"
  [[ "$FORCE" == true ]] && return
  if [[ "$interactive" == true ]]; then
    ask_yes_no "确认覆盖？" || { warn "已取消"; return 1; }
  else
    fail "已有安装；确认覆盖请加 --force"
  fi
}

perform_install() {
  local interactive="$1"
  ensure_overwrite_allowed "$interactive" || return
  prepare_install_values
  require_supported_system
  install_dependencies
  determine_architecture
  HAD_BINARY=false
  HAD_CONFIG=false
  HAD_CLIENT=false
  HAD_SERVICE=false
  WAS_ACTIVE=false
  WAS_ENABLED=false
  TEMP_DIR=$(mktemp -d) || fail "无法创建临时目录"
  download_xray
  generate_uuid
  generate_short_id
  generate_reality_keypair
  create_staged_config
  apply_staged_install
  log "Xray 安装完成：${BASE_DIR}"
  print_client_config
  rm -rf "$TEMP_DIR"
  TEMP_DIR=""
}

get_server_ip() {
  local endpoint ip
  for endpoint in 'https://api.ipify.org' 'https://ipv4.icanhazip.com'; do
    ip=$(curl -4 -fsSL --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null \
      | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^[0-9]{1,3}([.][0-9]{1,3}){3}$ ]]; then
      printf '%s\n' "$ip"
      return
    fi
  done
  warn "无法获取公网 IPv4，请把输出中的 YOUR_SERVER_IP 替换为服务器地址"
  printf '%s\n' "YOUR_SERVER_IP"
}

print_client_output() {
  local server="$1" port="$2" uuid="$3" domain="$4"
  local fingerprint="$5" public_key="$6" short_id="$7"
  local uri_host="$server" vless_url
  [[ "$server" == *:* ]] && uri_host="[${server}]"

  vless_url="vless://${uuid}@${uri_host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${short_id}&type=tcp#Xray-REALITY"
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
}

print_client_config() {
  local server_ip
  server_ip=$(get_server_ip)
  print_client_output "$server_ip" "$PORT" "$UUID" "$DOMAIN" \
    "$FINGERPRINT" "$PUBLIC_KEY" "$SHORT_ID"
}

derive_public_key() {
  local private_key="$1" output
  [[ -n "$private_key" && -x "$XRAY_BIN" ]] || return 1
  output=$("$XRAY_BIN" x25519 -i "$private_key" 2>/dev/null) || return 1
  output=$(extract_public_key "$output")
  [[ -n "$output" ]] || return 1
  printf '%s\n' "$output"
}

show_config() {
  [[ -f "$CONFIG_FILE" ]] || fail "配置文件不存在: ${CONFIG_FILE}"
  command -v jq >/dev/null 2>&1 || fail "读取配置需要 jq"

  local port uuid security server_ip
  port=$(jq -r '.inbounds[0].port // empty' "$CONFIG_FILE")
  uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$CONFIG_FILE")
  security=$(jq -r '.inbounds[0].streamSettings.security // "none"' "$CONFIG_FILE")
  [[ -n "$port" && -n "$uuid" ]] || fail "无法读取 Xray 入站配置"
  server_ip=$(get_server_ip)

  if [[ "$security" == "reality" ]]; then
    local domain private_key short_id fingerprint public_key derived_key
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG_FILE")
    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$CONFIG_FILE")
    short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$CONFIG_FILE")
    fingerprint="chrome"
    if [[ -f "$CLIENT_FILE" ]]; then
      fingerprint=$(jq -r '.fingerprint // "chrome"' "$CLIENT_FILE")
      public_key=$(jq -r '.publicKey // empty' "$CLIENT_FILE")
    fi
    derived_key=$(derive_public_key "$private_key" || true)
    [[ -z "$derived_key" ]] || public_key="$derived_key"
    [[ -n "$domain" && -n "$short_id" && -n "$public_key" ]] || fail "REALITY 客户端参数不完整"
    print_client_output "$server_ip" "$port" "$uuid" \
      "$domain" "$fingerprint" "$public_key" "$short_id"
  else
    fail "当前配置不是 REALITY (security=${security})"
  fi
}

show_status() {
  if [[ ! -f "$SERVICE_FILE" ]]; then
    warn "Xray 未安装"
    return 1
  fi

  local version="未知"
  [[ -x "$XRAY_BIN" ]] && version=$("$XRAY_BIN" -version 2>/dev/null | awk 'NR == 1 {print $2}')
  if systemctl is-active --quiet xray 2>/dev/null; then
    log "Xray 正在运行（版本: ${version}）"
  else
    warn "Xray 未运行（版本: ${version}）"
    systemctl status xray --no-pager -l 2>/dev/null || true
    return 1
  fi
}

uninstall() {
  log "卸载 Xray"
  systemctl disable --now xray >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl reset-failed xray >/dev/null 2>&1 || true
  rm -rf "$BASE_DIR"
  log "Xray 已卸载"
}

interactive_install() {
  local input=""
  ensure_overwrite_allowed true || return

  printf '\n%b' "${YELLOW}[?]${NC} 监听端口 [443]: "
  read -r input || true
  PORT="${input:-443}"
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
  printf '%b' "${YELLOW}[?]${NC} VLESS UUID [留空自动生成]: "
  read -r input || true
  UUID="$input"
  [[ -z "$UUID" ]] || validate_uuid "$UUID"

  # 已在本函数确认过覆盖，避免 perform_install 二次询问。
  FORCE=true
  perform_install true
  FORCE=false
}

menu_header() {
  printf '\n%b\n' "${BLUE} >> 操作菜单${NC}"
  printf '   %b\n' "${GREEN}1)${NC} 安装 / 重装"
  printf '   %b\n' "${GREEN}2)${NC} 卸载"
  printf '   %b\n' "${GREEN}3)${NC} 查看状态"
  printf '   %b\n' "${GREEN}4)${NC} 查看客户端配置"
  printf '   %b\n' "${GREEN}0)${NC} 退出"
}

interactive_menu() {
  [[ -t 0 ]] || fail "没有可用的交互终端；请使用 --install 或 --help"
  local choice=""
  while true; do
    menu_header
    printf '\n%b' "${YELLOW}[?]${NC} 请选择 [0-4]: "
    choice=""
    read -r choice || return
    case "$choice" in
      1) interactive_install ;;
      2)
        if ask_yes_no "确认卸载？"; then uninstall; else warn "已取消"; fi
        ;;
      3) show_status || true ;;
      4) show_config || true ;;
      0) log "再见"; return ;;
      *) error "无效选择，请重新输入" ;;
    esac
  done
}

main() {
  parse_args "$@"
  [[ "$ACTION" == "help" ]] && { show_help; return; }
  require_supported_system

  case "$ACTION" in
    menu) interactive_menu ;;
    install) perform_install false ;;
    uninstall) uninstall ;;
    status) show_status ;;
    show-config) show_config ;;
    *) fail "内部错误: 未知操作 ${ACTION}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap 'cleanup $?' EXIT
  trap handle_interrupt INT TERM
  main "$@"
fi

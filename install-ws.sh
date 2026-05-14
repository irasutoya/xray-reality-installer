#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
BASE_DIR="${BASE_DIR:-/root/xray}"
XRAY_USER="${XRAY_USER:-root}"
INSTALL_PATH="${INSTALL_PATH:-${BASE_DIR}/bin/xray}"
CONFIG_DIR="${CONFIG_DIR:-${BASE_DIR}/config}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.json}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/xray.service}"
STATE_DIR="${STATE_DIR:-${BASE_DIR}/state}"

PORT="${PORT:-80}"
UUID="${UUID:-}"
VERSION="${VERSION:-latest}"
WS_PATH="${WS_PATH:-/}"
WS_HOST="${WS_HOST:-}"
UNINSTALL=false
NO_START=false

TMP_DIR=""

GREEN=$'\033[1;32m'
RED=$'\033[1;31m'
BLUE=$'\033[1;34m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log() { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*"; }
die() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
${BLUE}Xray VLESS + WebSocket installer${NC}

Usage:
  ${SCRIPT_NAME} [options]

Options:
  -port <1-65535>          Listen port. Default: 80
  -uuid <uuid>             VLESS UUID. Default: generated
  -version <tag|latest>    Xray release tag, for example v25.4.30. Default: latest
  -path <path>             WebSocket path. Default: /
  -host <domain|ip>        WebSocket Host header in client output. Default: server IP
  -no-start                Install and validate config without starting systemd service
  -uninstall               Stop service and remove installed files
  -help                    Show this help

Examples:
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} -port 80 -path /ws
USAGE
}

cleanup() {
  local code=$?
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
  if [[ ${code} -ne 0 ]]; then
    warn "Aborted. Temporary files have been removed."
  fi
  exit "${code}"
}
trap cleanup EXIT INT TERM

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run this script as root."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "Port must be numeric: $1"
  (( "$1" >= 1 && "$1" <= 65535 )) || die "Port must be in range 1-65535: $1"
}

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] \
    || die "Invalid UUID: $1"
}

validate_ws_path() {
  [[ "$1" == /* ]] || die "WebSocket path must start with /: $1"
  [[ "$1" =~ ^/[A-Za-z0-9._~:@/-]*$ ]] || die "Invalid WebSocket path: $1"
}

validate_host() {
  [[ -z "$1" || "$1" =~ ^[A-Za-z0-9.-]+$ || "$1" =~ ^[0-9a-fA-F:.]+$ ]] || die "Invalid Host value: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -port)
        [[ $# -ge 2 ]] || die "-port requires a value."
        PORT="$2"
        shift 2
        ;;
      -uuid)
        [[ $# -ge 2 ]] || die "-uuid requires a value."
        UUID="$2"
        shift 2
        ;;
      -version)
        [[ $# -ge 2 ]] || die "-version requires a value."
        VERSION="$2"
        shift 2
        ;;
      -path)
        [[ $# -ge 2 ]] || die "-path requires a value."
        WS_PATH="$2"
        shift 2
        ;;
      -host)
        [[ $# -ge 2 ]] || die "-host requires a value."
        WS_HOST="$2"
        shift 2
        ;;
      -no-start)
        NO_START=true
        shift
        ;;
      -uninstall)
        UNINSTALL=true
        shift
        ;;
      -help|--help|-h)
        usage
        exit 0
        ;;
      *)
        usage
        die "Unknown option: $1"
        ;;
    esac
  done
}

validate_args() {
  validate_port "${PORT}"
  validate_ws_path "${WS_PATH}"
  validate_host "${WS_HOST}"
  if [[ -n "${UUID}" ]]; then
    validate_uuid "${UUID}"
  fi
}

install_dependencies() {
  local deps=(curl unzip openssl ca-certificates)
  log "Installing dependencies..."

  if command_exists apt-get; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${deps[@]}"
  elif command_exists dnf; then
    dnf install -y -q "${deps[@]}"
  elif command_exists yum; then
    yum install -y -q "${deps[@]}"
  else
    die "Unsupported package manager. Install manually: ${deps[*]}"
  fi

  for dep in curl unzip openssl; do
    command_exists "${dep}" || die "Missing dependency after install: ${dep}"
  done
}

generate_uuid() {
  if [[ -n "${UUID}" ]]; then
    return
  fi

  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
  elif command_exists uuidgen; then
    UUID="$(uuidgen)"
  else
    local raw
    raw="$(openssl rand -hex 16)"
    UUID="${raw:0:8}-${raw:8:4}-4${raw:13:3}-8${raw:17:3}-${raw:20:12}"
  fi
}

detect_arch() {
  local machine arch
  machine="$(uname -m)"

  case "${machine}" in
    x86_64|amd64) arch="64" ;;
    aarch64|arm64) arch="arm64-v8a" ;;
    armv7l|armv7) arch="arm32-v7a" ;;
    armv6l|armv6) arch="arm32-v6" ;;
    i386|i686) arch="32" ;;
    mips64le) arch="mips64le" ;;
    mipsle) arch="mipsle" ;;
    *) die "Unsupported architecture: ${machine}" ;;
  esac

  printf '%s' "${arch}"
}

release_base_url() {
  local arch="$1"
  if [[ "${VERSION}" == "latest" ]]; then
    printf 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-%s.zip' "${arch}"
  else
    printf 'https://github.com/XTLS/Xray-core/releases/download/%s/Xray-linux-%s.zip' "${VERSION}" "${arch}"
  fi
}

download_file() {
  local url="$1"
  local dest="$2"
  curl -fL --retry 3 --connect-timeout 10 --max-time 300 -o "${dest}" "${url}"
}

verify_checksum_if_available() {
  local zip_file="$1"
  local digest_file="$2"

  [[ -s "${digest_file}" ]] || {
    warn "Checksum file was not available; skipping checksum verification."
    return
  }

  local expected actual
  expected="$(grep -Eio '[a-f0-9]{64}' "${digest_file}" | head -n 1 || true)"
  [[ -n "${expected}" ]] || {
    warn "Checksum file did not contain a SHA-256 value; skipping checksum verification."
    return
  }

  actual="$(openssl dgst -sha256 "${zip_file}" | awk '{print $NF}')"
  [[ "${actual}" == "${expected}" ]] || die "Checksum verification failed."
  log "Checksum verification passed."
}

install_xray() {
  local arch zip_url zip_file digest_file extract_dir
  arch="$(detect_arch)"
  TMP_DIR="$(mktemp -d)"
  zip_url="$(release_base_url "${arch}")"
  zip_file="${TMP_DIR}/xray.zip"
  digest_file="${TMP_DIR}/xray.zip.dgst"
  extract_dir="${TMP_DIR}/extract"

  log "Downloading Xray (${VERSION}, linux-${arch})..."
  download_file "${zip_url}" "${zip_file}" || die "Failed to download Xray from ${zip_url}"

  if download_file "${zip_url}.dgst" "${digest_file}" >/dev/null 2>&1; then
    verify_checksum_if_available "${zip_file}" "${digest_file}"
  else
    warn "Could not download checksum asset; continuing without checksum verification."
  fi

  mkdir -p "${extract_dir}"
  unzip -q "${zip_file}" -d "${extract_dir}"
  [[ -x "${extract_dir}/xray" || -f "${extract_dir}/xray" ]] || die "Downloaded archive does not contain xray binary."

  install -d -m 0750 "$(dirname "${INSTALL_PATH}")"
  install -m 0755 "${extract_dir}/xray" "${INSTALL_PATH}"
  log "Installed Xray to ${INSTALL_PATH}"
}

write_config() {
  log "Writing Xray config..."
  install -d -m 0750 -o "${XRAY_USER}" -g "${XRAY_USER}" "${CONFIG_DIR}"
  install -d -m 0750 -o "${XRAY_USER}" -g "${XRAY_USER}" "${STATE_DIR}"

  umask 027
  cat > "${CONFIG_FILE}" <<JSON
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
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
          "path": "${WS_PATH}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
JSON

  chown "${XRAY_USER}:${XRAY_USER}" "${CONFIG_FILE}"
  chmod 0640 "${CONFIG_FILE}"
}

write_service() {
  log "Writing systemd service..."
  cat > "${SERVICE_FILE}" <<SERVICE
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${XRAY_USER}
Group=${XRAY_USER}
ExecStart=${INSTALL_PATH} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${STATE_DIR}
ReadOnlyPaths=${CONFIG_DIR} ${INSTALL_PATH}
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
SERVICE

  chmod 0644 "${SERVICE_FILE}"
  systemctl daemon-reload
}

validate_xray_config() {
  log "Validating Xray config..."
  "${INSTALL_PATH}" run -test -c "${CONFIG_FILE}" >/dev/null
}

start_service() {
  if [[ "${NO_START}" == true ]]; then
    warn "Skipping service start because -no-start was set."
    return
  fi

  log "Starting Xray service..."
  systemctl enable --now xray
  systemctl is-active --quiet xray || die "Xray failed to start. Check: journalctl -u xray -e --no-pager"
}

public_ip() {
  local ip
  ip="$(curl -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org || true)"
  [[ -n "${ip}" ]] || ip="SERVER_IP"
  printf '%s' "${ip}"
}

print_client_config() {
  local server_ip ws_host tag encoded_path vless_url
  server_ip="$(public_ip)"
  ws_host="${WS_HOST:-${server_ip}}"
  tag="xray-ws-${server_ip}"
  encoded_path="${WS_PATH//\//%2F}"
  vless_url="vless://${UUID}@${server_ip}:${PORT}?type=ws&security=none&path=${encoded_path}&host=${ws_host}#${tag}"

  cat <<OUTPUT

${BLUE}====== VLESS URL ======${NC}
${vless_url}

${BLUE}====== Mihomo / Clash Meta ======${NC}
proxies:
  - name: ${tag}
    server: ${server_ip}
    port: ${PORT}
    type: vless
    uuid: ${UUID}
    tls: false
    udp: true
    network: ws
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${ws_host}

${BLUE}====== Server files ======${NC}
Binary:  ${INSTALL_PATH}
Config:  ${CONFIG_FILE}
State:   ${STATE_DIR}
Service: ${SERVICE_FILE}
OUTPUT
}

uninstall() {
  log "Stopping and removing Xray..."
  systemctl disable --now xray >/dev/null 2>&1 || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "${BASE_DIR}"
  log "Uninstall complete."
}

main() {
  parse_args "$@"
  require_root

  if [[ "${UNINSTALL}" == true ]]; then
    uninstall
    return
  fi

  validate_args
  install_dependencies
  generate_uuid
  validate_uuid "${UUID}"
  install_xray
  write_config
  write_service
  validate_xray_config
  start_service
  print_client_config
}

main "$@"

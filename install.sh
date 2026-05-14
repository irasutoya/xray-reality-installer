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

PORT="${PORT:-443}"
UUID="${UUID:-}"
VERSION="${VERSION:-latest}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-aod.itunes.apple.com}"
REALITY_TARGET="${REALITY_TARGET:-${REALITY_SERVER_NAME}:443}"
CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT:-chrome}"
SHORT_ID="${SHORT_ID:-}"
PRIVATE_KEY=""
PUBLIC_KEY=""
UNINSTALL=false
NO_START=false
TARGET_SET=false

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
${BLUE}Xray VLESS + Vision + REALITY installer${NC}

Usage:
  ${SCRIPT_NAME} [options]

Options:
  -port <1-65535>          Listen port. Default: 443
  -uuid <uuid>             VLESS UUID. Default: generated
  -version <tag|latest>    Xray release tag, for example v25.4.30. Default: latest
  -server-name <domain>    REALITY SNI/serverName. Default: ${REALITY_SERVER_NAME}
  -target <host:port>      REALITY target. Default: ${REALITY_TARGET}
  -fingerprint <name>      uTLS client fingerprint. Default: chrome
  -short-id <hex>          REALITY shortId, even-length hex up to 16 chars. Default: random
  -no-start                Install and validate config without starting systemd service
  -uninstall               Stop service and remove installed files
  -help                    Show this help

Examples:
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} -server-name aod.itunes.apple.com -target aod.itunes.apple.com:443
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

validate_domain() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid server name: $1"
  [[ "$1" == *.* ]] || die "Server name should be a domain name: $1"
}

validate_target() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "Target must be host:port: $1"
  local target_port="${1##*:}"
  validate_port "${target_port}"
}

validate_fingerprint() {
  case "$1" in
    chrome|firefox|safari|ios|android|edge|360|qq|random|randomized|randomizedalpn) ;;
    *) die "Unsupported client fingerprint: $1" ;;
  esac
}

validate_short_id() {
  [[ "$1" =~ ^([0-9a-fA-F]{2}){0,8}$ ]] || die "shortId must be even-length hex, max 16 chars."
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
      -server-name)
        [[ $# -ge 2 ]] || die "-server-name requires a value."
        REALITY_SERVER_NAME="$2"
        if [[ "${TARGET_SET}" == false ]]; then
          REALITY_TARGET="${REALITY_SERVER_NAME}:443"
        fi
        shift 2
        ;;
      -target)
        [[ $# -ge 2 ]] || die "-target requires a value."
        REALITY_TARGET="$2"
        TARGET_SET=true
        shift 2
        ;;
      -fingerprint)
        [[ $# -ge 2 ]] || die "-fingerprint requires a value."
        CLIENT_FINGERPRINT="$2"
        shift 2
        ;;
      -short-id)
        [[ $# -ge 2 ]] || die "-short-id requires a value."
        SHORT_ID="$2"
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
  validate_domain "${REALITY_SERVER_NAME}"
  validate_target "${REALITY_TARGET}"
  validate_fingerprint "${CLIENT_FINGERPRINT}"
  if [[ -n "${UUID}" ]]; then
    validate_uuid "${UUID}"
  fi
  if [[ -n "${SHORT_ID}" ]]; then
    validate_short_id "${SHORT_ID}"
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

generate_short_id() {
  if [[ -z "${SHORT_ID}" ]]; then
    SHORT_ID="$(openssl rand -hex 8)"
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
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 -o "${dest}" "${url}"
}

mirror_url() {
  local prefix="$1"
  local url="$2"

  if [[ -z "${prefix}" ]]; then
    printf '%s' "${url}"
  elif [[ "${prefix}" == *"{url}"* ]]; then
    printf '%s' "${prefix/\{url\}/${url}}"
  else
    printf '%s/%s' "${prefix%/}" "${url}"
  fi
}

download_with_mirrors() {
  local url="$1"
  local dest="$2"
  local label="$3"
  local prefixes=()
  local prefix candidate

  if [[ -n "${XRAY_DOWNLOAD_PREFIX:-}" ]]; then
    prefixes+=("${XRAY_DOWNLOAD_PREFIX}")
  fi

  prefixes+=(
    ""
    "https://ghfast.top/"
    "https://gh.llkk.cc/"
    "https://gh-proxy.com/"
    "https://hub.gitmirror.com/"
  )

  for prefix in "${prefixes[@]}"; do
    candidate="$(mirror_url "${prefix}" "${url}")"
    log "Trying ${label}: ${candidate}"
    if download_file "${candidate}" "${dest}"; then
      return 0
    fi
    warn "Failed: ${candidate}"
  done

  return 1
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
  download_with_mirrors "${zip_url}" "${zip_file}" "Xray archive" || die "Failed to download Xray from ${zip_url}"

  if download_with_mirrors "${zip_url}.dgst" "${digest_file}" "Xray checksum" >/dev/null 2>&1; then
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

create_service_user() {
  if [[ "${XRAY_USER}" == "root" ]]; then
    return
  fi

  if id -u "${XRAY_USER}" >/dev/null 2>&1; then
    return
  fi

  local nologin="/usr/sbin/nologin"
  [[ -x "${nologin}" ]] || nologin="/sbin/nologin"

  command_exists useradd || die "useradd is required to create service user ${XRAY_USER}."
  useradd --system --no-create-home --home-dir "${STATE_DIR}" --shell "${nologin}" "${XRAY_USER}"
}

generate_reality_keypair() {
  local keypair
  log "Generating REALITY key pair..."
  keypair="$("${INSTALL_PATH}" x25519)"

  PRIVATE_KEY="$(awk -F': *' '/Private[[:space:]]*[Kk]ey|PrivateKey/ {print $2; exit}' <<<"${keypair}" | tr -d '[:space:]')"
  PUBLIC_KEY="$(awk -F': *' '/Public[[:space:]]*[Kk]ey|Password/ {print $2; exit}' <<<"${keypair}" | tr -d '[:space:]')"

  [[ -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" ]] || die "Failed to parse REALITY key pair."
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
          "target": "${REALITY_TARGET}",
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
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
  local server_ip tag vless_url
  server_ip="$(public_ip)"
  tag="xray-${server_ip}"
  vless_url="vless://${UUID}@${server_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=${CLIENT_FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${tag}"

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
    tls: true
    udp: true
    flow: xtls-rprx-vision
    network: tcp
    servername: ${REALITY_SERVER_NAME}
    client-fingerprint: ${CLIENT_FINGERPRINT}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}

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

  if [[ "${XRAY_USER}" != "root" ]] && id -u "${XRAY_USER}" >/dev/null 2>&1 && command_exists userdel; then
    userdel "${XRAY_USER}" >/dev/null 2>&1 || warn "Could not remove user ${XRAY_USER}; remove it manually if unused."
  fi

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
  generate_short_id
  validate_uuid "${UUID}"
  validate_short_id "${SHORT_ID}"
  install_xray
  create_service_user
  generate_reality_keypair
  write_config
  write_service
  validate_xray_config
  start_service
  print_client_config
}

main "$@"

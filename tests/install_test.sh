#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../install.sh
source "${ROOT_DIR}/install.sh"

TESTS=0

pass() {
  TESTS=$((TESTS + 1))
  printf 'ok %d - %s\n' "$TESTS" "$1"
}

assert_eq() {
  local expected="$1" actual="$2" description="$3"
  [[ "$expected" == "$actual" ]] || {
    printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$description" "$expected" "$actual" >&2
    exit 1
  }
  pass "$description"
}

assert_fails() {
  local description="$1"
  shift
  if ("$@") >/dev/null 2>&1; then
    printf 'not ok - %s（命令本应失败）\n' "$description" >&2
    exit 1
  fi
  pass "$description"
}

assert_eq "443" "$PORT" "默认端口为 443"
assert_eq "itunes.apple.com" "$DOMAIN" "默认 REALITY 域名为 itunes.apple.com"
assert_eq "chrome" "$FINGERPRINT" "默认客户端指纹为 chrome"

validate_port 443
pass "接受有效端口"
assert_fails "拒绝越界端口" validate_port 65536
assert_fails "拒绝非数字端口" validate_port abc

validate_uuid 00000000-0000-4000-8000-000000000000
pass "接受有效 UUID"
assert_fails "拒绝无效 UUID" validate_uuid not-a-uuid
validate_version v26.3.27
pass "接受三段式 Xray 版本"
assert_fails "拒绝危险的版本字符串" validate_version '../latest'

validate_domain itunes.apple.com
pass "接受有效域名"
assert_fails "拒绝域名注入字符" validate_domain 'example.com"}'
assert_fails "拒绝空域名标签" validate_domain example..com

assert_eq "64" "$(map_architecture x86_64)" "映射 x86_64 架构"
assert_eq "arm64-v8a" "$(map_architecture aarch64)" "映射 aarch64 架构"
assert_eq "mips32le" "$(map_architecture mipsle)" "映射 mipsle 架构"
assert_fails "拒绝未知架构" map_architecture made-up

key_output=$'Private key: private-value\nPassword (PublicKey): public-value'
assert_eq "private-value" "$(extract_private_key "$key_output")" "解析 REALITY 私钥"
assert_eq "public-value" "$(extract_public_key "$key_output")" "兼容新版公钥输出"

ACTION=menu
PORT=""
UUID=""
DOMAIN=itunes.apple.com
FINGERPRINT=chrome
VERSION=latest
FORCE=false
parse_args --port 8443 --uuid 00000000-0000-4000-8000-000000000000 --force
assert_eq "install" "$ACTION" "安装参数选择 install 操作"
assert_eq "8443" "$PORT" "解析 --port"
assert_eq "true" "$FORCE" "解析 --force"
assert_fails "缺少参数值时给出错误" parse_args --domain

(
  ACTION=menu
  PORT=""
  parse_args -port 9090
  [[ "$ACTION" == install && "$PORT" == 9090 ]]
)
pass "兼容旧版单横线参数"

(
  is_installed() { return 1; }
  FORCE=false
  ensure_overwrite_allowed false
)
pass "首次安装时继续执行而不是退出"

TEMP_DIR=$(mktemp -d)
PORT=443
UUID=00000000-0000-4000-8000-000000000000
DOMAIN=itunes.apple.com
FINGERPRINT=chrome
PRIVATE_KEY=private-value
PUBLIC_KEY=public-value
SHORT_ID=0123456789abcdef
STAGED_BINARY="${TEMP_DIR}/fake-xray"
XRAY_BIN=/root/xray/bin/xray
CONFIG_FILE=/root/xray/config/config.json
cat > "$STAGED_BINARY" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STAGED_BINARY"
create_staged_config
jq -e '.inbounds[0].streamSettings.realitySettings.privateKey == "private-value"' "$STAGED_CONFIG" >/dev/null
pass "生成有效的 REALITY JSON 配置"
jq -e '.inbounds[0].streamSettings.realitySettings | has("fingerprint") | not' "$STAGED_CONFIG" >/dev/null
pass "服务端配置不混入客户端 fingerprint"
jq -e '.fingerprint == "chrome" and .publicKey == "public-value"' "$STAGED_CLIENT" >/dev/null
pass "客户端参数单独保存"
grep -q '^NoNewPrivileges=true$' "$STAGED_SERVICE"
pass "systemd 服务启用基础加固"
rm -rf "$TEMP_DIR"

printf '# %d tests passed\n' "$TESTS"

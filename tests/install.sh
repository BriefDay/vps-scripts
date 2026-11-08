#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Verify root install.sh and hy2/install.sh stay byte-for-byte synchronized
if ! cmp -s "$script_dir/install.sh" "$script_dir/hy2/install.sh"; then
  printf 'FAIL: root install.sh and hy2/install.sh differ\n' >&2
  exit 1
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export HY2_SOURCE_ONLY=1
export HY2_CONFIG="$test_tmp/config.yaml"
export HY2_URL_SCHEME="$test_tmp/hy2_url_scheme.txt"
export HY2_BIN="$test_tmp/fake-hysteria"
export HY2_PID_FILE="$test_tmp/hysteria-server.pid"
export HY2_LOG_FILE="$test_tmp/hysteria-server.log"
export HY2_ERR_FILE="$test_tmp/hysteria-server.err"
export HY2_OPENRC_SCRIPT="$test_tmp/init.d/hysteria-server"
export HY2_SYSTEMD_UNIT="$test_tmp/systemd/hysteria-server.service"

# shellcheck source=/dev/null
source "$script_dir/install.sh"
RED='' GREEN='' YELLOW='' RESET=''

assert_eq() {
  local expected=$1 actual=$2 message=$3
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local needle=$1 haystack=$2 message=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s\nmissing: %s\nactual: %s\n' "$message" "$needle" "$haystack" >&2
    exit 1
  fi
}

# 1. Memory profile tests (128 MiB / 256 MiB vs 1 GiB)
small_128=$(quic_memory_profile $((128 * 1024 * 1024)))
assert_contains 'initStreamReceiveWindow: 524288' "$small_128" '128 MiB uses a small stream receive window'
assert_contains 'maxConnReceiveWindow: 2097152' "$small_128" '128 MiB caps the connection receive window'

small_profile=$(quic_memory_profile 268435456)
assert_contains 'initStreamReceiveWindow: 524288' "$small_profile" '256 MiB uses a small stream receive window'
assert_contains 'maxStreamReceiveWindow: 1048576' "$small_profile" '256 MiB caps the stream receive window'
assert_contains 'initConnReceiveWindow: 1048576' "$small_profile" '256 MiB uses a bounded connection receive window'
assert_contains 'maxConnReceiveWindow: 2097152' "$small_profile" '256 MiB caps the connection receive window'

large_profile=$(quic_memory_profile 1073741824)
assert_contains 'initStreamReceiveWindow: 8388608' "$large_profile" 'larger VPS keeps the standard stream window'
assert_contains 'maxConnReceiveWindow: 20971520' "$large_profile" 'larger VPS keeps the standard connection window'

assert_eq '0' "$(detect_memory_limit_bytes /tmp/nonexistent-cgroup-root)" 'missing cgroup data is treated as unlimited'

# 2. Read-only sysctl graceful handling in LXC containers
fake_bin=$(mktemp -d)
cat > "$fake_bin/sysctl" <<'FAKE_SYSCTL'
#!/usr/bin/env bash
exit 1
FAKE_SYSCTL
chmod +x "$fake_bin/sysctl"
if PATH="$fake_bin:$PATH" apply_sysctl_setting net.core.rmem_max 4194304; then
  printf 'FAIL: apply_sysctl_setting should return non-zero when sysctl rejects write\n' >&2
  exit 1
fi
rm -rf "$fake_bin"

# 3. Static config invariants
if grep -q 'net.ipv4.tcp_syncookies = 0' "$script_dir/install.sh"; then
  printf 'FAIL: script disables TCP syncookies\n' >&2
  exit 1
fi
if grep -q 'QoS:  已彻底解决' "$script_dir/install.sh"; then
  printf 'FAIL: script makes an absolute QoS claim\n' >&2
  exit 1
fi

script_text=$(<"$script_dir/install.sh")
assert_contains 'ignoreClientBandwidth: false' "$script_text" 'generated config permits client Brutal bandwidth negotiation'
assert_contains 'bandwidth:' "$script_text" 'generated config declares a Brutal bandwidth profile'
assert_contains '  up: 150 mbps' "$script_text" 'generated config caps client download at 150 Mbps'
assert_contains '  down: 100 mbps' "$script_text" 'generated config caps client upload at 100 Mbps'
assert_contains 'disableLossCompensation: true' "$script_text" 'generated config disables Brutal loss compensation'
assert_contains 'congestion:' "$script_text" 'generated config retains explicit BBR fallback control'
assert_contains 'bbrProfile: standard' "$script_text" 'generated config retains the validated BBR fallback profile'
assert_contains 'maxIncomingStreams: 128' "$script_text" 'generated config limits concurrent QUIC streams'
assert_contains 'keepAlivePeriod: 10s' "$script_text" 'generated config uses aggressive 10s keepalive'
assert_contains 'maxIdleTimeout: 120s' "$script_text" 'generated config permits 120s idle timeout'
assert_contains 'port-hopping=' "$script_text" 'installer generates port-hopping node'
assert_contains '请输入转发末尾端口号' "$script_text" 'installer prompts for optional end port'
assert_contains 'Hysteria2-Agent' "$script_text" 'installer labels dedicated agent node'
assert_contains 'download-bandwidth=150' "$script_text" 'installer prints a Surge Brutal test-node field'
assert_contains 'Surge 节点' "$script_text" 'installer labels its Surge-specific output'

# 4. Systemd service health check with delayed UDP socket readiness
fake_bin=$(mktemp -d)
cat > "$fake_bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
if [[ "$1" == "is-active" ]]; then
  [[ "$2" == "--quiet" && "$3" == "hysteria-server.service" ]]
  exit $?
fi
exit 0
FAKE_SYSTEMCTL
cat > "$fake_bin/ss" <<'FAKE_SS'
#!/usr/bin/env bash
state=${TMPDIR:-/tmp}/hysteria-health-test-state
if [[ ! -e "$state" ]]; then
  : > "$state"
  exit 1
fi
printf '%s\n' 'UNCONN 0 0 0.0.0.0:51320 0.0.0.0:*'
FAKE_SS
chmod +x "$fake_bin/systemctl" "$fake_bin/ss"
rm -f "${TMPDIR:-/tmp}/hysteria-health-test-state"
health_output=$(HY2_INIT_SYSTEM=systemd PATH="$fake_bin:$PATH" check_service_health 51320 2>&1)
assert_contains '服务健康检查通过' "$health_output" 'systemd health check tolerates socket startup delay'
rm -f "${TMPDIR:-/tmp}/hysteria-health-test-state"
rm -rf "$fake_bin"

# 5. OpenRC (Alpine) service management WITHOUT systemctl or journalctl
fake_bin=$(mktemp -d)
ln -s "$(command -v bash)" "$fake_bin/bash"
for tool in sh cat chmod mkdir rm grep sed tr printf tail sleep uname kill nohup; do
  if command -v "$tool" >/dev/null 2>&1; then
    ln -s "$(command -v "$tool")" "$fake_bin/$tool"
  fi
done
cat > "$fake_bin/rc-update" <<'FAKE_RC_UPDATE'
#!/usr/bin/env bash
exit 0
FAKE_RC_UPDATE
cat > "$fake_bin/rc-service" <<'FAKE_RC_SERVICE'
#!/usr/bin/env bash
[[ "$1" == "hysteria-server" && ( "$2" == "restart" || "$2" == "status" || "$2" == "stop" ) ]]
FAKE_RC_SERVICE
cat > "$fake_bin/ss" <<'FAKE_SS_OPENRC'
#!/usr/bin/env bash
printf '%s\n' 'UNCONN 0 0 0.0.0.0:31211 0.0.0.0:*'
FAKE_SS_OPENRC
chmod +x "$fake_bin/rc-update" "$fake_bin/rc-service" "$fake_bin/ss"

openrc_out=$(HY2_INIT_SYSTEM=openrc PATH="$fake_bin" bash -c '
  source "'"$script_dir"'/install.sh"
  start_or_restart_service
  check_service_health 31211
' 2>&1)
assert_contains '服务健康检查通过：UDP :31211 正在监听' "$openrc_out" 'OpenRC mode starts and passes health check without systemctl/journalctl'
assert_contains 'use net' "$(<"$HY2_OPENRC_SCRIPT")" 'OpenRC init script uses soft network dependency for LXC compatibility'
rm -rf "$fake_bin"

# 6. Pure non-systemd / non-OpenRC container daemon fallback WITHOUT systemctl, journalctl, or rc-service
fake_bin=$(mktemp -d)
for tool in bash sh cat chmod mkdir rm grep sed tr printf tail sleep uname kill nohup pkill; do
  if command -v "$tool" >/dev/null 2>&1; then
    ln -s "$(command -v "$tool")" "$fake_bin/$tool"
  fi
done
cat > "$HY2_BIN" <<'FAKE_HY2_BIN'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
  echo "Version: v2.13.0"
  exit 0
fi
echo "Hysteria2 mock server listening on :31211"
sleep 30
FAKE_HY2_BIN
chmod +x "$HY2_BIN"
echo "listen: :31211" > "$HY2_CONFIG"
cat > "$fake_bin/ss" <<'FAKE_SS_DAEMON'
#!/usr/bin/env bash
printf '%s\n' 'UNCONN 0 0 0.0.0.0:31211 0.0.0.0:*'
FAKE_SS_DAEMON
chmod +x "$fake_bin/ss"

daemon_out=$(HY2_INIT_SYSTEM=daemon PATH="$fake_bin" bash -c '
  source "'"$script_dir"'/install.sh"
  start_or_restart_service
  check_service_health 31211
  print_service_logs 5
  stop_hysteria_service
' 2>&1)
assert_contains '服务健康检查通过：UDP :31211 正在监听' "$daemon_out" 'Daemon fallback mode starts and passes health check without systemctl/rc-service'
assert_contains 'Hysteria2 mock server listening on :31211' "$daemon_out" 'Daemon fallback mode prints log file without journalctl'
rm -rf "$fake_bin"

# 7. Port hopping tests
assert_eq "0" "$(setup_port_hopping 39810 "" && echo 0)" 'setup_port_hopping without end port exits immediately with 0'

fake_bin=$(mktemp -d)
cat > "$fake_bin/iptables" <<'FAKE_IPTABLES'
#!/usr/bin/env bash
echo "iptables called with: $*" >> "${TMPDIR:-/tmp}/iptables.log"
exit 0
FAKE_IPTABLES
cat > "$fake_bin/ip6tables" <<'FAKE_IP6TABLES'
#!/usr/bin/env bash
echo "ip6tables called with: $*" >> "${TMPDIR:-/tmp}/ip6tables.log"
exit 0
FAKE_IP6TABLES
chmod +x "$fake_bin/iptables" "$fake_bin/ip6tables"
rm -f "${TMPDIR:-/tmp}/iptables.log" "${TMPDIR:-/tmp}/ip6tables.log"

PATH="$fake_bin:$PATH" setup_port_hopping 39810 39819 >/dev/null 2>&1 || true
iptables_calls=$(cat "${TMPDIR:-/tmp}/iptables.log" 2>/dev/null || true)
assert_contains '39810:39819' "$iptables_calls" 'setup_port_hopping passes custom port range to iptables'
assert_contains '--to-ports 39810' "$iptables_calls" 'setup_port_hopping redirects to starting port'
rm -f "${TMPDIR:-/tmp}/iptables.log" "${TMPDIR:-/tmp}/ip6tables.log"
rm -rf "$fake_bin"

printf 'PASS: all install.sh unit & container compatibility tests passed\n'

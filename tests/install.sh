#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RED='' GREEN='' YELLOW='' RESET=''
# Load only the resource-profile helper; this avoids package installation and the interactive menu.
source <(sed -n '/^detect_memory_limit_bytes()/,/^}/p; /^quic_memory_profile()/,/^}/p; /^apply_sysctl_setting()/,/^}/p; /^check_service_health()/,/^}/p; /^setup_port_hopping()/,/^}/p' "$script_dir/install.sh")

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
    printf 'FAIL: %s\nmissing: %s\n' "$message" "$needle" >&2
    exit 1
  fi
}

small_profile=$(quic_memory_profile 268435456)
assert_contains 'initStreamReceiveWindow: 2097152' "$small_profile" '256 MiB uses a small stream receive window'
assert_contains 'maxStreamReceiveWindow: 4194304' "$small_profile" '256 MiB caps the stream receive window'
assert_contains 'initConnReceiveWindow: 8388608' "$small_profile" '256 MiB uses a bounded connection receive window'
assert_contains 'maxConnReceiveWindow: 8388608' "$small_profile" '256 MiB caps the connection receive window'

large_profile=$(quic_memory_profile 1073741824)
assert_contains 'initStreamReceiveWindow: 8388608' "$large_profile" 'larger VPS keeps the standard stream window'
assert_contains 'maxConnReceiveWindow: 20971520' "$large_profile" 'larger VPS keeps the standard connection window'

assert_eq '0' "$(detect_memory_limit_bytes /tmp/nonexistent-cgroup-root)" 'missing cgroup data is treated as unlimited'

fake_bin=$(mktemp -d)
cat > "$fake_bin/sysctl" <<'FAKE_SYSCTL'
#!/usr/bin/env bash
exit 1
FAKE_SYSCTL
chmod +x "$fake_bin/sysctl"
warning_output=$(PATH="$fake_bin:$PATH" apply_sysctl_setting net.core.rmem_max 4194304 2>&1 || true)
assert_contains '不允许修改 net.core.rmem_max' "$warning_output" 'unsupported LXC sysctl emits a warning'
rm -rf "$fake_bin"

if grep -q 'net.ipv4.tcp_syncookies = 0' "$script_dir/install.sh"; then
  printf 'FAIL: script disables TCP syncookies\n' >&2
  exit 1
fi
if grep -q 'QoS:  已彻底解决' "$script_dir/install.sh"; then
  printf 'FAIL: script makes an absolute QoS claim\n' >&2
  exit 1
fi

assert_contains 'ignoreClientBandwidth: false' "$(<"$script_dir/install.sh")" 'generated config permits client Brutal bandwidth negotiation'
assert_contains 'bandwidth:' "$(<"$script_dir/install.sh")" 'generated config declares a Brutal bandwidth profile'
assert_contains '  up: 150 mbps' "$(<"$script_dir/install.sh")" 'generated config caps client download at 150 Mbps'
assert_contains '  down: 100 mbps' "$(<"$script_dir/install.sh")" 'generated config caps client upload at 100 Mbps'
assert_contains 'disableLossCompensation: true' "$(<"$script_dir/install.sh")" 'generated config disables Brutal loss compensation'
assert_contains 'congestion:' "$(<"$script_dir/install.sh")" 'generated config retains explicit BBR fallback control'
assert_contains 'bbrProfile: standard' "$(<"$script_dir/install.sh")" 'generated config retains the validated BBR fallback profile'
assert_contains 'maxIncomingStreams: 128' "$(<"$script_dir/install.sh")" 'generated config limits concurrent QUIC streams'
assert_contains 'keepAlivePeriod: 10s' "$(<"$script_dir/install.sh")" 'generated config uses aggressive 10s keepalive to prevent optical modem UDP timeout'
assert_contains 'maxIdleTimeout: 300s' "$(<"$script_dir/install.sh")" 'generated config permits 300s idle timeout for long reasoning tasks'
assert_contains 'port-hopping=' "$(<"$script_dir/install.sh")" 'installer generates port-hopping node for anti-QoS stability'
assert_contains '请输入转发末尾端口号' "$(<"$script_dir/install.sh")" 'installer prompts for optional end port'
assert_contains 'Hysteria2-Agent' "$(<"$script_dir/install.sh")" 'installer labels dedicated agent node'
assert_contains 'download-bandwidth=150' "$(<"$script_dir/install.sh")" 'installer prints a Surge Brutal test-node field'
assert_contains 'Surge 节点' "$(<"$script_dir/install.sh")" 'installer labels its Surge-specific output'

fake_bin=$(mktemp -d)
cat > "$fake_bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
[[ "$1" == "is-active" && "$2" == "--quiet" && "$3" == "hysteria-server.service" ]]
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
health_output=$(PATH="$fake_bin:$PATH" check_service_health 51320 2>&1)
assert_contains '服务健康检查通过' "$health_output" 'health check tolerates socket startup delay'
rm -f "${TMPDIR:-/tmp}/hysteria-health-test-state"
rm -rf "$fake_bin"

# Test setup_port_hopping without end port
assert_eq "0" "$(setup_port_hopping 39810 "" && echo 0)" 'setup_port_hopping without end port exits immediately with 0'

# Test setup_port_hopping with end port
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

printf 'PASS: install.sh resource profile tests\n'

#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RED='' GREEN='' YELLOW='' RESET=''
# Load only the resource-profile helper; this avoids package installation and the interactive menu.
source <(sed -n '/^detect_memory_limit_bytes()/,/^}/p; /^quic_memory_profile()/,/^}/p; /^apply_sysctl_setting()/,/^}/p; /^check_service_health()/,/^}/p' "$script_dir/install.sh")

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

assert_contains 'congestion:' "$(<"$script_dir/install.sh")" 'generated config selects explicit congestion control'
assert_contains 'bbrProfile: standard' "$(<"$script_dir/install.sh")" 'generated config uses the validated BBR profile'
assert_contains 'maxIncomingStreams: 128' "$(<"$script_dir/install.sh")" 'generated config limits concurrent QUIC streams'

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

printf 'PASS: install.sh resource profile tests\n'

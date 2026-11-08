#!/bin/bash
# Hysteria2 极简一键安装脚本 (防 QoS 优化版 - 全平台 Systemd / OpenRC / 容器通用)
# ============================================================

RED='\033[91m'
GREEN='\033[92m'
YELLOW='\033[93m'
RESET='\033[0m'

HY2_CONFIG="${HY2_CONFIG:-/etc/hysteria/config.yaml}"
HY2_URL_SCHEME="${HY2_URL_SCHEME:-/etc/hysteria/hy2_url_scheme.txt}"
HY2_BIN="${HY2_BIN:-/usr/local/bin/hysteria}"
if [ -z "${HY2_PID_FILE:-}" ]; then
    if [ -d /run ]; then
        HY2_PID_FILE="/run/hysteria-server.pid"
    else
        HY2_PID_FILE="/var/run/hysteria-server.pid"
    fi
fi
HY2_LOG_FILE="${HY2_LOG_FILE:-/var/log/hysteria-server.log}"
HY2_ERR_FILE="${HY2_ERR_FILE:-/var/log/hysteria-server.err}"
SSL_DIR="${SSL_DIR:-/etc/ssl/private}"

# Root 检测
if [ "${HY2_SOURCE_ONLY:-0}" != "1" ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户执行此脚本！${RESET}"
    exit 1
fi

# 系统检测
OS_TYPE="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE="${ID:-unknown}"
fi

has_systemd() {
    if [ "${HY2_INIT_SYSTEM:-}" = "systemd" ]; then return 0; fi
    if [ -n "${HY2_INIT_SYSTEM:-}" ]; then return 1; fi
    command -v systemctl >/dev/null 2>&1 || return 1
    if [ -d /proc ] && [ ! -d /run/systemd/system ]; then
        return 1
    fi
    return 0
}

has_openrc() {
    if [ "${HY2_INIT_SYSTEM:-}" = "openrc" ]; then return 0; fi
    if [ -n "${HY2_INIT_SYSTEM:-}" ]; then return 1; fi
    command -v rc-service >/dev/null 2>&1 || return 1
    if [ -d /proc ] && [ ! -f /run/openrc/softlevel ]; then
        if [ -d /run/openrc ]; then
            touch /run/openrc/softlevel 2>/dev/null || true
        else
            return 1
        fi
    fi
    return 0
}

install_packages() {
    echo "正在安装必要依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq wget curl openssl jq iptables iproute2 procps ca-certificates >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1 || true
        apk add --no-cache bash curl wget openssl jq iproute2 iptables procps ca-certificates grep sed coreutils shadow >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q epel-release >/dev/null 2>&1 || true
        dnf install -y -q wget curl openssl jq iptables iproute procps-ng ca-certificates >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q epel-release >/dev/null 2>&1 || true
        yum install -y -q wget curl openssl jq iptables iproute procps-ng ca-certificates >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed wget curl openssl jq iptables iproute2 procps-ng ca-certificates >/dev/null 2>&1 || true
    fi
}

detect_hy2_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|armv8*) echo "arm64" ;;
        armv7*|armv6*) echo "arm" ;;
        armv5*) echo "armv5" ;;
        i386|i686) echo "386" ;;
        s390x) echo "s390x" ;;
        riscv64) echo "riscv64" ;;
        mips*) echo "mipsle" ;;
        loongarch64) echo "loong64" ;;
        *) echo "" ;;
    esac
}

install_hysteria_binary() {
    echo "正在安装最新版 Hysteria2..."
    export TERM=xterm

    # Systemd 环境优先尝试官方脚本；非 Systemd / Alpine / 最小化容器走原生静态二进制直装避免 get.hy2.sh 兼容性异常
    if has_systemd; then
        bash <(curl -fsSL --connect-timeout 8 -m 90 https://get.hy2.sh/) >/dev/null 2>&1 || true
        if [ -x "$HY2_BIN" ] && "$HY2_BIN" version >/dev/null 2>&1; then
            return 0
        fi
    fi

    local hy2_arch
    hy2_arch=$(detect_hy2_arch)
    if [ -z "$hy2_arch" ]; then
        echo -e "${RED}不支持的 CPU 架构: $(uname -m)${RESET}" >&2
        return 1
    fi

    local hy2_ver=""
    hy2_ver=$(curl -fsSL --connect-timeout 5 -m 8 "https://api.hy2.io/v1/update?cver=installscript&plat=linux&arch=${hy2_arch}&chan=release&side=server" 2>/dev/null \
        | sed -n 's/.*"lver"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$hy2_ver" ]; then
        hy2_ver=$(curl -fsSL --connect-timeout 5 -m 8 "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"app\/\([^"]*\)".*/\1/p' | head -n 1)
    fi
    [ -z "$hy2_ver" ] && hy2_ver="v2.13.0"

    if [ -x "$HY2_BIN" ] && "$HY2_BIN" version 2>/dev/null | grep -qF "$hy2_ver"; then
        return 0
    fi

    local asset_path="apernet/hysteria/releases/download/app/${hy2_ver}/hysteria-linux-${hy2_arch}"
    local dl_urls=(
        "https://github.com/${asset_path}"
        "https://ghproxy.net/https://github.com/${asset_path}"
        "https://ghfast.top/https://github.com/${asset_path}"
        "https://mirror.ghproxy.com/https://github.com/${asset_path}"
    )

    local tmp_bin="/tmp/hysteria.bin.$$"
    local url
    mkdir -p "${HY2_BIN%/*}"
    for url in "${dl_urls[@]}"; do
        rm -f "$tmp_bin"
        if curl -fsSL --connect-timeout 8 -m 120 -o "$tmp_bin" "$url" 2>/dev/null || wget -q -T 10 -t 2 -O "$tmp_bin" "$url" 2>/dev/null; then
            if [ -s "$tmp_bin" ]; then
                chmod 755 "$tmp_bin"
                if "$tmp_bin" version >/dev/null 2>&1; then
                    mv -f "$tmp_bin" "$HY2_BIN"
                    chmod 755 "$HY2_BIN"
                    return 0
                fi
            fi
        fi
    done
    rm -f "$tmp_bin"

    if [ -x "$HY2_BIN" ] && "$HY2_BIN" version >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${RED}Hysteria2 二进制下载或校验失败，请检查网络连接！${RESET}" >&2
    return 1
}

detect_memory_limit_bytes() {
    local cgroup_root=${1:-/sys/fs/cgroup}
    local memory_limit
    memory_limit=$(cat "$cgroup_root/memory.max" 2>/dev/null || true)
    if [[ "$memory_limit" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$memory_limit"
        return 0
    fi
    memory_limit=$(cat "$cgroup_root/memory/memory.limit_in_bytes" 2>/dev/null || true)
    if [[ "$memory_limit" =~ ^[0-9]+$ ]] && [ "$memory_limit" -lt 1099511627776 ]; then
        printf '%s\n' "$memory_limit"
        return 0
    fi
    if [ "$#" -eq 0 ] && [ -r /proc/meminfo ]; then
        local mem_kb
        mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)
        if [[ "$mem_kb" =~ ^[0-9]+$ ]] && [ "$mem_kb" -gt 0 ]; then
            printf '%s\n' "$((mem_kb * 1024))"
            return 0
        fi
    fi
    printf '0\n'
}

quic_memory_profile() {
    local memory_limit_bytes=${1:-0}
    if [ "$memory_limit_bytes" -gt 0 ] && [ "$memory_limit_bytes" -le $((512 * 1024 * 1024)) ]; then
        cat <<'PROFILE'
  initStreamReceiveWindow: 524288
  maxStreamReceiveWindow: 1048576
  initConnReceiveWindow: 1048576
  maxConnReceiveWindow: 2097152
PROFILE
    else
        cat <<'PROFILE'
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
PROFILE
    fi
}

apply_sysctl_setting() {
    local key=$1 value=$2
    if sysctl -w "$key=$value" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

is_ipv6_reachable() {
    if command -v curl >/dev/null 2>&1; then
        curl -6 -fsS --connect-timeout 2 --max-time 3 "http://[2606:4700:4700::1111]/cdn-cgi/trace" >/dev/null 2>&1 && return 0
        curl -6 -fsS --connect-timeout 2 --max-time 3 "https://api64.ipify.org" >/dev/null 2>&1 && return 0
    fi
    if command -v ping6 >/dev/null 2>&1; then
        ping6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1 && return 0
        ping6 -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1 && return 0
    elif command -v ping >/dev/null 2>&1; then
        ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1 && return 0
    fi
    return 1
}

auto_optimize_network() {
    echo "正在配置网络优化 (BBR & UDP 缓冲区)..."
    # 检测并清理黑洞 IPv6 路由 (部分 NAT 容器默认网关不可达导致请求严重超时)
    if command -v ip >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && ip -6 route show default 2>/dev/null | grep -q default; then
        if ! is_ipv6_reachable; then
            echo -e "${YELLOW}警告：检测到当前系统 IPv6 默认路由不可达，自动清理无效默认路由以避免请求超时${RESET}" >&2
            ip -6 route del default 2>/dev/null || true
        fi
    fi

    local available_cc chosen_cc memory_limit
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    chosen_cc=""
    if echo "$available_cc" | grep -qw "bbr3"; then chosen_cc="bbr3"
    elif echo "$available_cc" | grep -qw "bbr"; then chosen_cc="bbr"
    fi

    memory_limit=$(detect_memory_limit_bytes)
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    cat > /etc/sysctl.d/99-hysteria2.conf << SYSCTL
# Values are best-effort; LXC containers may reject host-level sysctls.
net.core.default_qdisc = fq
${chosen_cc:+net.ipv4.tcp_congestion_control = $chosen_cc}
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.core.somaxconn = 4096
net.netfilter.nf_conntrack_max = 65535
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
SYSCTL

    local skipped_sysctls=0
    while IFS='=' read -r raw_key raw_val; do
        local key="${raw_key#"${raw_key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        local value="${raw_val#"${raw_val%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [ -z "$key" ] || [[ "$key" == \#* ]] || [ -z "$value" ]; then
            continue
        fi
        if ! apply_sysctl_setting "$key" "$value"; then
            skipped_sysctls=$((skipped_sysctls + 1))
        fi
    done < /etc/sysctl.d/99-hysteria2.conf

    if [ "$skipped_sysctls" -gt 0 ]; then
        echo -e "${YELLOW}提示：当前容器环境限制内核参数修改，已自动跳过 ${skipped_sysctls} 项只读 sysctl${RESET}" >&2
    fi

    if [ "$memory_limit" -gt 0 ] && [ "$memory_limit" -le $((512 * 1024 * 1024)) ]; then
        echo -e "${YELLOW}检测到内存限制 $((memory_limit / 1024 / 1024)) MiB，将使用小内存 QUIC 配置${RESET}"
    fi
}

setup_port_hopping() {
    local hy2_port=$1
    local hop_end=$2

    if [ -z "$hop_end" ]; then
        return 0
    fi

    local hop_start=$hy2_port
    echo "正在配置端口跳跃 (Port Hopping: UDP ${hop_start}-${hop_end} -> ${hy2_port})..."

    # 尝试切换为 legacy 模式 (部分 LXC 容器对 nf_tables 支持不佳)
    if command -v update-alternatives >/dev/null 2>&1; then
        update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    fi

    local iptables_ok=0
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null || true
        if iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
            iptables_ok=1
        elif command -v iptables-legacy >/dev/null 2>&1 && iptables-legacy -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
            iptables_ok=1
        fi
    fi
    local ip6tables_ok=0
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null || true
        if ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
            ip6tables_ok=1
        elif command -v ip6tables-legacy >/dev/null 2>&1 && ip6tables-legacy -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
            ip6tables_ok=1
        fi
    fi

    if [ "$iptables_ok" -eq 0 ] && [ "$ip6tables_ok" -eq 0 ]; then
        echo -e "${YELLOW}提示：当前 NAT/容器环境宿主机未开放 iptables NAT 权限，已自动转为纯单端口模式${RESET}" >&2
        return 1
    fi

    mkdir -p /etc/hysteria 2>/dev/null || true
    echo "${hop_start}:${hop_end}:${hy2_port}" > /etc/hysteria/port_hopping.txt 2>/dev/null || true
    return 0
}

ensure_systemd_service() {
    local unit_file="${HY2_SYSTEMD_UNIT:-/etc/systemd/system/hysteria-server.service}"
    if [ ! -f "$unit_file" ]; then
        mkdir -p "${unit_file%/*}" 2>/dev/null || true
        cat > "$unit_file" << EOF
[Unit]
Description=Hysteria 2 Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${HY2_BIN} server -c ${HY2_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

ensure_openrc_service() {
    local init_file="${HY2_OPENRC_SCRIPT:-/etc/init.d/hysteria-server}"
    mkdir -p "${init_file%/*}" "${HY2_PID_FILE%/*}" "${HY2_LOG_FILE%/*}" 2>/dev/null || true
    cat > "$init_file" << EOF
#!/sbin/openrc-run
name="hysteria-server"
description="Hysteria 2 Server"
command="${HY2_BIN}"
command_args="server -c ${HY2_CONFIG}"
command_background=true
pidfile="${HY2_PID_FILE}"
output_log="${HY2_LOG_FILE}"
error_log="${HY2_ERR_FILE}"

depend() {
    use net
    after firewall
}
EOF
    chmod +x "$init_file"
}

ensure_sysvinit_service() {
    if [ -d /etc/init.d ] && command -v update-rc.d >/dev/null 2>&1; then
        cat > /etc/init.d/hysteria-server << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          hysteria-server
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Hysteria 2 Server
### END INIT INFO

case "\$1" in
    start)
        nohup "${HY2_BIN}" server -c "${HY2_CONFIG}" >> "${HY2_LOG_FILE}" 2>&1 </dev/null &
        echo \$! > "${HY2_PID_FILE}"
        ;;
    stop)
        [ -f "${HY2_PID_FILE}" ] && kill "\$(cat "${HY2_PID_FILE}")" 2>/dev/null || true
        rm -f "${HY2_PID_FILE}"
        ;;
    restart)
        "\$0" stop
        sleep 1
        "\$0" start
        ;;
    status)
        [ -f "${HY2_PID_FILE}" ] && kill -0 "\$(cat "${HY2_PID_FILE}")" 2>/dev/null
        ;;
esac
EOF
        chmod +x /etc/init.d/hysteria-server
        update-rc.d hysteria-server defaults >/dev/null 2>&1 || true
    fi
}

stop_daemon_process() {
    if [ -f "$HY2_PID_FILE" ]; then
        local pid
        pid=$(cat "$HY2_PID_FILE" 2>/dev/null || true)
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 0.2 2>/dev/null || sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$HY2_PID_FILE"
    fi
    pkill -f "${HY2_BIN} server" 2>/dev/null || pkill -f "hysteria server" 2>/dev/null || true
    if [ "${HY2_BIN##*/}" = "hysteria" ] && [ -d /proc ]; then
        local comm_file p
        for comm_file in /proc/[0-9]*/comm; do
            [ -r "$comm_file" ] || continue
            if [ "$(cat "$comm_file" 2>/dev/null || true)" = "hysteria" ]; then
                p="${comm_file#/proc/}"
                p="${p%/comm}"
                kill "$p" 2>/dev/null || true
            fi
        done
    fi
}

start_daemon_process() {
    stop_daemon_process
    mkdir -p "${HY2_PID_FILE%/*}" "${HY2_LOG_FILE%/*}" 2>/dev/null || true
    : > "$HY2_LOG_FILE" 2>/dev/null || true
    nohup "$HY2_BIN" server -c "$HY2_CONFIG" >> "$HY2_LOG_FILE" 2>&1 </dev/null &
    echo $! > "$HY2_PID_FILE"
    sleep 1
}

start_or_restart_service() {
    if has_systemd; then
        ensure_systemd_service
        systemctl enable --now hysteria-server.service >/dev/null 2>&1 || true
        systemctl restart hysteria-server.service
    elif has_openrc; then
        ensure_openrc_service
        rc-update add hysteria-server default >/dev/null 2>&1 || true
        if ! rc-service hysteria-server restart; then
            start_daemon_process
        fi
    else
        ensure_sysvinit_service
        start_daemon_process
    fi
}

stop_hysteria_service() {
    if has_systemd; then
        systemctl stop hysteria-server.service 2>/dev/null || true
        systemctl disable hysteria-server.service 2>/dev/null || true
    elif has_openrc; then
        rc-service hysteria-server stop 2>/dev/null || true
        rc-update del hysteria-server default 2>/dev/null || true
        rm -f "${HY2_OPENRC_SCRIPT:-/etc/init.d/hysteria-server}"
    else
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d -f hysteria-server remove >/dev/null 2>&1 || true
        fi
        rm -f /etc/init.d/hysteria-server
    fi
    stop_daemon_process
}

is_service_active() {
    if has_systemd; then
        systemctl is-active --quiet hysteria-server.service && return 0
        return 1
    fi
    if has_openrc; then
        rc-service hysteria-server status >/dev/null 2>&1 && return 0
    fi
    if [ -f "$HY2_PID_FILE" ]; then
        local pid
        pid=$(cat "$HY2_PID_FILE" 2>/dev/null || true)
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    if command -v pgrep >/dev/null 2>&1 && pgrep -f "hysteria.*server" >/dev/null 2>&1; then
        return 0
    fi
    if [ "${HY2_BIN##*/}" = "hysteria" ] && [ -d /proc ]; then
        local comm_file
        for comm_file in /proc/[0-9]*/comm; do
            [ -r "$comm_file" ] || continue
            if [ "$(cat "$comm_file" 2>/dev/null || true)" = "hysteria" ]; then
                return 0
            fi
        done
    fi
    return 1
}

print_service_logs() {
    local lines=${1:-20}
    if has_systemd && command -v journalctl >/dev/null 2>&1; then
        journalctl --no-pager -u hysteria-server.service -n "$lines" >&2 || true
        return 0
    fi
    local found=0 f
    for f in "$HY2_ERR_FILE" "$HY2_LOG_FILE"; do
        if [ -s "$f" ]; then
            tail -n "$lines" "$f" >&2 2>/dev/null || true
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "暂无可用服务日志" >&2
    fi
}

check_service_health() {
    local hy2_port=$1
    if ! is_service_active; then
        echo -e "${RED}服务启动失败，最近日志：${RESET}" >&2
        print_service_logs 20
        return 1
    fi

    local hex_port
    hex_port=$(printf '%04X' "$hy2_port" 2>/dev/null || true)

    local attempt
    for attempt in 1 2 3 4 5; do
        # 1. ss 检查 (通用)
        if command -v ss >/dev/null 2>&1 && ss -H -lun "sport = :$hy2_port" 2>/dev/null | grep -q ":$hy2_port"; then
            echo -e "${GREEN}服务健康检查通过：UDP :$hy2_port 正在监听${RESET}"
            return 0
        fi
        if command -v ss >/dev/null 2>&1 && ss -lun 2>/dev/null | grep -q ":$hy2_port"; then
            echo -e "${GREEN}服务健康检查通过：UDP :$hy2_port 正在监听${RESET}"
            return 0
        fi
        # 2. 内核 /proc/net/udp(6) 零依赖检查 (适用于无 iproute2 的最小化容器)
        if [ -n "$hex_port" ]; then
            if grep -qi ":${hex_port} " /proc/net/udp /proc/net/udp6 2>/dev/null; then
                echo -e "${GREEN}服务健康检查通过：UDP :$hy2_port 正在监听${RESET}"
                return 0
            fi
        fi
        sleep 1
    done

    echo -e "${RED}服务已运行但未检测到 UDP :$hy2_port 正在监听，最近日志：${RESET}" >&2
    print_service_logs 20
    return 1
}

urlencode() {
    local string="$1"
    local length=${#string}
    local encoded=""
    local i c o
    for (( i = 0; i < length; i++ )); do
        c="${string:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) printf -v o '%%%02X' "'$c"; encoded+="$o" ;;
        esac
    done
    echo "$encoded"
}

quick_setup() {
    local hy2_port=${1:-}
    local hy2_end_port=${2:-}
    local cli_mode=0
    [ -n "$hy2_port" ] && cli_mode=1

    echo -e "${GREEN}========== Hysteria2 极简一键安装 ==========${RESET}"

    # 1. 安装 hysteria2
    install_hysteria_binary || return 1

    # 2. 交互: 输入端口号
    if [ -z "$hy2_port" ]; then
        while true; do
            read -r -p "请输入主监听端口号 (1-65535)：" hy2_port || return 1
            hy2_port="${hy2_port//[[:space:]]/}"
            if [[ "$hy2_port" =~ ^[0-9]+$ ]] && [ "$hy2_port" -ge 1 ] && [ "$hy2_port" -le 65535 ]; then break; fi
            echo -e "${RED}输入有误，请重新输入！${RESET}"
        done
    elif ! [[ "$hy2_port" =~ ^[0-9]+$ ]] || [ "$hy2_port" -lt 1 ] || [ "$hy2_port" -gt 65535 ]; then
        echo -e "${RED}传入的主监听端口号无效 (${hy2_port})！${RESET}" >&2
        return 1
    fi

    if [ "$cli_mode" -eq 0 ] && [ -z "$hy2_end_port" ] && [ -t 0 ]; then
        while true; do
            read -r -p "请输入转发末尾端口号 (可选/直接回车不开启转发)：" hy2_end_port || break
            hy2_end_port="${hy2_end_port//[[:space:]]/}"
            if [ -z "$hy2_end_port" ]; then
                break
            elif [[ "$hy2_end_port" =~ ^[0-9]+$ ]] && [ "$hy2_end_port" -ge 1 ] && [ "$hy2_end_port" -le 65535 ]; then
                if [ "$hy2_end_port" -le "$hy2_port" ]; then
                    echo -e "${RED}末尾端口必须大于主监听端口 (${hy2_port})，请重新输入！${RESET}"
                else
                    break
                fi
            else
                echo -e "${RED}输入有误，请输入有效的端口号 (1-65535) 或直接按回车跳过！${RESET}"
            fi
        done
    fi

    # 3. 自动生成 bing.com 自签证书
    echo "正在生成 bing.com 自签名证书..."
    local cert_domain="bing.com"
    mkdir -p "$SSL_DIR"
    openssl ecparam -name prime256v1 -out "$SSL_DIR/ec_param.pem" 2>/dev/null
    openssl req -x509 -nodes -newkey "ec:$SSL_DIR/ec_param.pem" \
        -keyout "$SSL_DIR/${cert_domain}.key" \
        -out "$SSL_DIR/${cert_domain}.crt" \
        -subj "/CN=${cert_domain}" -days 36500 2>/dev/null
    chmod 644 "$SSL_DIR/${cert_domain}.key" "$SSL_DIR/${cert_domain}.crt"
    chmod 755 "$SSL_DIR"
    chown root:hysteria "$SSL_DIR/${cert_domain}.key" "$SSL_DIR/${cert_domain}.crt" 2>/dev/null || true

    # 4. 获取 IP
    echo "正在获取服务器 IP..."
    local ipv4_addr="" ipv6_addr="" candidate
    for candidate in \
        "$(curl -4 -fsSL --connect-timeout 3 --max-time 4 http://ip-api.com/json/ 2>/dev/null | sed -n 's/.*"query"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)" \
        "$(curl -4 -fsSL --connect-timeout 3 --max-time 4 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')" \
        "$(curl -4 -fsSL --connect-timeout 3 --max-time 4 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')"; do
        if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ipv4_addr="$candidate"
            break
        fi
    done

    for candidate in \
        "$(curl -6 -fsSL --connect-timeout 3 --max-time 4 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')" \
        "$(curl -6 -fsSL --connect-timeout 3 --max-time 4 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')"; do
        if [[ "$candidate" == *:* ]] && [[ "$candidate" =~ ^[0-9a-fA-F:]+$ ]]; then
            ipv6_addr="$candidate"
            break
        fi
    done

    local hy2_domain=""
    if [ -n "$ipv4_addr" ]; then hy2_domain="$ipv4_addr"
    elif [ -n "$ipv6_addr" ]; then hy2_domain="[${ipv6_addr}]"
    else read -r -p "无法自动获取IP，请手动输入：" hy2_domain || return 1; fi

    # 5. 生成随机密码
    local hy2_passwd
    hy2_passwd=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 16)

    # 6. 写配置
    mkdir -p "${HY2_CONFIG%/*}"
    local memory_limit
    memory_limit=$(detect_memory_limit_bytes)
    cat > "$HY2_CONFIG" << CONFIG
listen: :${hy2_port}

tls:
  cert: ${SSL_DIR}/${cert_domain}.crt
  key: ${SSL_DIR}/${cert_domain}.key

auth:
  type: password
  password: ${hy2_passwd}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

# Brutal 限速：在 256 MiB LXC 上降低 UDP 接收突发
ignoreClientBandwidth: false
bandwidth:
  up: 150 mbps
  down: 100 mbps
  disableLossCompensation: true

# 未声明客户端带宽时回退至 BBR
congestion:
  type: bbr
  bbrProfile: standard

quic:
$(quic_memory_profile "$memory_limit")
  maxIdleTimeout: 120s
  maxIncomingStreams: 128
  keepAlivePeriod: 10s
CONFIG

    # 7. 配置端口跳跃与启动服务
    if [ -n "$hy2_end_port" ]; then
        if ! setup_port_hopping "$hy2_port" "$hy2_end_port"; then
            hy2_end_port=""
        fi
    fi
    start_or_restart_service
    check_service_health "$hy2_port" || return 1

    # 8. 生成链接
    local encoded_pw
    encoded_pw=$(urlencode "$hy2_passwd")
    local hop_param=""
    local mport_param=""
    local hop_info=""
    if [ -n "$hy2_end_port" ]; then
        hop_param=",port-hopping=${hy2_port}-${hy2_end_port},port-hopping-interval=30"
        mport_param="&mport=${hy2_port}-${hy2_end_port}"
        hop_info=" (跳跃端口段: ${hy2_port}-${hy2_end_port})"
    fi

    local link="hysteria2://${encoded_pw}@${hy2_domain}:${hy2_port}?sni=${cert_domain}&insecure=1${mport_param}#Hysteria2"
    mkdir -p "${HY2_URL_SCHEME%/*}"
    echo "$link" > "$HY2_URL_SCHEME"

    echo ""
    echo -e "${GREEN}========== Hysteria2 安装配置完成！==========${RESET}"
    echo -e "  主监听端口: ${hy2_port}${hop_info}"
    echo -e "  密码: ${hy2_passwd}"
    echo -e "  IPv4: ${ipv4_addr:-无}"
    echo -e "  IPv6: ${ipv6_addr:-无}"
    echo -e "  证书: bing.com 自签"
    echo -e "  QUIC: 已适配内存限制；保活心跳: 10s (防光猫会话超时)"
    echo ""
    echo -e "${RED}hy2 链接: ${link}${RESET}"
    echo -e "${YELLOW}提示：通用 hy2 链接不含 Brutal 带宽参数；Surge 请使用下方节点。${RESET}"
    echo -e "${RED}Surge 节点 (测速/下载 Brutal): Hysteria2 = hysteria2,${hy2_domain},${hy2_port},password=\"${hy2_passwd}\",sni=\"${cert_domain}\",skip-cert-verify=true,download-bandwidth=150${hop_param}${RESET}"
    echo -e "${GREEN}Surge 节点 (AI Agent 稳定防断流 BBR): Hysteria2-Agent = hysteria2,${hy2_domain},${hy2_port},password=\"${hy2_passwd}\",sni=\"${cert_domain}\",skip-cert-verify=true${hop_param}${RESET}"
    if [ -n "$ipv4_addr" ] && [ -n "$ipv6_addr" ]; then
        local link_v6="hysteria2://${encoded_pw}@[${ipv6_addr}]:${hy2_port}?sni=${cert_domain}&insecure=1${mport_param}#Hysteria2-IPv6"
        echo -e "${RED}IPv6 链接: ${link_v6}${RESET}"
        echo -e "${GREEN}Surge IPv6 (AI Agent 稳定防断流 BBR): Hysteria2-IPv6-Agent = hysteria2,[${ipv6_addr}],${hy2_port},password=\"${hy2_passwd}\",sni=\"${cert_domain}\",skip-cert-verify=true${hop_param}${RESET}"
    fi
    echo ""
}

hysteria2_uninstall() {
    read -r -p "确认卸载 Hysteria2? [y/n]: " choice || return 0
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        # 先清理端口跳跃规则（在删除 /etc/hysteria 之前读取记录）
        if [ -f /etc/hysteria/port_hopping.txt ]; then
            IFS=':' read -r saved_start saved_end saved_target < /etc/hysteria/port_hopping.txt 2>/dev/null || true
            if [ -n "$saved_start" ] && [ -n "$saved_end" ]; then
                if command -v iptables >/dev/null 2>&1; then
                    iptables -t nat -D PREROUTING -p udp --dport ${saved_start}:${saved_end} -j REDIRECT --to-ports "${saved_target:-$saved_start}" 2>/dev/null || \
                    iptables -t nat -D PREROUTING -p udp --dport ${saved_start}:${saved_end} -j REDIRECT 2>/dev/null || true
                fi
                if command -v ip6tables >/dev/null 2>&1; then
                    ip6tables -t nat -D PREROUTING -p udp --dport ${saved_start}:${saved_end} -j REDIRECT --to-ports "${saved_target:-$saved_start}" 2>/dev/null || \
                    ip6tables -t nat -D PREROUTING -p udp --dport ${saved_start}:${saved_end} -j REDIRECT 2>/dev/null || true
                fi
            fi
        fi
        if command -v iptables >/dev/null 2>&1; then
            iptables -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT 2>/dev/null || true
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT 2>/dev/null || true
        fi

        stop_hysteria_service
        if has_systemd; then
            bash <(curl -fsSL --connect-timeout 6 -m 30 https://get.hy2.sh/) --remove >/dev/null 2>&1 || true
            systemctl stop hysteria-iptables.service 2>/dev/null || true
            systemctl disable hysteria-iptables.service 2>/dev/null || true
            rm -f /etc/systemd/system/hysteria-iptables.service /etc/systemd/system/hysteria-server.service
            systemctl daemon-reload 2>/dev/null || true
        fi
        rm -f "$HY2_BIN" /usr/local/bin/hy2 "$HY2_LOG_FILE" "$HY2_ERR_FILE" \
            "$SSL_DIR/bing.com.key" "$SSL_DIR/bing.com.crt" "$SSL_DIR/ec_param.pem" \
            /etc/sysctl.d/99-hysteria2.conf
        rm -rf /etc/hysteria /etc/hy2config
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# --- Main ---
if [ "${HY2_SOURCE_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

if [ "$#" -gt 0 ]; then
    install_packages
    auto_optimize_network
    case "$1" in
        --port|-p)
            quick_setup "$2" "$3"
            exit $?
            ;;
        --batch)
            quick_setup "$2" "$3"
            exit $?
            ;;
        [0-9]*)
            quick_setup "$1" "$2"
            exit $?
            ;;
        uninstall|--uninstall)
            hysteria2_uninstall
            exit $?
            ;;
        *)
            echo "用法: $0 [端口号] [末尾端口号] 或 $0 --port <端口号>"
            exit 1
            ;;
    esac
fi

install_packages
auto_optimize_network

while true; do
    echo ""
    echo -e "${GREEN}Hysteria2 极简控制面板${RESET}"
    echo "1. 极简一键安装 (防QoS优化)"
    echo "2. 查看当前配置和节点链接"
    echo "3. 卸载 Hysteria2"
    echo "4. 服务管理 (重启/日志)"
    echo "0. 退出"
    read -r -p "请选择: " choice || exit 0
    case "$choice" in
        1) quick_setup ;;
        2)
            echo -e "\n${YELLOW}=== 配置文件 ===${RESET}"
            cat "$HY2_CONFIG" 2>/dev/null || echo "配置不存在"
            echo -e "\n${YELLOW}=== 节点链接 ===${RESET}"
            cat "$HY2_URL_SCHEME" 2>/dev/null || echo "节点链接不存在"
            ;;
        3) hysteria2_uninstall ;;
        4)
            start_or_restart_service
            echo -e "\n${GREEN}服务已重启。最近10条日志：${RESET}"
            print_service_logs 10
            ;;
        0) exit 0 ;;
        *) echo "输入无效" ;;
    esac
done

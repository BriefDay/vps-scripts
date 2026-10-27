#!/bin/bash
# Hysteria2 极简一键安装脚本 (防 QoS 优化版)
# ============================================================

RED='\033[91m'
GREEN='\033[92m'
YELLOW='\033[93m'
RESET='\033[0m'

HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_URL_SCHEME="/etc/hysteria/hy2_url_scheme.txt"
SSL_DIR="/etc/ssl/private"

# Root 检测
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户执行此脚本！${RESET}"
  exit 1
fi

# 系统检测
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
else
    echo "无法确定操作系统类型。"
    exit 1
fi

install_packages() {
    echo "正在安装必要依赖..."
    if [[ "$OS_TYPE" == "debian" || "$OS_TYPE" == "ubuntu" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq wget curl openssl jq iptables iproute2 >/dev/null 2>&1
    elif [[ "$OS_TYPE" == "centos" || "$OS_TYPE" == "rhel" || "$OS_TYPE" == "fedora" || "$OS_TYPE" == "rocky" ]]; then
        yum install -y -q epel-release >/dev/null 2>&1
        yum install -y -q wget curl openssl jq iptables iproute >/dev/null 2>&1
    fi
}

detect_memory_limit_bytes() {
    local cgroup_root=${1:-/sys/fs/cgroup}
    local memory_limit
    memory_limit=$(cat "$cgroup_root/memory.max" 2>/dev/null || true)
    if [[ "$memory_limit" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$memory_limit"
    else
        printf '0\n'
    fi
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
    echo -e "${YELLOW}警告：当前环境不允许修改 ${key}，已跳过${RESET}" >&2
    return 1
}

auto_optimize_network() {
    echo "正在配置网络优化 (BBR & UDP 缓冲区)..."
    local available_cc chosen_cc memory_limit
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    chosen_cc=""
    if echo "$available_cc" | grep -qw "bbr3"; then chosen_cc="bbr3"
    elif echo "$available_cc" | grep -qw "bbr"; then chosen_cc="bbr"
    fi

    memory_limit=$(detect_memory_limit_bytes)
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

    while IFS=' = ' read -r key value; do
        [ -z "$key" ] || [[ "$key" == \#* ]] || [ -z "$value" ] || apply_sysctl_setting "$key" "$value" || true
    done < /etc/sysctl.d/99-hysteria2.conf

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
    if [[ "${OS_TYPE:-}" == "debian" || "${OS_TYPE:-}" == "ubuntu" ]]; then
        update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    fi

    local iptables_ok=0
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null || true
        if iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
            iptables_ok=1
        elif iptables-legacy -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
            iptables_ok=1
        fi
    fi
    local ip6tables_ok=0
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null || true
        if ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
            ip6tables_ok=1
        elif ip6tables-legacy -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
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

check_service_health() {
    local hy2_port=$1
    if ! systemctl is-active --quiet hysteria-server.service; then
        echo -e "${RED}服务启动失败，最近日志：${RESET}" >&2
        journalctl --no-pager -u hysteria-server.service -n 20 >&2 || true
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
    journalctl --no-pager -u hysteria-server.service -n 20 >&2 || true
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
    echo -e "${GREEN}========== Hysteria2 极简一键安装 ==========${RESET}"
    
    # 1. 安装 hysteria2
    echo "正在安装最新版 Hysteria2..."
    export TERM=xterm
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1

    # 2. 交互: 输入端口号
    local hy2_port hy2_end_port
    while true; do
        read -p "请输入主监听端口号 (1-65535)：" hy2_port
        if [[ "$hy2_port" =~ ^[0-9]+$ ]] && [ "$hy2_port" -ge 1 ] && [ "$hy2_port" -le 65535 ]; then break; fi
        echo -e "${RED}输入有误，请重新输入！${RESET}"
    done

    while true; do
        read -p "请输入转发末尾端口号 (可选/直接回车不开启转发)：" hy2_end_port
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
    chown root:hysteria "$SSL_DIR/${cert_domain}.key" "$SSL_DIR/${cert_domain}.crt" 2>/dev/null

    # 4. 获取 IP
    echo "正在获取服务器 IP..."
    local ipv4_addr ipv6_addr
    ipv4_addr=$(curl -4 -s --max-time 3 http://ip-api.com/json/ 2>/dev/null | jq -r '.query // ""' 2>/dev/null)
    [ -z "$ipv4_addr" ] && ipv4_addr=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null)
    ipv6_addr=$(curl -6 -s --max-time 3 https://api.ip.sb/geoip 2>/dev/null | jq -r '.ip // ""' 2>/dev/null)
    [ -z "$ipv6_addr" ] && ipv6_addr=$(curl -6 -s --max-time 3 ifconfig.me 2>/dev/null)

    local hy2_domain=""
    if [ -n "$ipv4_addr" ]; then hy2_domain="$ipv4_addr"
    elif [ -n "$ipv6_addr" ]; then hy2_domain="[${ipv6_addr}]"
    else read -p "无法自动获取IP，请手动输入：" hy2_domain; fi

    # 5. 生成随机密码
    local hy2_passwd=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 16)

    # 6. 写配置
    mkdir -p /etc/hysteria
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
    systemctl enable --now hysteria-server.service >/dev/null 2>&1
    systemctl restart hysteria-server.service
    check_service_health "$hy2_port" || return 1

    # 8. 生成链接
    local encoded_pw=$(urlencode "$hy2_passwd")
    local hop_param=""
    local mport_param=""
    local hop_info=""
    if [ -n "$hy2_end_port" ]; then
        hop_param=",port-hopping=${hy2_port}-${hy2_end_port},port-hopping-interval=30"
        mport_param="&mport=${hy2_port}-${hy2_end_port}"
        hop_info=" (跳跃端口段: ${hy2_port}-${hy2_end_port})"
    fi

    local link="hysteria2://${encoded_pw}@${hy2_domain}:${hy2_port}?sni=${cert_domain}&insecure=1${mport_param}#Hysteria2"
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
    read -p "确认卸载 Hysteria2? [y/n]: " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        bash <(curl -fsSL https://get.hy2.sh/) --remove >/dev/null 2>&1
        rm -rf /etc/hysteria "$SSL_DIR" /etc/sysctl.d/99-hysteria2.conf /usr/local/bin/hy2
        # 清理端口跳跃规则与残留服务
        if [ -f /etc/hysteria/port_hopping.txt ]; then
            IFS=':' read -r saved_start saved_end saved_target < /etc/hysteria/port_hopping.txt 2>/dev/null || true
            if [ -n "$saved_start" ] && [ -n "$saved_end" ]; then
                if command -v iptables >/dev/null 2>&1; then
                    iptables -t nat -D PREROUTING -p udp --dport ${saved_start}:${saved_end} -j REDIRECT 2>/dev/null || true
                fi
                if command -v ip6tables >/dev/null 2>&1; then
                    ip6tables -t nat -D PREROUTING -p udp --dport ${saved_start}:${saved_end} -j REDIRECT 2>/dev/null || true
                fi
            fi
            rm -f /etc/hysteria/port_hopping.txt
        fi
        if command -v iptables >/dev/null 2>&1; then
            iptables -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT 2>/dev/null || true
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT 2>/dev/null || true
        fi
        rm -rf /etc/hy2config
        systemctl stop hysteria-iptables.service 2>/dev/null
        systemctl disable hysteria-iptables.service 2>/dev/null
        rm -f /etc/systemd/system/hysteria-iptables.service
        systemctl daemon-reload
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# --- Main ---
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
    read -p "请选择: " choice
    case "$choice" in
        1) quick_setup ;;
        2) 
            echo -e "\n${YELLOW}=== 配置文件 ===${RESET}"
            cat "$HY2_CONFIG" 2>/dev/null || echo "配置不存在"
            echo -e "\n${YELLOW}=== 节点链接 ===${RESET}"
            cat "$HY2_URL_SCHEME" 2>/dev/null
            ;;
        3) hysteria2_uninstall ;;
        4)
            systemctl restart hysteria-server.service
            echo -e "\n${GREEN}服务已重启。最近10条日志：${RESET}"
            journalctl -u hysteria-server.service -n 10 --no-pager
            ;;
        0) exit 0 ;;
        *) echo "输入无效" ;;
    esac
done

#!/bin/bash
# Hysteria2 一键安装脚本 (基于 hysteria2.py 新版优化)
# ============================================================

# ---------- 颜色定义 ----------
RED='\033[91m'
GREEN='\033[92m'
YELLOW='\033[93m'
RESET='\033[0m'

# ---------- 常量定义 ----------
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_CONFIG_DIR="/etc/hy2config"
HY2_URL_SCHEME="$HY2_CONFIG_DIR/hy2_url_scheme.txt"
SSL_DIR="/etc/ssl/private"

# ---------- Root 检测 ----------
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户执行此脚本！${RESET}"
  echo "你可以使用 'sudo -i' 进入 root 用户模式。"
  exit 1
fi

# ---------- 系统检测 ----------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
    OS_VERSION=$VERSION_ID
else
    echo "无法确定操作系统类型。"
    exit 1
fi

# 检测系统大类 (用于内核相关操作)
detect_os_type() {
  if [[ -f /etc/debian_version ]]; then
    OS_type="Debian"
  elif [[ -f /etc/redhat-release || -f /etc/centos-release || -f /etc/fedora-release || -f /etc/rocky-release ]]; then
    OS_type="CentOS"
  else
    OS_type="Unknown"
  fi
}

# ---------- 工具函数 ----------
_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

random_color() {
  local colors=("31" "32" "33" "34" "35" "36" "37")
  echo -e "\e[${colors[$((RANDOM % 7))]}m$1\e[0m"
}

# 端口验证函数 (来自 Python 版的 _validate_port)
validate_port() {
    local prompt="$1"
    local port
    while true; do
        read -p "$prompt" port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            echo "$port"
            return 0
        else
            echo -e "${RED}端口号范围为1~65535，请重新输入${RESET}" >&2
        fi
    done
}

# URL 编码函数 (纯 bash 实现，无需 python3)
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

# ---------- 依赖安装 (精简版，适配容器环境) ----------
install_packages() {
    echo "正在安装必要依赖..."
    if [ "$OS_TYPE" = "debian" ] || [ "$OS_TYPE" = "ubuntu" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq wget curl openssl iptables iproute2 ca-certificates jq >/dev/null 2>&1
    elif [ "$OS_TYPE" = "centos" ] || [ "$OS_TYPE" = "rhel" ] || [ "$OS_TYPE" = "fedora" ] || [ "$OS_TYPE" = "rocky" ]; then
        yum install -y -q epel-release >/dev/null 2>&1
        yum install -y -q wget curl openssl iptables iproute ca-certificates jq >/dev/null 2>&1
    else
        echo -e "${RED}不支持的操作系统。${RESET}"
        exit 1
    fi
    echo -e "${GREEN}依赖安装完成${RESET}"
}

# ---------- 环境初始化 (静默，无需用户交互) ----------
init_env() {
    mkdir -p "$HY2_CONFIG_DIR"
    touch "$HY2_URL_SCHEME" 2>/dev/null
    # 创建 hy2 快捷方式
    cat > /usr/local/bin/hy2 << 'SHORTCUT'
#!/bin/bash
wget -O hy2_install.sh https://raw.githubusercontent.com/seagullz4/hysteria2/main/install.sh && chmod +x hy2_install.sh && bash hy2_install.sh
SHORTCUT
    chmod 755 /usr/local/bin/hy2
}

# ---------- 网络自动优化 ----------
# 自动启用最优拥塞控制算法 (BBR3 > BBR)，优化 UDP 缓冲区
# 关闭 SYN cookies / CC-DDoS 轻量防护以减少开销
auto_optimize_network() {
    echo "正在配置网络优化..."

    # 检测可用的拥塞控制算法，优先 BBR3 > BBR
    local available_cc
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    local chosen_cc=""

    if echo "$available_cc" | grep -qw "bbr3"; then
        chosen_cc="bbr3"
    elif echo "$available_cc" | grep -qw "bbr"; then
        chosen_cc="bbr"
    fi

    # 应用 sysctl 优化
    cat > /etc/sysctl.d/99-hysteria2.conf << SYSCTL
# ===== Hysteria2 网络优化 =====
# 拥塞控制: 使用 ${chosen_cc:-bbr} (最快)
net.core.default_qdisc = fq
${chosen_cc:+net.ipv4.tcp_congestion_control = $chosen_cc}

# UDP 缓冲区优化 (Hysteria2 核心性能)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.udp_mem = 65536 131072 262144

# TCP 缓冲区优化
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 关闭 CC/DDoS 轻量防护 (减少不必要占用)
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 65535
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# 连接跟踪优化 (减少内存占用)
net.netfilter.nf_conntrack_max = 65535
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
SYSCTL

    sysctl -p /etc/sysctl.d/99-hysteria2.conf >/dev/null 2>&1

    if [ -n "$chosen_cc" ]; then
        echo -e "${GREEN}拥塞控制: ${chosen_cc} ✓ | UDP缓冲区优化 ✓ | CC/DDoS防护已关闭 ✓${RESET}"
    else
        echo -e "${YELLOW}未检测到 BBR/BBR3，已应用其他优化。建议安装 xanmod 内核以获得 BBR3${RESET}"
    fi
}

# ---------- 安装/更新 Hysteria2 ----------
hysteria2_install() {
    echo -e "${GREEN}正在安装/更新 Hysteria2 最新版本...${RESET}"
    # 设置默认终端类型，防止 tput 报错
    export TERM=xterm
    bash <(curl -fsSL https://get.hy2.sh/)
    echo -e "${GREEN}Hysteria2 安装完成${RESET}"
}

# ---------- 一键快速安装 ----------
# 自动: 安装最新版 + bing自签证书 + 获取IPv4/IPv6 + 随机密码
# 交互: 端口号 + 端口跳跃
quick_setup() {
    echo ""
    echo -e "${GREEN}========== Hysteria2 一键快速安装 ==========${RESET}"
    echo ""

    # 1. 安装 hysteria2
    hysteria2_install

    # 2. 生成 bing.com 自签证书
    echo ""
    echo -e "${GREEN}正在生成 bing.com 自签名证书...${RESET}"
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
    echo -e "${GREEN}证书已生成: $SSL_DIR/${cert_domain}.crt${RESET}"

    # 3. 获取 IP 地址 (默认双栈, 优先IPv4作为主地址)
    echo ""
    echo "正在获取服务器 IP 地址..."
    local ipv4_addr="" ipv6_addr=""

    # 获取 IPv4
    ipv4_addr=$(curl -4 -s --max-time 3 -A "Mozilla" http://ip-api.com/json/ 2>/dev/null | jq -r '.query // ""' 2>/dev/null)
    if [ -z "$ipv4_addr" ]; then
        ipv4_addr=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
    fi
    if [ -n "$ipv4_addr" ] && validate_ipv4 "$ipv4_addr"; then
        echo -e "${GREEN}IPv4: ${ipv4_addr}${RESET}"
    else
        ipv4_addr=""
        echo -e "${YELLOW}未检测到 IPv4${RESET}"
    fi

    # 获取 IPv6 (默认开启)
    ipv6_addr=$(curl -6 -s --max-time 3 -A "Mozilla" https://api.ip.sb/geoip 2>/dev/null | jq -r '.ip // ""' 2>/dev/null)
    if [ -z "$ipv6_addr" ]; then
        ipv6_addr=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null)
    fi
    if [ -n "$ipv6_addr" ] && validate_ipv6 "$ipv6_addr"; then
        echo -e "${GREEN}IPv6: ${ipv6_addr}${RESET}"
    else
        ipv6_addr=""
        echo -e "${YELLOW}未检测到 IPv6${RESET}"
    fi

    # 确定主 IP (用于链接生成)
    local hy2_domain=""
    if [ -n "$ipv4_addr" ]; then
        hy2_domain="$ipv4_addr"
    elif [ -n "$ipv6_addr" ]; then
        hy2_domain="[${ipv6_addr}]"
    else
        read -p "无法自动获取IP，请手动输入服务器IP地址：" hy2_domain
    fi

    # 4. 输入端口号
    echo ""
    local hy2_port
    hy2_port=$(validate_port "请输入端口号 (1-65535)：")

    # 5. 生成随机密码
    local hy2_passwd
    hy2_passwd=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 16)
    echo -e "${GREEN}已生成随机密码: ${hy2_passwd}${RESET}"

    # 6. 端口跳跃
    echo ""
    local jump_ports_hy2=""
    while true; do
        read -p "是否开启端口跳跃(y/n)：" jump_port_choice
        case "$jump_port_choice" in
            y|Y)
                # 自动获取默认网卡
                local interface_name
                interface_name=$(ip route list default | awk 'NR==1 {print $5}')
                if [ -z "$interface_name" ]; then
                    interface_name="eth0"
                fi
                echo "自动检测到网络接口: $interface_name"

                local first_port last_port
                while true; do
                    read -p "请输入起始端口号：" first_port
                    read -p "请输入结束端口号：" last_port
                    if ! [[ "$first_port" =~ ^[0-9]+$ ]] || ! [[ "$last_port" =~ ^[0-9]+$ ]]; then
                        echo "端口号只能为数字，请重新输入"; continue
                    fi
                    if [ "$first_port" -lt 1 ] || [ "$first_port" -gt 65535 ] || [ "$last_port" -lt 1 ] || [ "$last_port" -gt 65535 ]; then
                        echo "端口号范围为1~65535，请重新输入"; continue
                    fi
                    if [ "$first_port" -gt "$last_port" ]; then
                        echo "起始端口号不能大于结束端口号，请重新输入"; continue
                    fi
                    break
                done

                # 清理旧规则
                if [ -f "$HY2_CONFIG_DIR/jump_port_back.sh" ]; then
                    bash "$HY2_CONFIG_DIR/jump_port_back.sh" 2>/dev/null
                    rm -f "$HY2_CONFIG_DIR/jump_port_back.sh"
                fi

                # IPv4 iptables (尝试执行，并捕获错误)
                local iptables_ok=true
                if ! iptables -t nat -A PREROUTING -i "$interface_name" \
                    -p udp --dport "${first_port}:${last_port}" \
                    -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
                    echo -e "${YELLOW}警告: 容器无权设置 iptables。因为您已在 NAT 开放端口，客户端链接将保留端口跳跃参数，请确保外部 NAT 将端口域映射到 ${hy2_port}。${RESET}"
                    iptables_ok=false
                fi

                if [ "$iptables_ok" = true ]; then
                    # IPv6 iptables (默认开启)
                    local ipv6_interface="$interface_name"
                    if [ -n "$ipv6_addr" ]; then
                        if ip6tables -t nat -A PREROUTING -i "$ipv6_interface" \
                            -p udp --dport "${first_port}:${last_port}" \
                            -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
                            echo -e "${GREEN}IPv6 端口跳跃已开启${RESET}"
                        else
                            echo -e "${YELLOW}警告: 无法设置 IPv6 端口跳跃。${RESET}"
                        fi
                    fi

                    # 创建清理脚本
                    mkdir -p "$HY2_CONFIG_DIR"
                    cat > "$HY2_CONFIG_DIR/jump_port_back.sh" << CLEANUP
#!/bin/sh
iptables -t nat -D PREROUTING -i ${interface_name} -p udp --dport ${first_port}:${last_port} -j REDIRECT --to-ports ${hy2_port}
CLEANUP
                    if [ -n "$ipv6_addr" ]; then
                        echo "ip6tables -t nat -D PREROUTING -i ${ipv6_interface} -p udp --dport ${first_port}:${last_port} -j REDIRECT --to-ports ${hy2_port}" >> "$HY2_CONFIG_DIR/jump_port_back.sh"
                    fi
                    chmod 755 "$HY2_CONFIG_DIR/jump_port_back.sh"

                    # 持久化
                    if save_iptables_rules; then
                        create_iptables_persistence_service
                        echo -e "${GREEN}端口跳跃已配置并持久化${RESET}"
                    fi
                    jump_ports_hy2="&mport=${first_port}-${last_port}"
                else
                    # 容器无权限，仅生成带跳跃参数的链接 (依赖外部 NAT 转发)
                    jump_ports_hy2="&mport=${first_port}-${last_port}"
                fi
                break
                ;;
            n|N)
                jump_ports_hy2=""
                break
                ;;
            *) echo -e "${RED}输入错误请重新输入${RESET}" ;;
        esac
    done

    # 7. 写入配置文件
    mkdir -p "$(dirname "$HY2_CONFIG")"
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

ignoreClientBandwidth: false
CONFIG

    # 8. 生成链接
    echo ""
    local hy2_passwd_encoded
    hy2_passwd_encoded=$(urlencode "$hy2_passwd")
    local hy2_v2ray="hysteria2://${hy2_passwd_encoded}@${hy2_domain}:${hy2_port}?sni=${cert_domain}&insecure=1${jump_ports_hy2}#Hysteria2"

    # 保存链接
    mkdir -p "$HY2_CONFIG_DIR"
    echo "${hy2_v2ray}" > "$HY2_URL_SCHEME"

    # 显示二维码 (已移除)

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}  Hysteria2 安装配置完成！${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo ""
    echo -e "  端口:     ${hy2_port}"
    echo -e "  密码:     ${hy2_passwd}"
    echo -e "  IPv4:     ${ipv4_addr:-无}"
    echo -e "  IPv6:     ${ipv6_addr:-无}"
    echo -e "  证书:     bing.com 自签"
    [ -n "$jump_ports_hy2" ] && echo -e "  端口跳跃: ${first_port}-${last_port}"
    echo ""
    echo -e "${RED}hy2链接: ${hy2_v2ray}${RESET}"
    echo -e "请使用 v2ray/nekobox/v2rayNG/nekoray/surge 导入"
    echo ""

    # 如果有 IPv6，也生成一条 IPv6 链接
    if [ -n "$ipv4_addr" ] && [ -n "$ipv6_addr" ]; then
        local hy2_v2ray_v6="hysteria2://${hy2_passwd_encoded}@[${ipv6_addr}]:${hy2_port}?sni=${cert_domain}&insecure=1${jump_ports_hy2}#Hysteria2-IPv6"
        echo -e "${RED}IPv6链接: ${hy2_v2ray_v6}${RESET}"
        echo "${hy2_v2ray_v6}" >> "$HY2_URL_SCHEME"
        echo ""
    fi

    # 9. 启动服务
    systemctl enable --now hysteria-server.service 2>/dev/null
    systemctl restart hysteria-server.service 2>/dev/null
    echo -e "${GREEN}Hysteria2 服务已启动${RESET}"
}

# ---------- 卸载 Hysteria2 ----------
# 完整卸载逻辑 (来自 Python 版，包含 iptables 清理)
hysteria2_uninstall() {
    while true; do
        read -p "是否进行卸载hysteria2 [y/n]：" choice
        case "$choice" in
            y|Y)
                # 使用官方脚本卸载 (Python 版改进)
                bash <(curl -fsSL https://get.hy2.sh/) --remove

                # 停止并禁用 iptables 恢复服务
                systemctl stop hysteria-iptables.service 2>/dev/null
                systemctl disable hysteria-iptables.service 2>/dev/null

                # 清理 iptables 规则
                if [ -f "$HY2_CONFIG_DIR/jump_port_back.sh" ]; then
                    bash "$HY2_CONFIG_DIR/jump_port_back.sh" 2>/dev/null
                fi

                # 删除所有配置文件和服务 (来自 Python 版的完整清理列表)
                rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service
                rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service
                rm -f /etc/systemd/system/hysteria-iptables.service
                rm -f "$HY2_CONFIG_DIR/iptables-rules.v4"
                rm -f "$HY2_CONFIG_DIR/iptables-rules.v6"
                rm -rf /etc/hysteria
                rm -rf "$SSL_DIR"
                rm -rf "$HY2_CONFIG_DIR"
                rm -f /usr/local/bin/hy2

                # 兼容旧版清理
                systemctl stop hysteria.service 2>/dev/null
                systemctl disable hysteria.service 2>/dev/null
                rm -f /etc/systemd/system/hysteria.service
                systemctl stop ipppp.service 2>/dev/null
                systemctl disable ipppp.service 2>/dev/null
                rm -f /etc/systemd/system/ipppp.service
                rm -rf /root/hy3

                systemctl daemon-reload
                echo -e "${GREEN}卸载hysteria2完成${RESET}"
                exit 0
                ;;
            n|N)
                echo "已取消卸载hysteria2"
                break
                ;;
            *)
                echo -e "${RED}输入错误，请重新输入${RESET}"
                ;;
        esac
    done
}

# ---------- 服务管理 ----------
# 来自 Python 版的完整服务管理菜单
server_manage() {
    while true; do
        echo "1. 启动服务(自动设置为开机自启动)"
        echo "2. 停止服务"
        echo "3. 重启服务"
        echo "4. 查看服务状态"
        echo "5. 日志查询"
        echo "6. 查看hy2版本具体信息"
        echo "0. 返回"
        read -p "请输入选项：" choice
        case "$choice" in
            1) systemctl enable --now hysteria-server.service ;;
            2) systemctl stop hysteria-server.service ;;
            3) systemctl restart hysteria-server.service ;;
            4)
                echo -e "${RED}输入q退出查看${RESET}"
                systemctl status hysteria-server.service
                ;;
            5) journalctl --no-pager -e -u hysteria-server.service ;;
            6) /usr/local/bin/hysteria version 2>/dev/null || echo "未安装 hysteria2" ;;
            0) break ;;
            *) echo -e "${RED}输入错误，请重新输入${RESET}" ;;
        esac
    done
}

# ---------- iptables 持久化 ----------
# 来自 Python 版的 create_iptables_persistence_service
create_iptables_persistence_service() {
    # 创建恢复脚本
    cat > "$HY2_CONFIG_DIR/restore-iptables.sh" << 'RESTORE_SCRIPT'
#!/bin/bash
# Hysteria2 iptables rules restoration script
set -e

# 验证并恢复IPv4规则
if [ -f /etc/hy2config/iptables-rules.v4 ] && [ -s /etc/hy2config/iptables-rules.v4 ]; then
    if iptables-restore -t < /etc/hy2config/iptables-rules.v4 2>/dev/null; then
        iptables-restore < /etc/hy2config/iptables-rules.v4
        echo "IPv4 iptables规则恢复成功" | logger -t hysteria2-iptables
    else
        echo "IPv4 iptables规则文件无效，跳过恢复" | logger -t hysteria2-iptables
    fi
fi

# 验证并恢复IPv6规则
if [ -f /etc/hy2config/iptables-rules.v6 ] && [ -s /etc/hy2config/iptables-rules.v6 ]; then
    if ip6tables-restore -t < /etc/hy2config/iptables-rules.v6 2>/dev/null; then
        ip6tables-restore < /etc/hy2config/iptables-rules.v6
        echo "IPv6 ip6tables规则恢复成功" | logger -t hysteria2-iptables
    else
        echo "IPv6 ip6tables规则文件无效，跳过恢复" | logger -t hysteria2-iptables
    fi
fi

exit 0
RESTORE_SCRIPT
    chmod 755 "$HY2_CONFIG_DIR/restore-iptables.sh"

    # 创建 systemd 服务
    cat > /etc/systemd/system/hysteria-iptables.service << 'SERVICE'
[Unit]
Description=Restore Hysteria2 iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/hy2config/restore-iptables.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable hysteria-iptables.service
    echo "已创建iptables持久化服务"
}

# 保存 iptables 规则 (来自 Python 版)
save_iptables_rules() {
    mkdir -p "$HY2_CONFIG_DIR"
    if iptables-save > "$HY2_CONFIG_DIR/iptables-rules.v4" 2>/dev/null; then
        echo "已保存IPv4 iptables规则"
    else
        echo -e "${RED}保存IPv4 iptables规则失败${RESET}"
        return 1
    fi
    if ip6tables-save > "$HY2_CONFIG_DIR/iptables-rules.v6" 2>/dev/null; then
        echo "已保存IPv6 ip6tables规则"
    else
        echo -e "${RED}保存IPv6 ip6tables规则失败${RESET}"
        return 1
    fi
    return 0
}

# ---------- IP 获取函数 ----------
# Warp 检测和备用方案，纯 bash IP 验证

# IPv4 地址验证 (纯 bash，无需 python3)
validate_ipv4() {
    local ip="$1"
    # 检查格式: 4组数字用点分隔，每组 0-255
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    local IFS='.'
    local -a octets=($ip)
    [ ${#octets[@]} -ne 4 ] && return 1
    local octet
    for octet in "${octets[@]}"; do
        # 去除前导零后检查范围
        if [ "$octet" -lt 0 ] 2>/dev/null || [ "$octet" -gt 255 ] 2>/dev/null; then
            return 1
        fi
        # 纯数字检查 (防止空字段)
        [[ ! "$octet" =~ ^[0-9]+$ ]] && return 1
        [ "$octet" -gt 255 ] && return 1
    done
    return 0
}

# IPv6 地址验证 (纯 bash，无需 python3)
validate_ipv6() {
    local ip="$1"
    # 去除可能的方括号
    ip="${ip#[}"
    ip="${ip%]}"
    # 基本格式检查: 只允许十六进制字符、冒号和一个可选的 ::
    if [[ ! "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
        return 1
    fi
    # 不允许超过一个 ::
    local double_colon_count
    double_colon_count=$(echo "$ip" | grep -o '::' | wc -l)
    if [ "$double_colon_count" -gt 1 ]; then
        return 1
    fi
    # 按冒号分割，检查组数 (无 :: 时应为8组，有 :: 时最多8组)
    local IFS=':'
    local -a groups=($ip)
    if [ "$double_colon_count" -eq 0 ] && [ ${#groups[@]} -ne 8 ]; then
        return 1
    fi
    if [ ${#groups[@]} -gt 8 ]; then
        return 1
    fi
    # 检查每组长度不超过4个十六进制字符
    local group
    for group in "${groups[@]}"; do
        if [ -n "$group" ] && [ ${#group} -gt 4 ]; then
            return 1
        fi
    done
    return 0
}

get_ipv4_info() {
    local ip_data isp ip

    ip_data=$(curl -4 -s --max-time 3 -A "Mozilla" http://ip-api.com/json/ 2>/dev/null)
    if [ -n "$ip_data" ]; then
        isp=$(echo "$ip_data" | jq -r '.isp // ""' 2>/dev/null)
        if echo "$isp" | grep -qi "cloudflare"; then
            echo "检测到Warp，请输入正确的服务器 IPv4 地址"
            while true; do
                read -p "请输入IPv4地址：" ip
                if validate_ipv4 "$ip"; then
                    break
                else
                    echo -e "${RED}无效的IPv4地址，请重新输入${RESET}"
                fi
            done
        else
            ip=$(echo "$ip_data" | jq -r '.query // ""' 2>/dev/null)
        fi
    fi

    # 备用方案 (来自 Python 版)
    if [ -z "$ip" ]; then
        ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
    fi

    if [ -z "$ip" ] || ! validate_ipv4 "$ip"; then
        while true; do
            read -p "无法自动获取IP，请手动输入服务器的IPv4地址：" ip
            if validate_ipv4 "$ip"; then
                break
            else
                echo -e "${RED}无效的IPv4地址，请重新输入${RESET}"
            fi
        done
    fi

    echo "IPV4 WAN IP: $ip" >&2
    echo "$ip"
}

get_ipv6_info() {
    local ip_data isp ip

    ip_data=$(curl -6 -s --max-time 3 -A "Mozilla" https://api.ip.sb/geoip 2>/dev/null)
    if [ -n "$ip_data" ]; then
        isp=$(echo "$ip_data" | jq -r '.isp // ""' 2>/dev/null)
        if echo "$isp" | grep -qi "cloudflare"; then
            echo "检测到Warp，请输入正确的服务器 IPv6 地址"
            while true; do
                read -p "请输入IPv6地址：" ip
                if validate_ipv6 "$ip"; then
                    break
                else
                    echo -e "${RED}无效的IPv6地址，请重新输入${RESET}"
                fi
            done
        else
            ip=$(echo "$ip_data" | jq -r '.ip // ""' 2>/dev/null)
        fi
    fi

    # 备用方案
    if [ -z "$ip" ]; then
        ip=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null)
    fi

    if [ -z "$ip" ] || ! validate_ipv6 "$ip"; then
        while true; do
            read -p "无法自动获取IP，请手动输入服务器的IPv6地址：" ip
            if validate_ipv6 "$ip"; then
                break
            else
                echo -e "${RED}无效的IPv6地址，请重新输入${RESET}"
            fi
        done
    fi

    echo "IPV6 WAN IP: [$ip]" >&2
    echo "[$ip]"
}

# ---------- 证书生成 ----------
# 来自 Python 版的 generate_certificate，增加域名格式验证
generate_certificate() {
    while true; do
        read -p "请输入要用于自签名证书的域名（默认为 bing.com）: " user_domain
        local cert_domain="${user_domain:-bing.com}"

        # 域名格式验证 (来自 Python 版)
        if ! echo "$cert_domain" | grep -qE '^[a-zA-Z0-9.-]+$'; then
            echo "无效的域名格式，请输入有效的域名！"
            continue
        fi

        mkdir -p "$SSL_DIR"

        # 生成 EC 参数文件
        openssl ecparam -name prime256v1 -out "$SSL_DIR/ec_param.pem"

        # 生成证书和私钥
        openssl req -x509 -nodes -newkey "ec:$SSL_DIR/ec_param.pem" \
            -keyout "$SSL_DIR/${cert_domain}.key" \
            -out "$SSL_DIR/${cert_domain}.crt" \
            -subj "/CN=${cert_domain}" -days 36500

        # 安全权限设置 (来自 Python 版，比旧版 chmod 777 安全)
        chmod 644 "$SSL_DIR/${cert_domain}.key"
        chmod 644 "$SSL_DIR/${cert_domain}.crt"
        chmod 755 "$SSL_DIR"
        # 尝试将证书文件所有权交给 hysteria 用户
        chown root:hysteria "$SSL_DIR/${cert_domain}.key" "$SSL_DIR/${cert_domain}.crt" 2>/dev/null

        echo "自签名证书和私钥已生成！"
        echo "证书文件已保存到 $SSL_DIR/${cert_domain}.crt"
        echo "私钥文件已保存到 $SSL_DIR/${cert_domain}.key"

        CERT_DOMAIN="$cert_domain"
        return 0
    done
}

# ---------- 配置管理 ----------
# 来自 Python 版的 hysteria2_config，完整的配置向导
hysteria2_config() {
    while true; do
        echo "1. hy2配置查看"
        echo "2. hy2配置一键修改"
        echo "3. 手动修改hy2配置"
        echo "4. 网络优化(重新应用BBR/缓冲区优化)"
        echo "0. 返回"
        read -p "请输入选项：" choice
        case "$choice" in
            1)
                clear
                echo "您的官方配置文件为："
                echo ""
                if [ -f "$HY2_CONFIG" ]; then
                    cat "$HY2_CONFIG"
                else
                    echo -e "${RED}未找到配置文件${RESET}"
                fi
                if [ -f "$HY2_URL_SCHEME" ]; then
                    cat "$HY2_URL_SCHEME"
                fi
                echo ""
                echo "clash,surge,singbox模板在 $HY2_CONFIG_DIR/ 下，请自行查看"
                echo ""
                ;;
            2)
                # --- 端口 ---
                local hy2_port
                hy2_port=$(validate_port "请输入端口号：")

                # --- 用户名 ---
                read -p "请输入您用户名：" hy2_username
                hy2_username=$(urlencode "$hy2_username")

                # --- 密码 ---
                read -p "请输入您的强密码：" hy2_passwd

                # --- 伪装域名 ---
                read -p "请输入您需要伪装成的域名(请在前面加上https://)：" hy2_url

                # --- Brutal 模式 (来自 Python 版新增) ---
                local brutal_mode
                while true; do
                    read -p "是否开启Brutal模式(默认不推荐开启)？[y/n]：" hy2_brutal
                    case "$hy2_brutal" in
                        y|Y) brutal_mode="true"; break ;;
                        n|N) brutal_mode="false"; break ;;
                        *) echo -e "${RED}输入错误请重新输入${RESET}" ;;
                    esac
                done

                # --- 混淆模式 (来自 Python 版新增) ---
                local obfs_mode="" obfs_scheme="" obfs_passwd_encoded=""
                while true; do
                    read -p "是否开启混淆模式(默认不推荐开启，开启将会失去伪装能力)？[y/n]：" hy2_obfs
                    case "$hy2_obfs" in
                        y|Y)
                            read -p "请输入您的混淆密码：" obfs_passwd
                            obfs_mode="obfs:\n  type: salamander\n  \n  salamander:\n    password: ${obfs_passwd}"
                            obfs_passwd_encoded=$(urlencode "$obfs_passwd")
                            obfs_scheme="&obfs=salamander&obfs-password=${obfs_passwd_encoded}"
                            break
                            ;;
                        n|N)
                            obfs_mode=""
                            obfs_scheme=""
                            break
                            ;;
                        *) echo -e "${RED}输入错误请重新输入${RESET}" ;;
                    esac
                done

                # --- 协议嗅探 (来自 Python 版新增) ---
                local sniff_mode=""
                while true; do
                    read -p "是否开启协议嗅探 (Sniff)[y/n]：" hy2_sniff
                    case "$hy2_sniff" in
                        y|Y)
                            sniff_mode="sniff:\n  enable: true\n  timeout: 2s\n  rewriteDomain: false\n  tcpPorts: 80,443,8000-9000\n  udpPorts: all"
                            break
                            ;;
                        n|N) sniff_mode=""; break ;;
                        *) echo -e "${RED}输入错误请重新输入${RESET}" ;;
                    esac
                done

                # --- 端口跳跃 ---
                local jump_ports_hy2=""
                while true; do
                    read -p "是否开启端口跳跃(y/n)：" jump_port_choice
                    case "$jump_port_choice" in
                        y|Y)
                            echo "请选择你的v4网络接口（默认eth0, 一般不是lo接口）"
                            # 显示可用网络接口 (来自 Python 版)
                            ip -o link show | awk -F': ' '{print "  - "$2}'

                            read -p "请输入您的网络接口名称：" interface_name

                            # 端口输入循环验证 (来自 Python 版)
                            local first_port last_port
                            while true; do
                                read -p "请输入起始端口号：" first_port
                                read -p "请输入结束端口号：" last_port
                                if ! [[ "$first_port" =~ ^[0-9]+$ ]] || ! [[ "$last_port" =~ ^[0-9]+$ ]]; then
                                    echo "端口号只能为数字，请重新输入"
                                    continue
                                fi
                                if [ "$first_port" -lt 1 ] || [ "$first_port" -gt 65535 ]; then
                                    echo "起始端口号范围为1~65535，请重新输入"
                                    continue
                                fi
                                if [ "$last_port" -lt 1 ] || [ "$last_port" -gt 65535 ]; then
                                    echo "结束端口号范围为1~65535，请重新输入"
                                    continue
                                fi
                                if [ "$first_port" -gt "$last_port" ]; then
                                    echo "起始端口号不能大于结束端口号，请重新输入"
                                    continue
                                fi
                                break
                            done

                            # IPv6 端口跳跃 (来自 Python 版新增)
                            local has_ipv6=false ipv6_interface=""
                            while true; do
                                read -p "是否开启ipv6端口跳跃(y/n)：" jump_port_ipv6
                                case "$jump_port_ipv6" in
                                    y|Y)
                                        echo "请选择你的v6网络接口:"
                                        ip -o link show | awk -F': ' '{print "  - "$2}'
                                        read -p "请输入您的v6网络接口名称：" ipv6_interface
                                        ip6tables -t nat -A PREROUTING -i "$ipv6_interface" \
                                            -p udp --dport "${first_port}:${last_port}" \
                                            -j REDIRECT --to-ports "$hy2_port"
                                        has_ipv6=true
                                        break
                                        ;;
                                    n|N) has_ipv6=false; break ;;
                                    *) echo -e "${RED}输入错误请重新输入${RESET}" ;;
                                esac
                            done

                            # 检查并执行旧的清理脚本
                            if [ -f "$HY2_CONFIG_DIR/jump_port_back.sh" ]; then
                                bash "$HY2_CONFIG_DIR/jump_port_back.sh" 2>/dev/null
                                rm -f "$HY2_CONFIG_DIR/jump_port_back.sh"
                            fi

                            # IPv4 iptables (尝试执行，并捕获错误)
                            local iptables_ok=true
                            if ! iptables -t nat -A PREROUTING -i "$interface_name" \
                                -p udp --dport "${first_port}:${last_port}" \
                                -j REDIRECT --to-ports "$hy2_port" 2>/dev/null; then
                                echo -e "${YELLOW}警告: 容器无权设置 iptables。因为您已在 NAT 开放端口，客户端链接将保留端口跳跃参数，请确保外部 NAT 将端口域映射到 ${hy2_port}。${RESET}"
                                iptables_ok=false
                            fi

                            if [ "$iptables_ok" = true ]; then
                                # 创建清理脚本 (来自 Python 版)
                                mkdir -p "$HY2_CONFIG_DIR"
                                cat > "$HY2_CONFIG_DIR/jump_port_back.sh" << CLEANUP
#!/bin/sh
# Hysteria2 port hopping cleanup script
iptables -t nat -D PREROUTING -i ${interface_name} -p udp --dport ${first_port}:${last_port} -j REDIRECT --to-ports ${hy2_port}
CLEANUP
                            if [ "$has_ipv6" = true ] && [ -n "$ipv6_interface" ]; then
                                echo "ip6tables -t nat -D PREROUTING -i ${ipv6_interface} -p udp --dport ${first_port}:${last_port} -j REDIRECT --to-ports ${hy2_port}" >> "$HY2_CONFIG_DIR/jump_port_back.sh"
                            fi
                            chmod 755 "$HY2_CONFIG_DIR/jump_port_back.sh"

                                # iptables 持久化 (来自 Python 版新增)
                                echo "正在保存iptables规则以实现重启后自动恢复..."
                                if save_iptables_rules; then
                                    create_iptables_persistence_service
                                    echo -e "${GREEN}端口跳跃规则已配置并持久化，系统重启后将自动恢复${RESET}"
                                else
                                    echo -e "${RED}警告：iptables规则已应用但持久化失败，系统重启后可能需要重新配置${RESET}"
                                fi

                                jump_ports_hy2="&mport=${first_port}-${last_port}"
                            else
                                # 容器无权限，仅生成带跳跃参数的链接 (依赖外部 NAT 转发)
                                jump_ports_hy2="&mport=${first_port}-${last_port}"
                            fi
                            break
                            ;;
                        n|N)
                            jump_ports_hy2=""
                            break
                            ;;
                        *) echo -e "${RED}输入错误请重新输入${RESET}" ;;
                    esac
                done

                # --- 证书选择 ---
                local hy2_domain="" domain_name="" insecure=""
                while true; do
                    echo "1. 自动申请域名证书"
                    echo "2. 使用自签证书(不需要域名)"
                    echo "3. 手动选择证书路径"
                    read -p "请输入您选项：" cert_choice
                    case "$cert_choice" in
                        1)
                            # ACME 证书
                            read -p "请输入您自己的域名：" hy2_domain
                            domain_name="$hy2_domain"
                            read -p "请输入您的邮箱：" hy2_email

                            # ACME DNS 配置 (来自 Python 版新增，支持多个 DNS 提供商)
                            local acme_dns=""
                            while true; do
                                read -p "是否设置acme dns配置(如果不知道是什么请不要选择) [y/n]:" choice_acme
                                case "$choice_acme" in
                                    y|Y)
                                        while true; do
                                            clear
                                            echo "dns名称："
                                            echo "1.Cloudflare"
                                            echo "2.Duck DNS"
                                            echo "3.Gandi.net"
                                            echo "4.Godaddy"
                                            echo "5.Name.com"
                                            echo "6.Vultr"
                                            read -p "请输入您的选项：" dns_name
                                            case "$dns_name" in
                                                1)
                                                    read -p "请输入Cloudflare的Global api_token:" dns_token
                                                    acme_dns="type: dns\n  dns:\n    name: cloudflare\n    config:\n      cloudflare_api_token: ${dns_token}"
                                                    break ;;
                                                2)
                                                    read -p "请输入Duck DNS的api_token:" dns_token
                                                    read -p "请输入Duck DNS的override_domain:" override_domain
                                                    acme_dns="type: dns\n  dns:\n    name: duckdns\n    config:\n      duckdns_api_token: ${dns_token}\n    duckdns_override_domain: ${override_domain}"
                                                    break ;;
                                                3)
                                                    read -p "请输入Gandi.net的api_token:" dns_token
                                                    acme_dns="type: dns\n  dns:\n    name: gandi\n    config:\n      gandi_api_token: ${dns_token}"
                                                    break ;;
                                                4)
                                                    read -p "请输入Godaddy的api_token:" dns_token
                                                    acme_dns="type: dns\n  dns:\n    name: godaddy\n    config:\n      godaddy_api_token: ${dns_token}"
                                                    break ;;
                                                5)
                                                    read -p "请输入Name.com的namedotcom_token:" dns_token
                                                    read -p "请输入Name.com的namedotcom_user:" dns_user
                                                    read -p "请输入Name.com的namedotcom_server:" namedotcom_server
                                                    acme_dns="type: dns\n  dns:\n    name: namedotcom\n    config:\n      namedotcom_token: ${dns_token}\n      namedotcom_user: ${dns_user}\n      namedotcom_server: ${namedotcom_server}"
                                                    break ;;
                                                6)
                                                    read -p "请输入Vultr的API Key:" dns_token
                                                    acme_dns="type: dns\n  dns:\n    name: vultr\n    config:\n      vultr_api_key: ${dns_token}"
                                                    break ;;
                                                *) echo "输入错误，请重新输入" ;;
                                            esac
                                        done
                                        break ;;
                                    n|N) acme_dns=""; break ;;
                                    *) echo "输入错误，请重新输入" ;;
                                esac
                            done

                            insecure="&insecure=0"

                            # 写入配置文件
                            cat > "$HY2_CONFIG" << ACME_CONFIG
listen: :${hy2_port}

acme:
  domains:
    - ${hy2_domain}
  email: ${hy2_email}
  $(echo -e "$acme_dns")

auth:
  type: password
  password: ${hy2_passwd}

masquerade:
  type: proxy
  proxy:
    url: ${hy2_url}
    rewriteHost: true

ignoreClientBandwidth: ${brutal_mode}

$(echo -e "$obfs_mode")
$(echo -e "$sniff_mode")
ACME_CONFIG
                            break
                            ;;

                        2)
                            # 自签证书
                            generate_certificate
                            domain_name="$CERT_DOMAIN"

                            while true; do
                                echo "1. ipv4模式"
                                echo "2. ipv6模式"
                                read -p "请输入您的选项：" ip_mode
                                case "$ip_mode" in
                                    1) hy2_domain=$(get_ipv4_info); break ;;
                                    2) hy2_domain=$(get_ipv6_info); break ;;
                                    *) echo -e "${RED}输入错误，请重新输入！${RESET}" ;;
                                esac
                            done

                            insecure="&insecure=1"

                            cat > "$HY2_CONFIG" << SELF_SIGN_CONFIG
listen: :${hy2_port}

tls:
  cert: ${SSL_DIR}/${domain_name}.crt
  key: ${SSL_DIR}/${domain_name}.key

auth:
  type: password
  password: ${hy2_passwd}

masquerade:
  type: proxy
  proxy:
    url: ${hy2_url}
    rewriteHost: true

ignoreClientBandwidth: ${brutal_mode}

$(echo -e "$obfs_mode")
$(echo -e "$sniff_mode")
SELF_SIGN_CONFIG
                            break
                            ;;

                        3)
                            # 手动证书路径
                            read -p "请输入您的证书路径：" hy2_cert
                            read -p "请输入您的密钥路径：" hy2_key
                            read -p "请输入您自己的域名：" hy2_domain
                            domain_name="$hy2_domain"
                            insecure="&insecure=0"

                            cat > "$HY2_CONFIG" << MANUAL_CERT_CONFIG
listen: :${hy2_port}

tls:
  cert: ${hy2_cert}
  key: ${hy2_key}

auth:
  type: password
  password: ${hy2_passwd}

masquerade:
  type: proxy
  proxy:
    url: ${hy2_url}
    rewriteHost: true

ignoreClientBandwidth: ${brutal_mode}

$(echo -e "$obfs_mode")
$(echo -e "$sniff_mode")
MANUAL_CERT_CONFIG
                            break
                            ;;
                        *)
                            echo -e "${RED}输入错误，请重新输入${RESET}"
                            ;;
                    esac
                done

                # --- 生成链接 (来自 Python 版) ---
                clear
                local hy2_passwd_encoded
                hy2_passwd_encoded=$(urlencode "$hy2_passwd")
                local hy2_v2ray="hysteria2://${hy2_passwd_encoded}@${hy2_domain}:${hy2_port}?sni=${domain_name}${obfs_scheme}${insecure}${jump_ports_hy2}#${hy2_username}"

                # 显示二维码 (来自 Python 版新增)
                echo "您的 v2ray 二维码为："
                echo ""
                sleep 1
                if _exists qrencode; then
                    echo "$hy2_v2ray" | qrencode -s 1 -m 1 -t ANSI256 -o - 2>/dev/null
                else
                    echo "(未安装 qrencode，跳过二维码显示)"
                fi

                echo ""
                echo -e "${RED}您的hy2链接为: ${hy2_v2ray}${RESET}"
                echo -e "${RED}请使用v2ray/nekobox/v2rayNG/nekoray软件导入${RESET}"
                echo ""

                # 保存链接
                mkdir -p "$HY2_CONFIG_DIR"
                echo "您的 v2ray hy2配置链接为：${hy2_v2ray}" > "$HY2_URL_SCHEME"

                # 下载订阅模板 (来自 Python 版新增)
                echo "是否需要下载clash/singbox/surge订阅链接生成的模板文件用于导入软件，需要调用到外部链接（您的订阅信息不会被泄露）"
                read -p "请输入您的选项（请输入 y/n ）：" dl_choice
                case "$dl_choice" in
                    y|Y)
                        echo "正在下载 clash,sing-box,surge 配置文件到 $HY2_CONFIG_DIR/"
                        local hy2_v2ray_url
                        hy2_v2ray_url=$(urlencode "$hy2_v2ray")
                        local url_rule="&ua=&selectedRules=%5B%22Location%3ACN%22%2C%22Private%22%2C%22Non-China%22%2C%22Github%22%2C%22Google%22%2C%22Youtube%22%2C%22AI+Services%22%2C%22Telegram%22%2C%22Ad+Block%22%5D&customRules=%5B%5D&include_auto_select=false"
                        curl -s -o "$HY2_CONFIG_DIR/clash.yaml" "https://sub.baibaicat.site/clash?config=${hy2_v2ray_url}${url_rule}"
                        curl -s -o "$HY2_CONFIG_DIR/sing-box.yaml" "https://sub.baibaicat.site/singbox?config=${hy2_v2ray_url}${url_rule}"
                        curl -s -o "$HY2_CONFIG_DIR/surge.yaml" "https://sub.baibaicat.site/surge?config=${hy2_v2ray_url}${url_rule}"
                        echo -e "${RED}clash,sing-box,surge配置文件已保存到 $HY2_CONFIG_DIR/ 目录下 ！！${RESET}"
                        ;;
                    *)
                        echo "跳过生成订阅链接"
                        ;;
                esac

                # 启动服务 (使用官方 systemd 服务名)
                systemctl enable --now hysteria-server.service
                systemctl restart hysteria-server.service
                ;;

            3)
                if _exists nano; then
                    echo -e "${RED}正在使用nano编辑器进行手动修改，输入完成后按Ctrl+X保存退出${RESET}"
                    nano "$HY2_CONFIG"
                else
                    echo -e "${RED}正在使用vi编辑器进行手动修改，输入完成后按:wq保存退出${RESET}"
                    vi "$HY2_CONFIG"
                fi
                systemctl enable --now hysteria-server.service
                systemctl restart hysteria-server.service
                echo "hy2服务已启动"
                ;;

            4)
                # 网络优化 (内置，无外部依赖)
                auto_optimize_network
                ;;
            0) break ;;
            *) echo -e "${RED}请重新输入${RESET}" ;;
        esac
    done
}

# ---------- 版本检测 ----------
check_hysteria2_version() {
    local version
    version=$(/usr/local/bin/hysteria version 2>/dev/null | grep '^Version' | grep -o 'v[.0-9]*')
    if [ -n "$version" ]; then
        echo "当前hysteria2版本为：${version}"
    else
        echo "未找到hysteria2版本"
    fi
}

# ============================================================
#                       主程序
# ============================================================

install_packages
init_env
auto_optimize_network

while true; do
    clear
    echo -e "${RED}HELLO HYSTERIA2 !${RESET}  (输入hy2快捷启动)"
    check_hysteria2_version
    echo ""
    echo "1. 一键安装 (自动安装+bing证书+获取IP)"
    echo "2. 卸载hysteria2"
    echo "3. 配置管理 (查看/修改/高级配置)"
    echo "4. 服务管理 (启停/重启/日志)"
    echo "0. 退出"
    read -p "请输入选项：" main_choice
    case "$main_choice" in
        1)
            clear
            quick_setup
            echo ""
            read -p "按回车键返回主菜单..." _
            ;;
        2)
            clear
            hysteria2_uninstall
            ;;
        3)
            clear
            hysteria2_config
            ;;
        4)
            clear
            check_hysteria2_version
            server_manage
            ;;
        0)
            echo "已退出"
            exit 0
            ;;
        *)
            echo -e "${RED}输入错误，请重新输入${RESET}"
            sleep 1
            ;;
    esac
done

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

# URL 编码函数
urlencode() {
    local string="$1"
    python3 -c "import urllib.parse; print(urllib.parse.quote('$string'))" 2>/dev/null || echo "$string"
}

# ---------- 依赖安装 ----------
install_packages() {
    echo "正在安装必要依赖..."
    if [ "$OS_TYPE" = "debian" ] || [ "$OS_TYPE" = "ubuntu" ]; then
        apt update -qq
        apt install -y -qq wget curl sed sudo openssl net-tools psmisc procps iptables iproute2 ca-certificates jq qrencode >/dev/null 2>&1
    elif [ "$OS_TYPE" = "centos" ] || [ "$OS_TYPE" = "rhel" ] || [ "$OS_TYPE" = "fedora" ] || [ "$OS_TYPE" = "rocky" ]; then
        yum install -y -q epel-release >/dev/null 2>&1
        yum install -y -q wget curl sed sudo openssl net-tools psmisc procps-ng iptables iproute ca-certificates jq qrencode >/dev/null 2>&1
    else
        echo -e "${RED}不支持的操作系统。${RESET}"
        exit 1
    fi
    echo -e "${GREEN}依赖安装完成${RESET}"
}

# ---------- 条款同意 ----------
agree_treaty() {
    local agree_file="$HY2_CONFIG_DIR/agree.txt"
    if [ -f "$agree_file" ]; then
        echo "你已经同意过条款，谢谢"
        create_shortcut
        return
    fi

    while true; do
        echo "我同意使用本程序必须遵守部署服务器所在地、所在国家和用户所在国家的法律法规, 程序作者不对使用者任何不当行为负责。且本程序仅供学习交流使用，不得用于任何商业用途。"
        read -p "是否同意并阅读(在上面)安装hysteria2相关条款 [y/n]：" choose
        case "$choose" in
            y|Y)
                mkdir -p "$HY2_CONFIG_DIR"
                touch "$agree_file"
                touch "$HY2_URL_SCHEME"
                create_shortcut
                break
                ;;
            n|N)
                echo "请同意此条款进行安装"
                exit 0
                ;;
            *)
                echo -e "${RED}请输入正确选项！${RESET}"
                ;;
        esac
    done
}

# 创建 hy2 快捷方式 (来自 Python 版)
create_shortcut() {
    cat > /usr/local/bin/hy2 << 'SHORTCUT'
#!/bin/bash
wget -O hy2_install.sh https://raw.githubusercontent.com/seagullz4/hysteria2/main/install.sh && chmod +x hy2_install.sh && bash hy2_install.sh
SHORTCUT
    chmod 755 /usr/local/bin/hy2
}

# ---------- 安装/更新 Hysteria2 ----------
# 使用官方安装脚本 (来自 Python 版的改进)
hysteria2_install() {
    while true; do
        read -p "是否安装/更新hysteria2 [y/n]：" choice
        case "$choice" in
            y|Y)
                echo "1. 默认安装最新版本"
                echo "2. 安装指定版本"
                read -p "请输入选项：" sub_choice
                case "$sub_choice" in
                    1)
                        # 使用官方脚本安装 (Python 版改进)
                        bash <(curl -fsSL https://get.hy2.sh/)
                        echo "--------------"
                        echo -e "${RED}hysteria2安装完成,请进行配置一键修改${RESET}"
                        echo "--------------"
                        hysteria2_config
                        break
                        ;;
                    2)
                        read -p "请输入您需要安装的版本号(直接输入版本号数字即可，不需要加v，如2.6.0)：" ver
                        # 版本号格式验证 (来自 Python 版)
                        if ! echo "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
                            echo -e "${RED}版本号格式无效，请输入如 2.6.0 的格式${RESET}"
                            continue
                        fi
                        bash <(curl -fsSL https://get.hy2.sh/) --version "v${ver}"
                        echo "--------------"
                        echo -e "${RED}hysteria2指定${ver}版本安装完成,请输入选项进行配置一键修改！！！${RESET}"
                        echo "--------------"
                        hysteria2_config
                        break
                        ;;
                    *)
                        echo -e "${RED}输入错误，请重新输入${RESET}"
                        ;;
                esac
                ;;
            n|N)
                echo "已取消安装hysteria2"
                break
                ;;
            *)
                echo -e "${RED}输入错误，请重新输入${RESET}"
                ;;
        esac
    done
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
# 来自 Python 版，增加了 Warp 检测和备用方案

# IPv4 地址验证
validate_ipv4() {
    local ip="$1"
    python3 -c "
import ipaddress
try:
    ipaddress.IPv4Address('$ip')
    exit(0)
except:
    exit(1)
" 2>/dev/null
}

# IPv6 地址验证
validate_ipv6() {
    local ip="$1"
    python3 -c "
import ipaddress
try:
    ipaddress.IPv6Address('$ip')
    exit(0)
except:
    exit(1)
" 2>/dev/null
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
        echo "4. 性能优化(可选,推荐安装xanmod内核)"
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

                            # 应用 iptables 规则
                            iptables -t nat -A PREROUTING -i "$interface_name" \
                                -p udp --dport "${first_port}:${last_port}" \
                                -j REDIRECT --to-ports "$hy2_port"

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
                echo -e "${RED}正在使用nano编辑器进行手动修改，输入完成后按Ctrl+X保存退出${RESET}"
                nano "$HY2_CONFIG"
                systemctl enable --now hysteria-server.service
                systemctl restart hysteria-server.service
                echo "hy2服务已启动"
                ;;

            4)
                # 性能优化 (来自 Python 版)
                wget -O tcpx.sh 'https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh' && chmod +x tcpx.sh && ./tcpx.sh
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
agree_treaty

while true; do
    clear
    echo -e "${RED}HELLO HYSTERIA2 !${RESET}  (输入hy2快捷启动)"
    echo "1. 安装/更新hysteria2"
    echo "2. 卸载hysteria2"
    echo "3. hysteria2配置"
    echo "4. hysteria2服务管理"
    echo "0. 退出"
    read -p "请输入选项：" main_choice
    case "$main_choice" in
        1)
            clear
            hysteria2_install
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

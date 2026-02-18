#!/bin/bash

# ============================================================
# VPS 初始化脚本 - 支持多种 Linux 发行版
# ============================================================

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

read_with_default_value() {
    local tips=$1
    local def=$2
    local read_value
    read -p "请输入${tips}[默认:${def}]: " read_value
    if [ -z "${read_value}" ]; then
        read_value=$def
    fi
    echo "$read_value"
}

check_user_exists() {
    local username=$1
    if id "$username" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

ask_skip() {
    local step_name=$1
    local response
    read -p "${step_name} 已存在,是否跳过(Y/n): " response
    if [[ "$response" =~ ^[Yy]$ ]] || [ -z "$response" ]; then
        return 0
    else
        return 1
    fi
}

backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local backup_name="${file}.bak.$(date +%Y%m%d%H%M%S)"
        cp -pf "$file" "$backup_name"
        log_info "已备份文件: $file -> $backup_name"
    fi
}

change_ssh_port() {
    local portset=$1

    if ! [[ "$portset" =~ ^[0-9]+$ ]] || [ "$portset" -lt 1 ] || [ "$portset" -gt 65535 ]; then
        log_error "请输入1-65535之间的有效端口号"
        exit 1
    fi

    log_info "修改SSH端口为: $portset"

    backup_file /etc/ssh/sshd_config

    if [ "$is_centos" = true ]; then
        $app_cmd install -y policycoreutils-python-utils 2>/dev/null || $app_cmd install -y policycoreutils-python 2>/dev/null

        if command -v semanage &> /dev/null; then
            if ! semanage port -l | grep -q "^ssh_port_t.*${portset}"; then
                semanage port -a -t ssh_port_t -p tcp $portset 2>/dev/null || true
                log_info "已添加端口 $portset 到SELinux策略"
            fi
        fi
    fi

    /bin/sed -i "/^Port /d" /etc/ssh/sshd_config
    echo "Port $portset" >> /etc/ssh/sshd_config

    if systemctl restart sshd.service; then
        log_info "SSH服务重启成功"
    else
        log_error "SSH服务重启失败"
        exit 1
    fi
}

add_ssh_port() {
    local portset=$1

    if ! [[ "$portset" =~ ^[0-9]+$ ]] || [ "$portset" -lt 1 ] || [ "$portset" -gt 65535 ]; then
        log_error "请输入1-65535之间的有效端口号"
        exit 1
    fi

    log_info "添加SSH端口: $portset"

    backup_file /etc/ssh/sshd_config

    if [ "$is_centos" = true ]; then
        $app_cmd install -y policycoreutils-python-utils 2>/dev/null || $app_cmd install -y policycoreutils-python 2>/dev/null

        if command -v semanage &> /dev/null; then
            if ! semanage port -l | grep -q "^ssh_port_t.*${portset}"; then
                semanage port -a -t ssh_port_t -p tcp $portset 2>/dev/null || true
                log_info "已添加端口 $portset 到SELinux策略"
            fi
        fi
    fi

    if ! grep -q "^Port ${portset}" /etc/ssh/sshd_config; then
        echo "Port $portset" >> /etc/ssh/sshd_config
        log_info "已添加端口 $portset 到SSH配置"
    else
        log_warn "端口 $portset 已存在于SSH配置中"
    fi

    if systemctl restart sshd.service; then
        log_info "SSH服务重启成功"
    else
        log_error "SSH服务重启失败"
        exit 1
    fi
}

add_user() {
    local name=$1
    local passwd=$2
    local skip=false
    local user_exists=false

    log_info "检查用户: $name"

    if id "$name" &> /dev/null; then
        user_exists=true
        log_warn "用户 $name 已存在"
        if ask_skip "用户 $name"; then
            skip=true
            log_info "跳过用户创建步骤"
        else
            log_info "将更新用户配置"
        fi
    fi

    if [ "$skip" = false ]; then
        if [ "$user_exists" = false ] || [ -z "$passwd" ]; then
            read -s -p "请输入用户 $name 的密码: " input_passwd
            echo
            if [ -z "$input_passwd" ]; then
                log_error "密码不能为空"
                exit 1
            fi
            passwd=$input_passwd
        fi

        if [ "$user_exists" = false ]; then
            if useradd -m -s /bin/bash "$name"; then
                log_info "用户 $name 创建成功"
            else
                log_error "用户 $name 创建失败"
                exit 1
            fi
        fi

        if echo "$name:$passwd" | chpasswd; then
            log_info "用户 $name 密码修改成功"
        else
            log_error "用户 $name 密码修改失败"
            exit 1
        fi

        log_info "配置用户 $name 的sudo权限"
        sed -i "/^${name} ALL=(ALL) NOPASSWD:ALL/d" /etc/sudoers
        echo "$name ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
        log_info "用户 $name 已配置无密码sudo权限"
    fi
}

close_selinux() {
    if [ "$is_centos" = false ]; then
        log_info "Debian/Ubuntu系统不需要配置SELinux"
        return
    fi

    if [ ! -f /etc/selinux/config ]; then
        log_info "SELinux配置文件不存在"
        return
    fi

    if grep -q "^SELINUX=enforcing" /etc/selinux/config; then
        log_warn "检测到SELinux已启用,将关闭SELinux"
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        log_warn "SELinux已禁用,需要重启后生效"
    else
        log_info "SELinux已禁用或未安装"
    fi
}

# 安装和配置 fail2ban(防暴力破解)
init_fail2ban() {
    local skip=false

    # 检查是否已安装和运行
    if systemctl is-active --quiet fail2ban; then
        log_info "检测到fail2ban已在运行"
        if ask_skip "fail2ban配置"; then
            log_info "跳过fail2ban配置步骤"
            return
        fi
    fi

    log_info "安装fail2ban..."
    $app_cmd -y install fail2ban

    # 确定 logpath 根据系统类型
    local logpath="/var/log/auth.log"  # Debian/Ubuntu
    local banaction="iptables"
    local action_mwl="iptables[name=DEFAULT, port=ssh, protocol=tcp]"

    if [ "$is_centos" = true ]; then
        logpath="/var/log/secure"      # CentOS/RHEL
        banaction="firewallcmd-ipset"
        action_mwl="firewallcmd-ipset[name=DEFAULT, port=ssh, protocol=tcp]"
    fi

    # 动态添加端口配置(如果设置了自定义SSH端口)
    local ssh_ports="ssh"
    if [ -n "$current_ssh_port" ]; then
        ssh_ports="${ssh_ports},${current_ssh_port}"
    fi
    if [ -n "$additional_ssh_port" ]; then
        ssh_ports="${ssh_ports},${additional_ssh_port}"
    fi

    # 创建自定义配置文件 jail-default.conf
    # 注意: 使用独立的配置文件而不是修改 /etc/fail2ban/jail.local
    local custom_config="/etc/fail2ban/jail-default.conf"

    # 备份已存在的自定义配置文件
    backup_file "$custom_config"

    # 生成自定义配置文件内容
    log_info "创建fail2ban自定义配置: $custom_config"
    cat > "$custom_config" << EOF
# ============================================================
# Fail2ban 自定义配置文件 - SSH 防暴力破解
# 注意: 此文件由 init_vps.sh 自动生成
# ============================================================

[DEFAULT]
# 忽略的IP地址(可以是IP段)
ignoreip = 127.0.0.1/8

# 封禁时间(秒): 默认10小时
bantime = 36000

# 查找时间范围(秒): 10分钟内
findtime = 600

# 最大重试次数
maxretry = 5

# CentOS/RHEL 使用 firewalld, Debian/Ubuntu 使用 iptables
banaction = ${banaction}

# 封禁动作: 封禁并记录日志和发送邮件
action = %(action_mwl)s

# ============================================================
# SSH 服务配置
# ============================================================

[sshd]
# 启用此jail
enabled = true

# 过滤器名称
filter = sshd

# 封禁动作(指定端口号)
# 动态添加所有SSH端口
action = iptables[name=SSH, port=${ssh_ports}, protocol=tcp]

# SSH日志路径(根据系统类型自动设置)
logpath = ${logpath}

# ============================================================
# SSH DDoS 防护配置(可选)
# ============================================================

[sshd-ddos]
enabled = false
filter = sshd-ddos
logpath = ${logpath}
port = ${ssh_ports}
protocol = tcp
maxretry = 6
bantime = 72000
EOF

    log_info "fail2ban配置文件已创建,监听端口: $ssh_ports"

    # 先停止可能运行的 fail2ban
    systemctl stop fail2ban 2>/dev/null || true
    sleep 2

    # 清理可能的旧 socket 文件
    rm -f /var/run/fail2ban/fail2ban.sock 2>/dev/null || true

    # 检查配置文件语法
    log_info "检查fail2ban配置文件..."
    if fail2ban-client -t 2>/dev/null; then
        log_info "fail2ban 配置文件检查通过"
    else
        log_warn "fail2ban 配置文件检查失败,继续尝试启动"
    fi

    # 启动服务
    systemctl enable fail2ban
    systemctl start fail2ban

    # 等待服务完全启动
    sleep 5

    # 检查服务状态
    if systemctl is-active --quiet fail2ban; then
        log_info "fail2ban 服务运行正常"
    else
        log_error "fail2ban 服务启动失败"
        systemctl status fail2ban
        return
    fi

    # 检查 jail 状态
    log_info "fail2ban jail 状态:"
    fail2ban-client status 2>/dev/null || log_warn "无法获取 fail2ban 总体状态"

    if fail2ban-client status sshd &>/dev/null; then
        fail2ban-client status sshd
    else
        log_warn "sshd jail 未启用,尝试启动..."
        if fail2ban-client start sshd &>/dev/null; then
            log_info "sshd jail 启动成功"
            sleep 2
            fail2ban-client status sshd
        else
            log_error "sshd jail 启动失败,请检查配置"
        fi
    fi
}

init_firewall() {
    local skip=false
    local fw_name=""

    # 检查防火墙是否已安装和配置
    if [ "$is_debian" = true ]; then
        fw_name="ufw"
        if systemctl is-active --quiet ufw; then
            log_info "检测到ufw已在运行"
            if ask_skip "防火墙配置"; then
                skip=true
                log_info "跳过防火墙配置步骤"
            else
                log_info "将重新配置防火墙"
            fi
        fi
    else
        fw_name="firewalld"
        if systemctl is-active --quiet firewalld; then
            log_info "检测到firewalld已在运行"
            if ask_skip "防火墙配置"; then
                skip=true
                log_info "跳过防火墙配置步骤"
            else
                log_info "将重新配置防火墙"
            fi
        fi
    fi

    if [ "$skip" = true ]; then
        return
    fi

    log_info "配置防火墙 ($fw_name)..."

    # Debian/Ubuntu 使用 ufw
    if [ "$is_debian" = true ]; then
        # 安装 ufw
        $app_cmd install -y ufw

        # 配置 ufw 规则
        log_info "配置 ufw 防火墙规则..."
        ufw allow 22/tcp comment "SSH original port"
        ufw allow 10022/tcp comment "SSH backup port"
        if [ -n "$current_ssh_port" ]; then
            ufw allow $current_ssh_port/tcp comment "SSH custom port"
        fi
        if [ -n "$additional_ssh_port" ]; then
            ufw allow $additional_ssh_port/tcp comment "SSH additional port"
        fi
        ufw allow 80/tcp comment "HTTP"
        ufw allow 443/tcp comment "HTTPS"

        # 启用 ufw
        echo "y" | ufw enable
        ufw reload
        log_info "ufw 防火墙规则配置完成"

    # CentOS/RHEL 使用 firewalld
    else
        # 安装 epel-release (CentOS需要)
        $app_cmd -y install epel-release

        # 安装 firewalld
        $app_cmd install -y firewalld

        systemctl restart firewalld
        systemctl enable firewalld

        # 配置 firewalld 规则
        log_info "配置 firewalld 防火墙规则..."
        firewall-cmd --zone=public --add-port=22/tcp --permanent
        firewall-cmd --zone=public --add-port=10022/tcp --permanent
        if [ -n "$current_ssh_port" ]; then
            firewall-cmd --zone=public --add-port=$current_ssh_port/tcp --permanent
        fi
        if [ -n "$additional_ssh_port" ]; then
            firewall-cmd --zone=public --add-port=$additional_ssh_port/tcp --permanent
        fi
        firewall-cmd --zone=public --add-port=80/tcp --permanent
        firewall-cmd --zone=public --add-port=443/tcp --permanent
        firewall-cmd --zone=public --add-port=443/udp --permanent

        firewall-cmd --reload
        log_info "firewalld 防火墙规则配置完成"
    fi

    # 调用 fail2ban 配置函数
    init_fail2ban
}

# 全局变量
current_ssh_port=""  # 当前SSH主端口
additional_ssh_port=""  # 额外SSH端口

# 获取用户输入
user_name=$(read_with_default_value '新用户名' 'jamchen')

# 确认输入信息
read -s -n1 -p "用户名为: $user_name, 确认(Y/y): " confirm
echo ''

if [ "$confirm" != 'Y' ] && [ "$confirm" != 'y' ]; then
    log_error "已取消操作"
    exit 1
fi

if [ -z "$user_name" ]; then
    log_error "用户名不能为空"
    exit 1
fi

log_info "用户名: $user_name"

sys_name=$(cat /etc/os-release 2>/dev/null | grep "^ID=" | head -1 | sed 's/ID=//' | sed 's/"//g')
sys_version=$(cat /etc/os-release 2>/dev/null | grep "^VERSION_ID=" | head -1 | sed 's/VERSION_ID="//' | sed 's/"//g')
sys_like=$(cat /etc/os-release 2>/dev/null | grep "^ID_LIKE=" | head -1)

if [ -n "$sys_like" ]; then
    sys_like=$(echo "$sys_like" | sed 's/ID_LIKE=//' | sed 's/"//g')
fi

log_info "检测到系统信息:"
log_info "  ID: $sys_name"
log_info "  VERSION: $sys_version"
log_info "  ID_LIKE: $sys_like"

is_debian=false
is_centos=false

if [[ "$sys_name" == 'debian' ]] || [[ "$sys_name" == 'ubuntu' ]] || \
   [[ "$sys_like" == *debian* ]] || [[ "$sys_like" == *ubuntu* ]]; then
    is_debian=true
    app_cmd='apt-get'
    log_info "识别为 Debian/Ubuntu 系列系统"
elif [[ "$sys_name" == 'centos' ]] || [[ "$sys_name" == 'rhel' ]] || \
     [[ "$sys_name" == 'rocky' ]] || [[ "$sys_name" == 'rockylinux' ]] || \
     [[ "$sys_name" == 'almalinux' ]] || [[ "$sys_name" == 'fedora' ]] || \
     [[ "$sys_name" == 'ol' ]] || [[ "$sys_name" == 'oraclelinux' ]] || \
     [[ "$sys_name" == 'anolis' ]] || [[ "$sys_like" == *rhel* ]] || \
     [[ "$sys_like" == *centos* ]]; then
    is_centos=true
    app_cmd='yum'
    log_info "识别为 CentOS/RHEL 系列系统"
else
    log_error "不支持的系统类型: $sys_name"
    log_error "此脚本仅支持 Debian/Ubuntu 和 CentOS/RHEL 系列系统"
    exit 1
fi

log_info "当前系统为: $sys_name $sys_version, 包管理器: $app_cmd"

log_info "更新系统..."
if [ "$is_debian" = true ]; then
    $app_cmd update -y
    $app_cmd upgrade -y
else
    $app_cmd -y update
fi

log_info "安装基础工具..."
$app_cmd install -y wget vim git curl

echo ""
echo "========================================="
echo "请选择要执行的步骤(多选用逗号分隔):"
echo "========================================="
echo "1. 添加/更新用户"
echo "2. 修改SSH端口"
echo "3. 添加备用SSH端口"
echo "4. 禁用root登录"
echo "5. 配置防火墙和fail2ban"
echo "6. 安装v2ray"
echo "7. 全部执行"
echo "0. 退出"
echo "========================================="

# 清理输入缓冲区
while read -r -t 0.1 -n 10000 discard 2>/dev/null; do
    :
done

read -p "请输入选项[默认:7]: " options

# 如果用户直接回车,默认执行全部
if [ -z "$options" ]; then
    options="7"
fi

run_all_user=false
run_change_ssh_port=false
run_add_ssh_port=false
run_disable_root=false
run_firewall=false
run_v2ray=false

if [ "$options" = "7" ]; then
    run_all_user=true
    run_change_ssh_port=true
    run_add_ssh_port=true
    run_disable_root=true
    run_firewall=true
    run_v2ray=true
elif [ "$options" = "0" ]; then
    log_info "已退出"
    exit 0
else
    IFS=',' read -ra opt_array <<< "$options"
    for opt in "${opt_array[@]}"; do
        case $opt in
            1) run_all_user=true ;;
            2) run_change_ssh_port=true ;;
            3) run_add_ssh_port=true ;;
            4) run_disable_root=true ;;
            5) run_firewall=true ;;
            6) run_v2ray=true ;;
        esac
    done
fi

echo ""
log_info "开始执行选择的步骤..."
echo ""

if [ "$run_all_user" = true ]; then
    add_user "$user_name" ""
else
    log_info "跳过用户配置步骤"
fi

if [ "$run_change_ssh_port" = true ]; then
    read -p "请输入新的SSH端口: " current_ssh_port
    if [ -z "$current_ssh_port" ]; then
        log_warn "未输入端口,跳过修改SSH端口"
    else
        change_ssh_port "$current_ssh_port"
    fi
else
    log_info "跳过修改SSH端口步骤"
fi

if [ "$run_add_ssh_port" = true ]; then
    read -p "请输入要添加的SSH端口[默认:10022]: " additional_ssh_port
    if [ -z "$additional_ssh_port" ]; then
        additional_ssh_port="10022"
    fi
    add_ssh_port "$additional_ssh_port"
else
    log_info "跳过添加备用SSH端口步骤"
fi

if [ "$run_disable_root" = true ]; then
    log_info "禁用root用户SSH登录"
    backup_file /etc/ssh/sshd_config
    sed -i "/^PermitRootLogin/d" /etc/ssh/sshd_config
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config
    systemctl restart sshd.service && log_info "SSH服务重启成功" || { log_error "SSH服务重启失败"; exit 1; }
else
    log_info "跳过禁用root登录步骤"
fi

if [ "$run_firewall" = true ]; then
    init_firewall
else
    log_info "跳过防火墙配置步骤"
fi

if [ "$run_v2ray" = true ]; then
    log_info "开始安装v2ray..."
    log_warn "即将执行 v2ray 安装脚本,请按提示操作"
    log_warn "安装来源: https://github.com/mack-a/v2ray-agent"
    bash <(curl -fsSL "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh")
    log_info "v2ray安装脚本执行完成"
else
    log_info "跳过v2ray安装步骤"
fi

echo ""
log_info "========================================="
log_info "VPS初始化完成!"
log_info "========================================="
log_info "新用户: $user_name"
log_info "防火墙已配置常用端口"
log_info "fail2ban已启用(防暴力破解)"
log_info "root用户SSH登录已禁用"
log_info "========================================="
echo ""
log_warn "重要提示:"
log_warn "1. 请使用新用户 $user_name 登录"
log_warn "2. 请根据实际情况使用 -p 参数指定SSH端口"
log_warn "3. 如果修改了SELinux配置(CentOS),建议手动重启系统"
echo ""


if [ -n "$ssh_key_port" ] && [ -n "$domain" ]; then
	echo ""
	log_info "免密登录设置命令:"
	echo "  ssh-keygen"
	echo "  ssh-copy-id -i ~/.ssh/id_rsa.pub -p $ssh_key_port $user_name@$domain"
	echo ""
fi

echo ""

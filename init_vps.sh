#!/bin/bash

# ============================================================
# VPS 初始化脚本 - 支持多种 Linux 发行版
# ============================================================

# 确保 PATH 包含必要的目录（追加到现有 PATH 后）
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

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

restart_ssh_service() {
    # 尝试重启 SSH 服务，如果失败则尝试修复
    if ! systemctl restart sshd.service; then
        log_warn "SSH服务重启失败，尝试修复..."
        # 检查是否为 OpenSSL 版本不匹配问题
        if journalctl -xeu sshd.service --no-pager 2>&1 | grep -q "OpenSSL version mismatch"; then
            log_warn "检测到 OpenSSL 版本不匹配，执行 openssh-server 更新..."
            if $app_cmd update -y openssh-server; then
                log_info "openssh-server 更新完成，再次尝试重启 SSH 服务"
                systemctl restart sshd.service
                if systemctl is-active --quiet sshd; then
                    log_info "SSH服务重启成功"
                    return 0
                else
                    log_error "SSH服务重启失败"
                    return 1
                fi
            else
                log_error "openssh-server 更新失败"
                return 1
            fi
        else
            log_error "SSH服务重启失败"
            return 1
        fi
    else
        log_info "SSH服务重启成功"
        return 0
    fi
}

change_ssh_port() {
    local portset=$1

    if ! [[ "$portset" =~ ^[0-9]+$ ]] || [ "$portset" -lt 1024 ] || [ "$portset" -gt 65535 ]; then
        log_error "请输入1024-65535之间的有效端口号"
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

    restart_ssh_service || exit 1
}

add_ssh_port() {
    local portset=$1

    if ! [[ "$portset" =~ ^[0-9]+$ ]] || [ "$portset" -lt 1024 ] || [ "$portset" -gt 65535 ]; then
        log_error "请输入1024-65535之间的有效端口号"
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

    restart_ssh_service || exit 1
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
            while true; do
                read -s -p "请输入用户 $name 的密码: " input_passwd
                echo
                if [ -z "$input_passwd" ]; then
                    log_error "密码不能为空，请重新输入"
                    continue
                fi
                # 显示密码长度供用户确认
                local passwd_len=${#input_passwd}
                log_info "密码长度: $passwd_len 位"

                # 询问是否确认
                read -p "确认使用此密码? (Y/n): " confirm_passwd
                if [[ "$confirm_passwd" =~ ^[Nn]$ ]]; then
                    log_warn "已取消，请重新输入密码"
                    continue
                fi
                passwd=$input_passwd
                break
            done
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

# 禁用空密码登录
disable_empty_password_login() {
    log_info "禁用空密码登录..."

    backup_file /etc/ssh/sshd_config

    # 移除旧的配置项（如果有）
    sed -i "/^PermitEmptyPasswords /d" /etc/ssh/sshd_config

    # 添加禁用空密码登录配置
    echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config

    # 重启 SSH 服务
    restart_ssh_service || exit 1
    log_info "已禁用空密码登录"
}

# 限制登录尝试次数和登录超时
ssh_security_limit() {
    log_info "配置SSH登录限制..."

    backup_file /etc/ssh/sshd_config

    # 移除旧的配置项（如果有）
    sed -i "/^MaxAuthTries /d" /etc/ssh/sshd_config
    sed -i "/^ClientAliveInterval /d" /etc/ssh/sshd_config
    sed -i "/^ClientAliveCountMax /d" /etc/ssh/sshd_config

    # 配置登录尝试次数（最多5次）
    echo "MaxAuthTries 5" >> /etc/ssh/sshd_config

    # 配置登录超时（客户端活跃检测）
    # ClientAliveInterval: 300秒（5分钟）发送一次心跳
    # ClientAliveCountMax: 5次无响应则断开
    echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
    echo "ClientAliveCountMax 5" >> /etc/ssh/sshd_config

    # 重启 SSH 服务
    restart_ssh_service || exit 1
    log_info "已配置登录限制: 最多5次尝试, 空闲25分钟自动断开"
}

# 禁用密码登录（仅允许密钥认证）
disable_password_login() {
    log_info "禁用SSH密码登录..."
    log_warn "注意: 禁用密码登录后，只能使用SSH密钥登录！"

    # 警告用户
    read -p "确认要禁用密码登录吗？(y/N): " confirm
    if [[ "$confirm" != 'y' ]] && [[ "$confirm" != 'Y' ]]; then
        log_warn "已取消禁用密码登录"
        return
    fi

    backup_file /etc/ssh/sshd_config

    # 移除旧的配置项（如果有）
    sed -i "/^PasswordAuthentication /d" /etc/ssh/sshd_config

    # 添加禁用密码登录配置
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config

    # 重启 SSH 服务
    restart_ssh_service || exit 1
    log_info "已禁用密码登录，仅允许SSH密钥认证"
    log_warn "请确保已配置SSH密钥，否则将无法登录！"
}

# 禁用 root 登录
disable_root_login() {
    log_info "禁用root用户SSH登录..."

    backup_file /etc/ssh/sshd_config

    sed -i "/^PermitRootLogin/d" /etc/ssh/sshd_config
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config

    restart_ssh_service || exit 1
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
    local custom_config="/etc/fail2ban/jail.d/jail-default.conf"

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
action = ${banaction}[name=SSH, port="${ssh_ports}", protocol=tcp]

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

    # 重启服务
    systemctl enable fail2ban
    systemctl restart fail2ban

    # 等待服务完全启动
    sleep 2

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
        log_error "sshd jail 启动失败,请检查配置"
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

    # 如果 dpkg 被中断，先修复
    if [ "$is_debian" = true ]; then
        if dpkg --configure -a 2>&1 | grep -q "you must manually run"; then
            log_warn "检测到 dpkg 被中断，正在修复..."
            dpkg --configure -a
        fi
    fi

    log_info "配置防火墙 ($fw_name)..."

    # Debian/Ubuntu 使用 ufw
    if [ "$is_debian" = true ]; then
        # 安装 ufw
        if ! command -v ufw &> /dev/null; then
            $app_cmd install -y ufw
        fi

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
}

# 自动安全更新配置
auto_security_update() {
    local skip=false

    # Debian/Ubuntu 使用 unattended-upgrades
    if [ "$is_debian" = true ]; then
        # 检查是否已安装和配置
        if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
            log_info "检测到自动安全更新配置已存在"
            if ask_skip "自动安全更新配置"; then
                skip=true
                log_info "跳过自动安全更新配置步骤"
            else
                log_info "将重新配置自动安全更新"
            fi
        fi

        if [ "$skip" = true ]; then
            return
        fi

        log_info "配置自动安全更新..."

        # 安装 unattended-upgrades
        $app_cmd install -y unattended-upgrades apt-listchanges

        # 备份配置文件
        backup_file /etc/apt/apt.conf.d/50unattended-upgrades

        # 配置 unattended-upgrades
        cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
// ============================================================
// 自动安全更新配置 - Debian/Ubuntu
// 注意: 此文件由 init_vps.sh 自动生成
// ============================================================

// 自动更新范围
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
//  "${distro_id}:${distro_codename}-updates";
//  "${distro_id}ESMApps:${distro_codename}-apps-security";
//  "${distro_id}ESM:${distro_codename}-infra-security";
};

// 不自动更新的包（根据需要添加）
Unattended-Upgrade::Package-Blacklist {
};

// 自动删除不需要的依赖包
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// 自动重启（不建议启用）
Unattended-Upgrade::Automatic-Reboot "false";

// 发送邮件通知（如果配置了邮件服务器）
// Unattended-Upgrade::Mail "root";
// Unattended-Upgrade::MailOnlyOnError "true";

// 日志级别
Unattended-Upgrade::Verbose "false";
EOF

        # 启用自动更新
        # 方法1: 尝试使用 debconf-set-selections（更可靠）
        if command -v debconf-set-selections &> /dev/null; then
            echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
        # 方法2: 直接创建配置文件
        else
            cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
        fi

        log_info "Debian/Ubuntu 自动安全更新配置完成"
        log_info "系统将每日自动安装安全更新，不会自动重启"

    # CentOS/RHEL 使用 yum-cron 或 dnf-automatic
    else
        # 检查是否已安装和配置
        if [ -f /etc/yum/yum-cron.conf ] || [ -f /etc/dnf/automatic.conf ]; then
            log_info "检测到自动安全更新配置已存在"
            if ask_skip "自动安全更新配置"; then
                skip=true
                log_info "跳过自动安全更新配置步骤"
            else
                log_info "将重新配置自动安全更新"
            fi
        fi

        if [ "$skip" = true ]; then
            return
        fi

        log_info "配置自动安全更新..."

        # 优先尝试安装 dnf-automatic（适用于 RHEL 8+ / CentOS 8+ / Fedora）
        if command -v dnf &> /dev/null || command -v yum &> /dev/null; then
            # 尝试安装 dnf-automatic（适用于 dnf 系统）
            if $app_cmd install -y dnf-automatic 2>/dev/null || $app_cmd install -y dnf-automatic.timer 2>/dev/null; then
                # 备份配置文件
                backup_file /etc/dnf/automatic.conf

                # 配置 dnf-automatic
                cat > /etc/dnf/automatic.conf << 'EOF'
# ============================================================
# 自动安全更新配置 - RHEL 8+ / CentOS 8+ (dnf-automatic)
# 注意: 此文件由 init_vps.sh 自动生成
# ============================================================

[commands]
# 更新类型: default, security, security-severity:Critical, minimal
upgrade_type = security

# 是否随机下载和安装
random_sleep = 360

[emitters]
# 发送通知方式 (none, stdio, motd, email)
emit_via = stdio

# 系统名称
system_name = None

[base]
# 调试模式
debuglevel = 0

# 是否跳过不可解析的包
skip_broken = no

# 发送邮件（需要配置邮件服务器）
# email_from = root
# email_to = root
# email_host = localhost

# 是否下载更新
download_updates = yes

# 是否应用更新
apply_updates = yes

# 重启类型: off, reboot, none
reboot = off

# 是否只在需要重启时重启
reboot_command = "shutdown -r +5 'Rebooting for kernel updates'"

[groups]

# 不自动更新的组
# group_list = None
# group_exclude = None
# group_update = None
EOF

                # 启用并启动 dnf-automatic.timer
                systemctl enable --now dnf-automatic.timer 2>/dev/null || systemctl enable --now dnf-automatic 2>/dev/null

                log_info "dnf-automatic 自动安全更新配置完成"
                log_info "系统将通过 systemd timer 定期自动安装安全更新"

            # 如果 dnf-automatic 不可用，尝试安装 yum-cron（适用于 CentOS 7）
            elif $app_cmd install -y yum-cron 2>/dev/null; then
                # 备份配置文件
                backup_file /etc/yum/yum-cron.conf

                # 配置 yum-cron
                cat > /etc/yum/yum-cron.conf << 'EOF'
# ============================================================
# 自动安全更新配置 - CentOS 7 (yum-cron)
# 注意: 此文件由 init_vps.sh 自动生成
# ============================================================

[commands]
# 更新命令
update_cmd = security-security

# 是否下载但不安装
# download_updates = yes

# 是否应用更新
apply_updates = yes

[emitters]
# 发送邮件（需要配置邮件服务器）
# system_name = None
# emit_via = email
# email_from = root
# email_to = root
# email_host = localhost

[base]
# 检查更新频率 (hourly|daily)
debug_level = 0
mday = *
month = *
random_sleep = 360
skip_broken = false

# 每日检查
day_of_month = *
day_of_week = *
hour = 6
minute = 0

# 是否通过消息通知
emit_via = stdio

# 通过邮件发送消息
# email_from = root
# email_to = root
# email_host = localhost

# 指定数据库
db_name = /var/lib/yum/yumdb

# 系统名称
system_name = None

[groups]

# 不自动更新的组
# group_list = None
# group_exclude = None
# group_update = None
EOF

                # 启用并启动 yum-cron
                systemctl enable yum-cron 2>/dev/null
                systemctl start yum-cron 2>/dev/null

                log_info "yum-cron 自动安全更新配置完成"
                log_info "系统将每日 6:00 自动检查并安装安全更新"

            else
                log_warn "无法安装自动安全更新工具（dnf-automatic 或 yum-cron）"
                log_warn "请手动配置自动安全更新或使用以下命令安装："
                log_warn "  dnf install -y dnf-automatic"
                log_warn "  systemctl enable --now dnf-automatic.timer"
            fi
        fi
    fi

    log_info "自动安全更新配置步骤完成"
}

# 系统安全加固（内核参数配置）
sys_security_harden() {
    local skip=false

    # 检查是否已配置
    if [ -f /etc/sysctl.d/99-security.conf ]; then
        log_info "检测到系统安全加固配置已存在"
        if ask_skip "系统安全加固配置"; then
            skip=true
            log_info "跳过系统安全加固配置步骤"
        else
            log_info "将重新配置系统安全加固"
        fi
    fi

    if [ "$skip" = true ]; then
        return
    fi

    log_info "配置系统安全加固（内核参数）..."

    # 备份原有配置（如果存在）
    backup_file /etc/sysctl.conf

    # 创建系统安全加固配置文件
    local sysctl_conf="/etc/sysctl.d/99-security.conf"

    log_info "创建内核安全参数配置: $sysctl_conf"
    cat > "$sysctl_conf" << 'EOF'
# ============================================================
# 系统安全加固配置 - 内核参数优化
# 注意: 此文件由 init_vps.sh 自动生成
# ============================================================

# ---------------------------
# 网络安全参数
# ---------------------------

# 禁用IP转发（除非需要作为路由器）
net.ipv4.ip_forward = 0

# 禁用发送重定向
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 禁用接收ICMP重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# 禁用源路由包
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# 启用反向路径过滤（防止IP欺骗）
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# 记录带有伪造源地址的数据包
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ---------------------------
# TCP/IP 栈安全参数
# ---------------------------

# 启用SYN cookies保护（防止SYN洪水攻击）
net.ipv4.tcp_syncookies = 1

# 减少TCP keepalive超时时间（默认7200秒，改为600秒）
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# 调整TCP超时重连次数
net.ipv4.tcp_retries2 = 5

# 禁用TCP时间戳（防止信息泄露）
net.ipv4.tcp_timestamps = 0

# 启用TCP窗口缩放（提高性能）
net.ipv4.tcp_window_scaling = 1

# 增加TCP最大队列长度
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

# ---------------------------
# ICMP协议安全
# ---------------------------

# 忽略ping请求（可选，根据需求开启）
# net.ipv4.icmp_echo_ignore_all = 1

# 忽略广播ping
net.ipv4.icmp_echo_ignore_broadcasts = 1

# 禁用ICMP重定向发送
net.ipv4.conf.all.send_redirects = 0

# ---------------------------
# 内存和文件系统安全
# ---------------------------

# 禁用核心转储（防止敏感信息泄露）
kernel.core_pattern = |/bin/false
fs.suid_dumpable = 0

# 增加文件描述符限制
fs.file-max = 65535

# ---------------------------
# 进程安全
# ---------------------------

# 限制ptrace范围（防止进程追踪攻击）
kernel.yama.ptrace_scope = 1

# 随机化虚拟内存布局（ASLR）
kernel.randomize_va_space = 2

# ---------------------------
# 其他安全参数
# ---------------------------

# 禁用magic sysrq键（防止通过键盘执行危险操作）
kernel.sysrq = 0

# 增加本地端口范围
net.ipv4.ip_local_port_range = 10000 65000

# 启用保护模式（防止缓冲区溢出攻击）
kernel.exec-shield = 1 2>/dev/null || true  # 仅适用于某些内核

# 启用随机化栈（防止栈溢出攻击）
kernel.randomize_stack = 1 2>/dev/null || true  # 仅适用于某些内核
EOF

    # 应用内核参数配置
    log_info "应用内核参数配置..."
    sysctl -p "$sysctl_conf" 2>/dev/null || sysctl --system 2>/dev/null

    # 显示当前部分关键参数状态
    log_info "当前内核安全参数状态:"
    sysctl net.ipv4.tcp_syncookies 2>/dev/null || true
    sysctl net.ipv4.ip_forward 2>/dev/null || true
    sysctl net.ipv4.conf.all.rp_filter 2>/dev/null || true
    sysctl kernel.yama.ptrace_scope 2>/dev/null || true
    sysctl kernel.randomize_va_space 2>/dev/null || true

    log_info "系统安全加固配置完成"
}

# 安装 v2ray
init_v2ray() {
    local skip=false

    # 检查是否已安装
    if systemctl is-active --quiet v2ray 2>/dev/null || command -v v2ray &> /dev/null; then
        log_info "检测到v2ray已安装"
        if ask_skip "v2ray安装"; then
            log_info "跳过v2ray安装步骤"
            return
        else
            log_info "将重新安装v2ray"
        fi
    fi

    log_info "开始安装v2ray..."
    log_warn "即将执行 v2ray 安装脚本,请按提示操作"
    log_warn "安装来源: https://github.com/mack-a/v2ray-agent"
    sleep 2

    # 执行 v2ray 安装脚本
    if bash <(curl -fsSL "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh"); then
        log_info "v2ray安装脚本执行完成"
    else
        log_error "v2ray安装脚本执行失败"
        return 1
    fi
}

# 全局变量
current_ssh_port="10022"  # 当前SSH主端口,默认10022
additional_ssh_port=""  # 额外SSH端口,默认为空

# 获取用户输入
user_name=$(read_with_default_value '新用户名' 'jamchen')

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
echo "4. SSH安全加固(禁用root+空密码)"
echo "5. 配置防火墙"
echo "6. 配置fail2ban"
echo "7. 系统安全加固(内核参数)"
echo "8. 安装v2ray"
echo "9. 禁用密码登录(仅允许密钥认证)"
echo "a. 全部执行(不含选项9)"
echo "0. 退出"
echo "========================================="

# 清理输入缓冲区
while read -r -t 0.1 -n 10000 discard 2>/dev/null; do
    :
done

read -p "请输入选项[默认:a]: " options

# 如果用户直接回车,默认执行全部
if [ -z "$options" ]; then
    options="a"
fi

run_all_user=false
run_change_ssh_port=false
run_add_ssh_port=false
run_disable_root=false
run_firewall=false
run_fail2ban=false
run_security_harden=false
run_disable_password=false
run_v2ray=false

if [ "$options" = "a" ] || [ "$options" = "A" ]; then
    run_all_user=true
    run_change_ssh_port=true
    run_add_ssh_port=true
    run_disable_root=true
    run_firewall=true
    run_fail2ban=true
    run_security_harden=true
    run_v2ray=true
    # 不包含禁用密码登录
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
            6) run_fail2ban=true ;;
            7) run_security_harden=true ;;
            8) run_v2ray=true ;;
            9) run_disable_password=true ;;
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
    read -p "请输入新的SSH端口[默认:10022]: " current_ssh_port
    if [ -z "$current_ssh_port" ]; then
        current_ssh_port="10022"
        log_info "使用默认端口: $current_ssh_port"
    fi
    change_ssh_port "$current_ssh_port"
else
    log_info "跳过修改SSH端口步骤"
fi

if [ "$run_add_ssh_port" = true ]; then
    read -p "请输入要添加的SSH端口[留空跳过]: " additional_ssh_port
    if [ -z "$additional_ssh_port" ]; then
        log_warn "未输入端口,跳过添加备用SSH端口"
    else
        add_ssh_port "$additional_ssh_port"
    fi
else
    log_info "跳过添加备用SSH端口步骤"
fi

if [ "$run_disable_root" = true ]; then
    disable_root_login
    disable_empty_password_login
    ssh_security_limit
else
    log_info "跳过SSH安全加固步骤"
fi

if [ "$run_firewall" = true ]; then
    init_firewall
else
    log_info "跳过防火墙配置步骤"
fi

if [ "$run_fail2ban" = true ]; then
    init_fail2ban
else
    log_info "跳过fail2ban配置步骤"
fi

if [ "$run_security_harden" = true ]; then
    sys_security_harden
    auto_security_update
else
    log_info "跳过系统安全加固配置步骤"
fi

if [ "$run_v2ray" = true ]; then
    init_v2ray
else
    log_info "跳过v2ray安装步骤"
fi

if [ "$run_disable_password" = true ]; then
    disable_password_login
else
    log_info "跳过禁用密码登录步骤"
fi

echo ""
log_info "========================================="
log_info "VPS初始化完成!"
log_info "========================================="
log_info "新用户: $user_name"
log_info "防火墙已配置常用端口"
log_info "fail2ban已启用(防暴力破解)"
log_info "root用户SSH登录已禁用"
log_info "空密码登录已禁用"
log_info "SSH登录限制已配置(最多5次,空闲超时25分钟)"
log_info "系统安全加固已完成(内核参数优化)"
log_info "自动安全更新已启用"
log_info "========================================="
echo ""
log_warn "重要提示:"
log_warn "1. 请使用新用户 $user_name 登录"
log_warn "2. 请根据实际情况使用 -p 参数指定SSH端口"
log_warn "3. 如果修改了SELinux配置(CentOS),建议手动重启系统"
log_warn "4. 内核参数已应用,无需重启即可生效"
log_warn "5. 自动安全更新已启用,系统将自动安装安全补丁"
log_warn "6. 空密码登录已被禁用,请确保用户设置了密码"
log_warn "7. SSH登录限制: 最多5次尝试, 空闲25分钟后自动断开"
echo ""


if [ -n "$current_ssh_port" ] && [ -n "$domain" ]; then
	echo ""
	log_info "免密登录设置命令:"
	echo "  ssh-keygen"
	echo "  ssh-copy-id -i ~/.ssh/id_rsa.pub -p $current_ssh_port $user_name@$domain"
	echo ""
fi

echo ""

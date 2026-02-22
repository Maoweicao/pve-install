#!/bin/bash

set -o errexit
set -o pipefail

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m'

SYSTEM_ARCH=""
DEBIAN_CODENAME=""
PVE_VERSION=""
HOSTNAME_FQDN=""
SERVER_IP=""
MIRROR_BASE=""
PVE_REPO_COMPONENT=""
PVE_GPG_KEY_URL=""
STATE_DIR="/var/lib/pve-install"

function ensure_state_dir() {
    if [[ ! -d "$STATE_DIR" ]]; then
        mkdir -p "$STATE_DIR" || true
    fi
}

log_info() { printf "${COLOR_GREEN}[INFO]${COLOR_NC} %s\n" "$1"; }
log_warn() { printf "${COLOR_YELLOW}[WARN]${COLOR_NC} %s\n" "$1"; }
log_error() { printf "${COLOR_RED}[ERROR]${COLOR_NC} %s\n" "$1"; }
log_step() { printf "\n${COLOR_BLUE}>>> [步骤] %s${COLOR_NC}\n" "$1"; }

function cleanup_on_exit() {
    log_warn "脚本被中断或发生错误，正在退出..."
    exit 1
}

function ensure_packages_installed() {
    log_step "检查并安装缺失的基础软件包"
    local pkgs=("curl" "wget" "gnupg2" "lsb-release" "ca-certificates" "apt-transport-https")
    local missing=()

    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "检测到缺失的软件包: ${missing[*]}"
        log_info "将尝试自动安装缺失的软件包 (apt-get update && apt-get install -y ...)。"
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get update; then
            log_error "apt-get update 失败，无法安装缺失的软件包。"
            exit 1
        fi
        if ! apt-get install -y "${missing[@]}"; then
            log_error "自动安装缺失软件包失败: ${missing[*]}"
            exit 1
        fi
        log_info "缺失的软件包已安装。"
    else
        log_info "所有基础软件包均已安装。"
    fi
}

function check_prerequisites() {
    log_step "检查系统环境和依赖"

    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 权限运行。请尝试使用 'sudo'。"
        exit 1
    fi

    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64)
            SYSTEM_ARCH="arm64"
            ;;
        x86_64|amd64)
            SYSTEM_ARCH="amd64"
            ;;
        *)
            log_error "不支持的系统架构: $arch"
            log_info "此脚本仅支持 amd64 (x86_64) 和 arm64 (aarch64)。"
            exit 1
            ;;
    esac
    log_info "检测到系统架构: ${SYSTEM_ARCH}"

    # 自动检查并安装 pve 官方脚本常用的基础依赖包
    ensure_packages_installed
}

function check_debian_version() {
    log_step "验证 Debian 版本"
    
    if [[ ! -f /etc/debian_version ]]; then
        log_error "未检测到 Debian 系统，此脚本无法继续。"
        exit 1
    fi
    
    DEBIAN_CODENAME=$(lsb_release -cs)

    case "$DEBIAN_CODENAME" in
        bullseye)
            PVE_VERSION="7"
            log_info "检测到 Debian 11 (Bullseye)，将准备安装 PVE $PVE_VERSION"
            ;;
        bookworm)
            PVE_VERSION="8"
            log_info "检测到 Debian 12 (Bookworm)，将准备安装 PVE $PVE_VERSION"
            ;;
        trixie)
            PVE_VERSION="9"
            log_info "检测到 Debian 13 (Trixie)，将准备安装 PVE $PVE_VERSION"
            ;;
        *)
            log_error "不支持的 Debian 版本: $DEBIAN_CODENAME (仅支持 bullseye、bookworm 和 trixie)"
            exit 1
            ;;
    esac
}

function configure_architecture_specifics() {
    log_step "根据架构 (${SYSTEM_ARCH}) 配置软件源"

    if [[ "$SYSTEM_ARCH" == "amd64" ]]; then
        log_info "为 AMD64 架构使用 Proxmox 官方公共下载源 (无订阅)。"
        MIRROR_BASE="https://download.proxmox.com/debian/pve"
        PVE_REPO_COMPONENT="pve-no-subscription"
        PVE_GPG_KEY_URL="https://download.proxmox.com/debian/proxmox-release-${DEBIAN_CODENAME}.gpg"
    else
        # 修正之处：为 ARM64 单独处理 URL，确保路径正确
        log_info "为 ARM64 架构选择第三方镜像源。"
        local choice
        local mirror_domain
        while true; do
            printf "请选择一个地理位置较近的镜像源以获得更快的速度：\n"
            printf "  1) 主源 (韩国)\n"
            printf "  2) 中国 (Lierfang)\n"
            printf "  3) 中国香港\n"
            printf "  4) 德国\n"
            read -p "请输入选项数字 (1-4): " choice
            
            case $choice in
                1) mirror_domain="https://mirrors.apqa.cn"; break ;;
                2) mirror_domain="https://mirrors.lierfang.com"; break ;;
                3) mirror_domain="https://hk.mirrors.apqa.cn"; break ;;
                4) mirror_domain="https://de.mirrors.apqa.cn"; break ;;
                *) log_warn "无效的选项，请输入 1 到 4 之间的数字。" ;;
            esac
        done
        # 分别、显式地构建软件源和GPG密钥的URL
        MIRROR_BASE="${mirror_domain}/proxmox/debian/pve"
        PVE_REPO_COMPONENT="port"
        PVE_GPG_KEY_URL="${mirror_domain}/proxmox/debian/pveport.gpg"
    fi
    log_info "软件源地址已设置为: ${MIRROR_BASE}"
    log_info "GPG密钥地址已设置为: ${PVE_GPG_KEY_URL}"
}

function download_keyring_to() {
    local dest="$1"; shift
    local urls=("$@")
    local tmp="${dest}.tmp"
    local ok=1

    for u in "${urls[@]}"; do
        if curl -fsSL "$u" -o "$tmp"; then
            ok=0; break
        fi
        if command -v wget &>/dev/null; then
            if wget --no-check-certificate -qO "$tmp" "$u"; then
                ok=0; break
            fi
        fi
    done

    if [[ $ok -ne 0 ]]; then
        return 1
    fi
    mv "$tmp" "$dest"
    chmod 644 "$dest"
    return 0
}

function write_deb822_source() {
    local dest="/etc/apt/sources.list.d/pve-install-repo.sources"
    ensure_state_dir
    log_step "写入 deb822 格式的 Proxmox APT 源到 ${dest}"
    cat > "$dest" <<EOF
Types: deb
URIs: ${MIRROR_BASE}
Suites: ${DEBIAN_CODENAME}
Components: ${PVE_REPO_COMPONENT}
Signed-By: /usr/share/keyrings/proxmox-archive-keyring-${DEBIAN_CODENAME}.gpg
EOF
    log_info "已写入: $dest"
}

function configure_hostname() {
    log_step "配置主机名和 /etc/hosts 文件"
    
    local hostname domain
    while true; do
        read -p "请输入主机名 (例如: pve): " hostname
        if [[ -n "$hostname" ]]; then
            break
        else
            log_warn "主机名不能为空，请重新输入。"
        fi
    done

    while true; do
        read -p "请输入域名 (例如: local, home): " domain
        if [[ -n "$domain" ]]; then
            break
        else
            log_warn "域名不能为空，请重新输入。"
        fi
    done
    
    HOSTNAME_FQDN="${hostname}.${domain}"

    while true; do
        read -p "请输入服务器的静态 IP 地址 (例如: 192.168.1.10): " SERVER_IP
        if [[ -z "$SERVER_IP" ]]; then
            log_warn "IP 地址不能为空，请重新输入。"
            continue
        fi
        if [[ $SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        else
            log_warn "无效的 IP 地址格式，请重新输入。"
        fi
    done

    log_info "配置预览："
    echo "  - 完整主机名 (FQDN): ${HOSTNAME_FQDN}"
    echo "  - IP 地址: ${SERVER_IP}"
    
    local confirm_hosts
    read -p "即将修改主机名并覆盖 /etc/hosts 文件，是否继续? (y/N): " confirm_hosts
    if [[ "${confirm_hosts,,}" != "y" ]]; then
        log_warn "操作已取消。"
        return 1
    fi

    hostnamectl set-hostname "$HOSTNAME_FQDN" --static
    log_info "主机名已设置为: $HOSTNAME_FQDN"

    local hosts_content
    hosts_content=$(cat <<EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
${SERVER_IP}    ${HOSTNAME_FQDN} ${hostname}
EOF
)
    echo "$hosts_content" > /etc/hosts.tmp && mv /etc/hosts.tmp /etc/hosts
    log_info "/etc/hosts 文件已成功更新。"
}

function backup_apt_config() {
    log_step "备份当前 APT 源配置"
    
    local backup_dir="/root/pve_install_backup_$(date +%Y%m%d_%H%M%S)"
    if mkdir -p "$backup_dir"; then
        log_info "备份目录已创建: $backup_dir"
    else
        log_error "无法创建备份目录，请检查权限。"
        return 1
    fi
    
    find /etc/apt/ -name "*.list" -exec cp {} "$backup_dir/" \;
    log_info "所有 .list 文件已备份。"
}

function run_installation() {
    log_step "开始安装 Proxmox VE (遵循官方推荐步骤)"
    ensure_state_dir

    # 下载并安装 keyring 到 /usr/share/keyrings
    local key_dest="/usr/share/keyrings/proxmox-archive-keyring-${DEBIAN_CODENAME}.gpg"
    log_info "正在下载 Proxmox APT 存档密钥到 ${key_dest}..."

    # 优先尝试 enterprise，然后 download，再尝试之前的 PVE_GPG_KEY_URL
    local urls=(
        "https://enterprise.proxmox.com/debian/proxmox-archive-keyring-${DEBIAN_CODENAME}.gpg"
        "https://download.proxmox.com/debian/proxmox-archive-keyring-${DEBIAN_CODENAME}.gpg"
        "${PVE_GPG_KEY_URL}"
    )

    if ! download_keyring_to "$key_dest" "${urls[@]}"; then
        log_error "无法下载 Proxmox keyring。请检查网络或手动将 key 文件放置到 ${key_dest}。"
        exit 1
    fi
    log_info "密钥已安装到: ${key_dest}"

    # 使用 deb822 写入新的 .sources 文件（Signed-By 指向上面 keyring）
    write_deb822_source

    # 可选：将现有 sources 迁移为 modernize 格式（如果支持）
    if command -v apt &>/dev/null; then
        if apt --help 2>&1 | grep -q "modernize-sources"; then
            log_info "检测到 apt modernize-sources，正在尝试迁移现有 sources（如果需要）。"
            apt modernize-sources || log_warn "apt modernize-sources 运行失败或无需迁移。"
        fi
    fi

    log_info "更新并升级系统包 (apt update && apt full-upgrade)..."
    if ! apt update || ! apt -y full-upgrade; then
        log_error "apt 更新或升级失败。请检查网络和 APT 配置。"
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive

    local kernel_flag_file="${STATE_DIR}/kernel_installed"
    local packages_flag_file="${STATE_DIR}/packages_installed"

    if [[ ! -f "$kernel_flag_file" ]]; then
        log_info "安装 Proxmox VE 推荐内核 (proxmox-default-kernel)。"
        if ! apt install -y proxmox-default-kernel; then
            log_error "安装 proxmox-default-kernel 失败。"
            exit 1
        fi
        touch "$kernel_flag_file"
        log_info "Proxmox 内核已安装。为使新内核生效，建议现在重启系统。"
        read -p "是否立即重启系统以加载 Proxmox 内核？(y/N): " reboot_now
        if [[ "${reboot_now,,}" == "y" ]]; then
            log_info "系统将在 5 秒后重启..."
            sleep 5
            reboot
        else
            log_warn "请手动重启系统后重新运行脚本以继续安装剩余的 Proxmox 包。"
            exit 0
        fi
    fi

    # 继续安装 Proxmox VE 软件包（在内核生效后运行）
    if [[ -f "$kernel_flag_file" && ! -f "$packages_flag_file" ]]; then
        log_info "安装 Proxmox VE 包: proxmox-ve, postfix, open-iscsi, chrony"
        if ! apt install -y proxmox-ve postfix open-iscsi chrony; then
            log_error "安装 Proxmox VE 包失败。"
            exit 1
        fi

        # 移除 Debian 默认 kernel（按官方建议）
        log_info "尝试移除 Debian 默认内核包以避免未来升级问题。"
        apt remove -y linux-image-amd64 'linux-image-6.12*' || log_warn "移除特定 kernel 包时出现问题，跳过。"

        # 更新 grub（如果存在）
        if command -v update-grub &>/dev/null; then
            log_info "更新 grub 引导配置。"
            update-grub || log_warn "update-grub 失败。"
        fi

        # 可选：移除 os-prober
        read -p "是否移除 os-prober 包（推荐，防止 VM 分区被列入 grub）？(y/N): " remove_os
        if [[ "${remove_os,,}" == "y" ]]; then
            apt remove -y os-prober || log_warn "移除 os-prober 失败或未安装。"
        fi

        touch "$packages_flag_file"
        log_info "Proxmox VE 包安装完成。"
    fi

    log_info "安装阶段完成。"
}

function show_completion_info() {
    local ip
    ip=$(hostname -I | awk '{print $1}')

    printf "\n============================================================\n"
    log_info "    Proxmox VE $PVE_VERSION 安装成功!    "
    printf "============================================================\n\n"
    
    log_info "请通过以下地址访问 Proxmox VE Web 管理界面:"
    printf "  ${COLOR_YELLOW}URL:      https://%s:8006/${COLOR_NC}\n" "${ip}"
    printf "  ${COLOR_YELLOW}用户名:   root${COLOR_NC}\n"
    printf "  ${COLOR_YELLOW}密码:     (您的系统 root 密码)${COLOR_NC}\n\n"
    
    log_warn "为了加载新的 Proxmox 内核，系统需要重启。"
    local reboot_confirm
    read -p "是否立即重启系统? (y/N): " reboot_confirm
    if [[ "${reboot_confirm,,}" == "y" ]]; then
        log_info "系统将在 5 秒后重启..."
        sleep 5
        reboot
    else
        log_warn "重启已取消。请在方便时手动运行 'reboot' 命令。"
    fi
}

function main() {
    trap cleanup_on_exit INT TERM
    
    echo "欢迎使用 Proxmox VE 通用安装脚本 (AMD64/ARM64)"

    check_prerequisites
    check_debian_version
    configure_architecture_specifics

    if ! configure_hostname; then
        log_error "主机名配置未完成，脚本终止。"
        exit 1
    fi
    
    printf "\n====================== 最终安装确认 ======================\n"
    log_info "系统环境检查完成，配置如下："
    printf "  - 系统架构:        %s\n" "$SYSTEM_ARCH"
    printf "  - Debian 版本:     %s (PVE %s)\n" "$DEBIAN_CODENAME" "$PVE_VERSION"
    printf "  - 主机名 (FQDN):   %s\n" "$HOSTNAME_FQDN"
    printf "  - 服务器 IP:       %s\n" "$SERVER_IP"
    printf "  - 使用软件源:      %s\n" "$MIRROR_BASE"
    printf "============================================================\n"

    local final_confirm
    read -p "即将开始不可逆的安装过程，是否继续? (y/N): " final_confirm
    if [[ "${final_confirm,,}" != "y" ]]; then
        log_error "用户取消了安装。脚本退出。"
        exit 1
    fi

    backup_apt_config
    run_installation

    show_completion_info
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

#!/bin/bash

# ====================================================================
#  脚本名称: Sing-Box & Local Web Panel (MetaCubeXD) 终极一键管理脚本
#  系统支持: Debian, Ubuntu, CentOS, Rocky Linux, Alpine (OpenRC/Systemd 兼容)
#  适用架构: AMD64, ARM64
#  主要特点: 
#    1. 跨平台多协议支持，安装完成后，终端输入 sb 即可快捷管理
#    2. 自动部署官方最新 Sing-Box 核心 + 静态 Web 托管面板 (MetaCubeXD)
#    3. 预设安全 Shadowsocks 2022 (Blake3) 与 Mixed 通用入站端口
#    4. 彻底解决 OpenVZ、LXC 等轻量虚拟化平台下守护进程权限崩溃问题
# ====================================================================

export LANG=en_US.UTF-8

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
PLAIN='\033[0m'

# 通知与引导函数
info() { echo -e "${BLUE}[信息]${PLAIN} $*"; }
success() { echo -e "${GREEN}[成功]${PLAIN} $*"; }
warn() { echo -e "${YELLOW}[警告]${PLAIN} $*"; }
error() { echo -e "${RED}[错误]${PLAIN} $*"; }
readp() { read -p "$(echo -e "${YELLOW}$1${PLAIN}")" $2; }

# 权限验证
[[ $EUID -ne 0 ]] && error "请使用 root 权限或 sudo 运行此脚本！" && exit 1

# 基础路径配置
SB_DIR="/etc/sing-box"
SB_BIN="/usr/bin/sing-box"
SB_UI_DIR="${SB_DIR}/ui"
SB_CONFIG="${SB_DIR}/config.json"
SS_URI_PATH="${SB_DIR}/ss_uri.txt"
SB_SHORTCUT="/usr/local/bin/sb"

# 如果用户已经安装，运行此脚本直接跳转快捷面板
if [ -f "$SB_CONFIG" ] && [ -f "$SB_SHORTCUT" ]; then
    success "检测到您已成功安装 Sing-Box 服务，正在为您调出控制面板..."
    sleep 1
    exec "$SB_SHORTCUT"
fi

# 检测系统平台
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi

    # 检测架构
    case $(uname -m) in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) error "暂不支持当前的 $(uname -m) 架构" && exit 1 ;;
    esac
}

# 安装依赖项
install_deps() {
    info "检测并安装基础系统依赖..."
    case "$OS" in
        alpine)
            apk update >/dev/null 2>&1
            apk add --no-cache bash curl wget unzip tar ca-certificates openssl openrc jq libc6-compat gcompat >/dev/null 2>&1
            # 确保 OpenRC 服务管理器启动
            if ! rc-service --list 2>/dev/null | grep -q "^openrc"; then
                rc-update add openrc boot >/dev/null 2>&1 || true
                rc-service openrc start >/dev/null 2>&1 || true
            fi
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >/dev/null 2>&1
            apt-get install -y jq curl wget unzip tar ca-certificates openssl >/dev/null 2>&1
            ;;
        redhat)
            if [ -x "$(command -v dnf)" ]; then
                dnf install -y jq curl wget unzip tar ca-certificates openssl >/dev/null 2>&1
            else
                yum install -y jq curl wget unzip tar ca-certificates openssl >/dev/null 2>&1
            fi
            ;;
        *)
            warn "未识别的系统，尝试使用通用命令安装依赖..."
            ;;
    esac
}

# 获取 Sing-Box 最新版本号
get_latest_version() {
    info "正在检索官方 GitHub 库最新版本号..."
    LATEST_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [ -z "$LATEST_VER" ] || [ "$LATEST_VER" = "null" ]; then
        LATEST_VER="v1.11.2" # 经典高兼容备用版
        warn "获取最新版本号超时，将使用稳定备用版: ${LATEST_VER}"
    else
        success "最新版本号获取成功: ${LATEST_VER}"
    fi
    VERSION_NUM="${LATEST_VER#v}"
}

# 部署 Web 静态 UI
deploy_web_ui() {
    local temp_dir="$1"
    info "正在下载现代化 Web 控制面板 (MetaCubeXD)..."
    UI_URL="https://github.com/MetaCubeX/MetaCubeXD/archive/refs/heads/gh-pages.zip"

    if ! wget -q --show-progress -O "${temp_dir}/panel.zip" "$UI_URL"; then
        warn "主控面板下载超时，正在切换备用 Yacd 极简控制面板..."
        UI_URL="https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip"
        if ! wget -q --show-progress -O "${temp_dir}/panel.zip" "$UI_URL"; then
            error "控制面板静态资产下载失败，请检查网络。"
            return 1
        fi
    fi

    unzip -q "${temp_dir}/panel.zip" -d "$temp_dir"
    rm -rf "${SB_UI_DIR:?}"/*

    # 精准检索 index.html 所在的静态根目录
    local real_src_dir=$(find "$temp_dir" -name "index.html" -exec dirname {} \; | head -n 1)
    if [[ -n "$real_src_dir" && -d "$real_src_dir" ]]; then
        cp -r "$real_src_dir"/* "$SB_UI_DIR/"
        success "Web 面板资源部署成功: $SB_UI_DIR"
        return 0
    else
        error "解压文件中未找到关键入口网页 index.html！"
        return 1
    fi
}

# 转换标准的 shadowsocks 2022 url-safe base64 格式
to_urlsafe_base64() {
    local input="$1"
    printf "%s" "$input" | base64 | tr '+/' '-_' | tr -d '=' | tr -d '\n\r'
}

# 主安装逻辑
install_main() {
    detect_os
    install_deps
    get_latest_version

    mkdir -p "$SB_DIR"
    mkdir -p "$SB_UI_DIR"

    # 下载并部署二进制主程序
    info "正在下载 Sing-Box ${LATEST_VER} ($ARCH)..."
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VER}/sing-box-${VERSION_NUM}-linux-${ARCH}.tar.gz"

    TEMP_DIR=$(mktemp -d)
    if ! wget -q --show-progress -O "${TEMP_DIR}/sing-box.tar.gz" "$DOWNLOAD_URL"; then
        error "下载 Sing-Box 核心程序失败，请自检网络连接。"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    tar -zxf "${TEMP_DIR}/sing-box.tar.gz" -C "$TEMP_DIR"
    cp $(find "$TEMP_DIR" -type f -name "sing-box" | head -n 1) "$SB_BIN"
    chmod +x "$SB_BIN"
    success "Sing-Box 核心程序成功安装至: $SB_BIN"

    # 部署 Web 静态 UI
    deploy_web_ui "$TEMP_DIR"
    rm -rf "$TEMP_DIR"

    # 引导用户设置端口和凭证
    echo "--------------------------------------------------"
    readp "设置 Web 面板通信端口 [1-65535] (回车默认 9090): " WEB_PORT
    [[ -z "$WEB_PORT" ]] && WEB_PORT=9090

    # 自动生成 12 字节安全 Web Secret
    AUTO_SECRET=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 12)
    [[ -z "$AUTO_SECRET" ]] && AUTO_SECRET="sbSecret99"
    readp "设置面板连接安全密钥 Secret (回车使用随机密钥 ${AUTO_SECRET}): " WEB_SECRET
    [[ -z "$WEB_SECRET" ]] && WEB_SECRET="$AUTO_SECRET"

    # 自动生成 16 字节 Shadowsocks 密码 (AES-128)
    AUTO_SS_PWD=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r')
    readp "设置 Shadowsocks 2022 代理密码 (回车自动生成随机密钥): " SS_PWD
    [[ -z "$SS_PWD" ]] && SS_PWD="$AUTO_SS_PWD"

    readp "设置 Shadowsocks 代理端口 [1-65535] (回车默认随机端口): " SS_PORT
    if [[ -z "$SS_PORT" ]]; then
        SS_PORT=$(shuf -i 10000-60000 -n 1)
    fi

    readp "设置本地 Mixed (Socks/HTTP) 混合代理端口 (回车默认 2080): " MIXED_PORT
    [[ -z "$MIXED_PORT" ]] && MIXED_PORT=2080
    echo "--------------------------------------------------"

    # 写入完美配置
    cat > "$SB_CONFIG" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:${WEB_PORT}",
      "external_ui": "ui",
      "secret": "${WEB_SECRET}",
      "default_mode": "rule"
    }
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${SS_PORT},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${SS_PWD}"
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": ${MIXED_PORT},
      "sniff": true,
      "sniff_override_destination": true
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
    success "Sing-Box 配置文件生成完毕: $SB_CONFIG"

    # 配置系统服务与守护程序
    setup_system_service

    # 创建快捷管理工具 sb
    create_sb_shortcut

    # 获取外部公网 IP 显示信息
    local external_ip=$(curl -s4m5 icanhazip.com || curl -s4m5 api.ipify.org || echo "YOUR_SERVER_IP")
    
    # 自动生成 SS 链接
    local userinfo="2022-blake3-aes-128-gcm:${SS_PWD}"
    local encoded_userinfo=$(to_urlsafe_base64 "$userinfo")
    local ss_uri="ss://${encoded_userinfo}@${external_ip}:${SS_PORT}#singbox-ss2022"
    echo "$ss_uri" > "$SS_URI_PATH"

    echo -e "\n${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}      🎉 Sing-Box 核心与自托管面板部署成功！${PLAIN}"
    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "1. 💻 静态控制面板地址: ${BLUE}http://${external_ip}:${WEB_PORT}/ui/${PLAIN}"
    echo -e "2. 🔑 外部控制安全密钥 (Secret): ${PURPLE}${WEB_SECRET}${PLAIN}"
    echo -e "3. 🔌 Shadowsocks 2022 端口: ${BLUE}${SS_PORT}${PLAIN}"
    echo -e "4. 🔗 专属 SS 节点链接 (SIP002):"
    echo -e "   ${BLUE}${ss_uri}${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "💡 温馨提示: 终端随时输入 ${GREEN}sb${PLAIN} 即可调出全功能管理面板！"
    echo -e "${GREEN}==================================================${PLAIN}\n"
}

# 注册开机自启系统服务 (Systemd 与 OpenRC 智能自动区分)
setup_system_service() {
    info "正在注册底层开机运行守护服务..."
    if [ "$OS" = "alpine" ]; then
        local service_path="/etc/init.d/sing-box"
        cat > "$service_path" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server with Custom Web UI"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        chmod +x "$service_path"
        rc-update add sing-box default >/dev/null 2>&1 || true
        rc-service sing-box restart || true
    else
        local service_path="/etc/systemd/system/sing-box.service"
        cat > "$service_path" <<EOF
[Unit]
Description=Sing-box Proxy Server with Custom Web UI
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=${SB_BIN} run -c ${SB_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box >/dev/null 2>&1
    fi
    success "开机自启系统服务注册成功！"
}

# 创建 sb 命令行实用工具
create_sb_shortcut() {
    cat > "$SB_SHORTCUT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
#  Sing-Box 面板自建本地管理进程 (sb)
# ====================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
PLAIN='\033[0m'

CONFIG_PATH="/etc/sing-box/config.json"
SS_URI_PATH="/etc/sing-box/ss_uri.txt"
SB_BIN="/usr/bin/sing-box"

info() { echo -e "${BLUE}[信息]${PLAIN} $*"; }
success() { echo -e "${GREEN}[成功]${PLAIN} $*"; }
warn() { echo -e "${YELLOW}[警告]${PLAIN} $*"; }
error() { echo -e "${RED}[错误]${PLAIN} $*"; }
readp() { read -p "$(echo -e "${YELLOW}$1${PLAIN}")" $2; }

detect_service_system() {
    if [ -x "$(command -v rc-service)" ]; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="systemd"
    fi
}
detect_service_system

manage_service() {
    local action="$1"
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-service sing-box "$action"
    else
        systemctl "$action" sing-box
    fi
}

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://icanhazip.com"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    echo "YOUR_SERVER_IP"
}

to_urlsafe_base64() {
    local input="$1"
    printf "%s" "$input" | base64 | tr '+/' '-_' | tr -d '=' | tr -d '\n\r'
}

# 1. 查看控制面板及节点连接信息
action_view_info() {
    [ -f "$CONFIG_PATH" ] || { error "配置文件不存在！"; return 1; }
    
    local web_port=$(jq -r '.experimental.clash_api.external_controller' "$CONFIG_PATH" | cut -d':' -f2)
    local secret=$(jq -r '.experimental.clash_api.secret' "$CONFIG_PATH")
    local ss_port=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .listen_port' "$CONFIG_PATH")
    local ss_pwd=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .password' "$CONFIG_PATH")
    local mixed_port=$(jq -r '.inbounds[] | select(.tag == "mixed-in") | .listen_port' "$CONFIG_PATH")
    local external_ip=$(get_public_ip)

    # 重新生成最新 URI
    local userinfo="2022-blake3-aes-128-gcm:${ss_pwd}"
    local encoded_userinfo=$(to_urlsafe_base64 "$userinfo")
    local ss_uri="ss://${encoded_userinfo}@${external_ip}:${ss_port}#singbox-ss2022"
    echo "$ss_uri" > "$SS_URI_PATH"

    echo -e "\n${BLUE}==================================================${PLAIN}"
    echo -e "       🌌 Sing-Box Web 自托管服务运行数据"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "💻 静态面板 URL 地址 : ${GREEN}http://${external_ip}:${web_port}/ui/${PLAIN}"
    echo -e "🔑 面板安全通信 Secret: ${PURPLE}${secret}${PLAIN}"
    echo -e "🔌 Shadowsocks 监听端口: ${BLUE}${ss_port}${PLAIN}"
    echo -e "🔑 Shadowsocks 密码密钥: ${BLUE}${ss_pwd}${PLAIN}"
    echo -e "🔌 Mixed 混合代理监听端口: ${BLUE}${mixed_port}${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "🔗 Shadowsocks 2022 节点 URI 地址 :"
    echo -e "   ${GREEN}${ss_uri}${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
}

# 2. 修改端口/访问密钥
action_reset_port_pwd() {
    [ -f "$CONFIG_PATH" ] || { error "配置文件不存在！"; return 1; }
    
    echo -e "\n${BLUE}--- 重置网络端口与安全配置 (留空回车则维持原样) ---${PLAIN}"
    readp "请输入新的 Web 面板监听端口: " new_web_port
    readp "请输入新的 Web 连接安全密钥 Secret: " new_secret
    readp "请输入新的 Shadowsocks 2022 代理端口: " new_ss_port
    readp "请输入新的 Shadowsocks 2022 访问密码: " new_ss_pwd
    readp "请输入新的 Mixed 混合监听代理端口: " new_mixed_port

    if [[ -n "$new_web_port" ]]; then
        jq ".experimental.clash_api.external_controller = \"0.0.0.0:${new_web_port}\"" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi
    if [[ -n "$new_secret" ]]; then
        jq ".experimental.clash_api.secret = \"${new_secret}\"" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi
    if [[ -n "$new_ss_port" ]]; then
        jq "(.inbounds[] | select(.tag == \"ss-in\") | .listen_port) = ${new_ss_port}" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi
    if [[ -n "$new_ss_pwd" ]]; then
        jq "(.inbounds[] | select(.tag == \"ss-in\") | .password) = \"${new_ss_pwd}\"" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi
    if [[ -n "$new_mixed_port" ]]; then
        jq "(.inbounds[] | select(.tag == \"mixed-in\") | .listen_port) = ${new_mixed_port}" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    info "正在重启守护服务加载新配置中..."
    manage_service restart
    success "面板配置重构更新成功！"
    action_view_info
}

# 3. 查看实时服务运行日志
action_view_logs() {
    info "正在调取进程控制台输出流 (按 Ctrl+C 退出)..."
    sleep 1
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        tail -f -n 50 /var/log/sing-box.err 2>/dev/null || tail -f -n 50 /var/log/sing-box.log
    else
        journalctl -u sing-box -f -n 50 --no-pager
    fi
}

# 4. 手动在线升级 Sing-box 核心
action_upgrade() {
    info "正在检测并连接官方仓库进行核心升级..."
    local latest_ver=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [ -z "$latest_ver" ] || [ "$latest_ver" = "null" ]; then
        error "无法连接至 GitHub API 获取最新版本。"
        return 1
    fi
    local ver_num="${latest_ver#v}"
    local arch=""
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
    esac

    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_ver}/sing-box-${ver_num}-linux-${arch}.tar.gz"
    local temp_dir=$(mktemp -d)
    if ! wget -q --show-progress -O "${temp_dir}/sing-box.tar.gz" "$download_url"; then
        error "更新升级包下载失败！"
        rm -rf "$temp_dir"
        return 1
    fi
    manage_service stop
    tar -zxf "${temp_dir}/sing-box.tar.gz" -C "$temp_dir"
    cp $(find "$temp_dir" -type f -name "sing-box" | head -n 1) "$SB_BIN"
    chmod +x "$SB_BIN"
    rm -rf "$temp_dir"
    
    manage_service start
    success "核心组件成功热升级至最新版本: ${latest_ver}"
}

# 5. 卸载清除
action_uninstall() {
    info "正在停止进程并撤销开机自启..."
    manage_service stop >/dev/null 2>&1 || true
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-update del sing-box default >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box
    else
        systemctl disable sing-box >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /usr/local/bin/sb "$SB_BIN"
    success "Sing-Box 核心服务与 Web 控制面板已完全卸载并清除残留！"
}

# 6. 编辑原始 JSON
action_edit_json() {
    local editor="${EDITOR:-vi}"
    if command -v nano >/dev/null 2>&1; then
        editor="nano"
    fi
    $editor "$CONFIG_PATH"
    
    info "正在校验配置文件完整性..."
    if "$SB_BIN" check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        success "配置文件校验无误，正在重启服务应用更改..."
        manage_service restart
    else
        error "新配置文件语法不符合规范，服务未重启。请重新检查修改！"
    fi
}

show_interactive_menu() {
    clear
    echo -e "${PURPLE}==================================================${PLAIN}"
    echo -e "${PURPLE}    🌌 Sing-Box Web自托管服务 本地交互命令行 (sb) ${PLAIN}"
    echo -e "${PURPLE}==================================================${PLAIN}"
    echo -e " 1. 查看 静态面板访问路径 / 安全 Secret / 节点连接"
    echo -e " 2. 修改/重置 面板端口、安全通信Secret及代理端口"
    echo -e " 3. 管理 核心系统服务 (启动/停止/重启)"
    echo -e " 4. 实时 查看后端服务控制台运行日志"
    echo -e " 5. 手动 在线热升级 Sing-Box 核心组件"
    echo -e " 6. 打开 原始配置文件 (JSON) 文本编辑器"
    echo -e " 7. 彻底 卸载并清除 Sing-Box 核心与 Web 面板"
    echo -e " 0. 退出控制面板"
    echo -e "${PURPLE}==================================================${PLAIN}"
    
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        if rc-service sing-box status 2>/dev/null | grep -q "started"; then
            echo -e "运行状态: ${GREEN}运行中 (Active)${PLAIN}"
        else
            echo -e "运行状态: ${RED}未运行 (Stopped)${PLAIN}"
        fi
    else
        if systemctl is-active --quiet sing-box; then
            echo -e "运行状态: ${GREEN}运行中 (Active)${PLAIN}"
        else
            echo -e "运行状态: ${RED}未运行 (Stopped)${PLAIN}"
        fi
    fi
    echo -e "=================================================="

    readp "请输入您的指令 [0-7]: " menu_choice
    case "$menu_choice" in
        1) action_view_info ;;
        2) action_reset_port_pwd ;;
        3) 
            echo -e "\n1. 重启服务  2. 停止服务  3. 启动服务"
            readp "请选择: " cmd_act
            [[ "$cmd_act" = "1" ]] && { manage_service restart && success "重启成功！"; }
            [[ "$cmd_act" = "2" ]] && { manage_service stop && success "停止成功！"; }
            [[ "$cmd_act" = "3" ]] && { manage_service start && success "启动成功！"; }
            ;;
        4) action_view_logs ;;
        5) action_upgrade ;;
        6) action_edit_json ;;
        7) action_uninstall; exit 0 ;;
        0) exit 0 ;;
        *) error "指令输入错误，请重新选择！" && sleep 1 ;;
    esac
}

while true; do
    show_interactive_menu
    echo -e "\n回车按任意键继续返回主菜单..."
    read -n 1
done
EOF
    chmod +x "$SB_SHORTCUT"
}

# 启动一键部署流程
install_main

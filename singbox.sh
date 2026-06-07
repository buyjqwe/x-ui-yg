#!/bin/bash

# ====================================================================
#  脚本名称: Sing-Box & Local Web Panel (MetaCubeXD) 一键安装管理脚本
#  系统支持: Debian, Ubuntu, CentOS, Rocky Linux (Systemd 兼容)
#  适用架构: AMD64, ARM64
#  主要特点: 
#    1. 自动获取并安装最新官方 Sing-Box 核心
#    2. 零外部 Web 依赖 (无 Nginx/Python)，Sing-Box 自行托管 Web 面板
#    3. 自动安装最现代化的 MetaCubeXD 极简美学控制台
#    4. 支持安全密钥 (Secret) 验证，保障面板不被非法扫描
#    5. 完美兼容 OpenVZ、LXC 等限制型虚拟化平台，自带一键诊断修复工具
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
info() { echo -e "${BLUE}[信息]${PLAIN} $1"; }
success() { echo -e "${GREEN}[成功]${PLAIN} $1"; }
warn() { echo -e "${YELLOW}[警告]${PLAIN} $1"; }
error() { echo -e "${RED}[错误]${PLAIN} $1"; }
readp() { read -p "$(echo -e "${YELLOW}$1${PLAIN}")" $2; }

# 权限验证
[[ $EUID -ne 0 ]] && error "请使用 root 权限或 sudo 运行此脚本！" && exit 1

# 基础目录配置
SB_DIR="/etc/sing-box"
SB_BIN="/usr/local/bin/sing-box"
SB_UI_DIR="${SB_DIR}/ui"
SB_CONFIG="${SB_DIR}/config.json"

# 检测系统与架构
detect_env() {
    # 检测架构
    case $(uname -m) in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) error "暂不支持当前的 $(uname -m) CPU 架构" && exit 1 ;;
    esac

    # 检测系统包管理器
    if [ -x "$(command -v apt-get)" ]; then
        PM="apt"
    elif [ -x "$(command -v dnf)" ]; then
        PM="dnf"
    elif [ -x "$(command -v yum)" ]; then
        PM="yum"
    else
        error "未能识别的系统包管理器，请在 Debian/Ubuntu/CentOS/Rocky 下运行。" && exit 1
    fi
}

# 安装必要依赖
install_deps() {
    info "正在检测并安装基础系统依赖 (curl, wget, tar, unzip, jq)..."
    if [ "$PM" = "apt" ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar unzip jq -y >/dev/null 2>&1
    else
        $PM install -y curl wget tar unzip jq -y >/dev/null 2>&1
    fi
}

# 获取最新 Sing-Box 版本
get_latest_version() {
    info "正在获取 Sing-Box 最新官方版本号..."
    LATEST_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [ -z "$LATEST_VER" ] || [ "$LATEST_VER" = "null" ]; then
        LATEST_VER="v1.11.2" # 备用高稳定性版本
        warn "通过 GitHub API 获取版本失败，将采用备用稳定版: ${LATEST_VER}"
    else
        success "成功获取最新官方版本: ${LATEST_VER}"
    fi
    # 去除 'v' 前缀以供构建 URL
    VERSION_NUM="${LATEST_VER#v}"
}

# 部署静态面板资源 (高可靠精准提取算法)
deploy_web_ui() {
    local temp_dir="$1"
    info "正在部署现代化 Web 控制面板 (MetaCubeXD)..."
    UI_URL="https://github.com/MetaCubeX/MetaCubeXD/archive/refs/heads/gh-pages.zip"
    
    if ! wget -q --show-progress -O "${temp_dir}/panel.zip" "$UI_URL"; then
        warn "下载主控制面板失败，正在尝试使用备用 Yacd 极简控制台..."
        UI_URL="https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip"
        if ! wget -q --show-progress -O "${temp_dir}/panel.zip" "$UI_URL"; then
            error "控制面板资源全部下载失败，请检查服务器网络。"
            return 1
        fi
    fi

    unzip -q "${temp_dir}/panel.zip" -d "$temp_dir"
    rm -rf "${SB_UI_DIR:?}"/*
    
    # 动态递归定位解压目录中 index.html 所在的真实根目录
    local real_src_dir=$(find "$temp_dir" -name "index.html" -exec dirname {} \; | head -n 1)
    if [[ -n "$real_src_dir" && -d "$real_src_dir" ]]; then
        cp -r "$real_src_dir"/* "$SB_UI_DIR/"
        success "Web 面板静态资源已成功高可靠部署至: $SB_UI_DIR"
        return 0
    else
        error "解压后的目录中未找到关键引导主页 index.html！"
        return 1
    fi
}

# 部署并构建 Web 控制面板
install_singbox() {
    detect_env
    install_deps
    get_latest_version

    # 创建工作目录
    mkdir -p "$SB_DIR"
    mkdir -p "$SB_UI_DIR"

    # 下载并提取二进制
    info "正在下载 Sing-Box ${LATEST_VER} ($ARCH)..."
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VER}/sing-box-${VERSION_NUM}-linux-${ARCH}.tar.gz"
    
    TEMP_DIR=$(mktemp -d)
    if ! wget -q --show-progress -O "${TEMP_DIR}/sing-box.tar.gz" "$DOWNLOAD_URL"; then
        error "下载 Sing-Box 核心失败，请检查您的服务器与 GitHub 的网络连接。"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    tar -zxf "${TEMP_DIR}/sing-box.tar.gz" -C "$TEMP_DIR"
    cp $(find "$TEMP_DIR" -type f -name "sing-box" | head -n 1) "$SB_BIN"
    chmod +x "$SB_BIN"
    success "Sing-Box 主程序已成功部署至 $SB_BIN"

    # 部署网页静态面板
    deploy_web_ui "$TEMP_DIR"

    # 清理临时工作区
    rm -rf "$TEMP_DIR"

    # 引导用户输入 Web 面板配置
    echo "--------------------------------------------------"
    readp "请设置 Web 面板访问端口 (默认 9090): " WEB_PORT
    [[ -z "$WEB_PORT" ]] && WEB_PORT=9090
    
    # 自动生成安全密钥
    AUTO_SECRET=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 12)
    [[ -z "$AUTO_SECRET" ]] && AUTO_SECRET="sbSecret520"
    readp "请设置面板连接安全密钥 Secret (回车使用随机密钥 ${AUTO_SECRET}): " WEB_SECRET
    [[ -z "$WEB_SECRET" ]] && WEB_SECRET="$AUTO_SECRET"

    readp "请设置本地混合监听代理端口 (如SOCKS5/HTTP, 默认 2080): " MIXED_PORT
    [[ -z "$MIXED_PORT" ]] && MIXED_PORT=2080
    echo "--------------------------------------------------"

    # 创建纯净无冲突的基础 config.json
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
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
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
    success "Sing-Box 纯净配置文件已生成: $SB_CONFIG"

    # 注册 Systemd 守护进程 (移除导致 OpenVZ/LXC 启动失败的 Capability sandboxing Directive)
    info "正在配置自适应 Systemd 守护服务..."
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${SB_BIN} run -c ${SB_CONFIG}
WorkingDirectory=${SB_DIR}
Restart=always
RestartSec=5
LimitN_FILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box >/dev/null 2>&1

    # 自动开启防火墙端口 (如有必要)
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --add-port=${WEB_PORT}/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=${MIXED_PORT}/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v ufw >/dev/null 2>&1; then
        ufw allow ${WEB_PORT}/tcp >/dev/null 2>&1
        ufw allow ${MIXED_PORT}/tcp >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
    fi

    # 获取本机的外部访问 IP 地址
    local external_ip=$(curl -s4m5 icanhazip.com || curl -s4m5 api.ipify.org || echo "您的服务器公网IP")

    echo -e "\n${GREEN}==================================================${PLAIN}"
    echo -e "${GREEN}      🎉 Sing-Box 核心及 Web 控制面板部署完成！${PLAIN}"
    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "1. 💻 面板访问连接: ${BLUE}http://${external_ip}:${WEB_PORT}/ui/${PLAIN}"
    echo -e "2. 🔑 面板安全密钥 (Secret): ${PURPLE}${WEB_SECRET}${PLAIN}"
    echo -e "   ${YELLOW}(注: 首次打开页面，请在弹出设置框中填入该 Secret 即可完成通信)${PLAIN}"
    echo -e "3. 🔌 本地多协议混合监听端口: ${BLUE}${MIXED_PORT}${PLAIN}"
    echo -e "4. 📂 配置文件路径: ${BLUE}${SB_CONFIG}${PLAIN}"
    echo -e "5. 📁 静态面板资源目录: ${BLUE}${SB_UI_DIR}${PLAIN}"
    echo -e "${GREEN}==================================================${PLAIN}\n"
}

# 自动诊断核心启动失败原因并执行自我修复
diagnose_failures() {
    info "正在启动一键诊断程序..."
    sleep 1

    # 1. 验证主程序是否存在
    if [ ! -f "$SB_BIN" ]; then
        error "检测失败：主二进制程序 $SB_BIN 不存在，请执行选项 1 重新安装。"
        return 1
    fi
    chmod +x "$SB_BIN"

    # 2. 验证二进制可用性 (防止 CPU 架构错误导致执行异常)
    if ! "$SB_BIN" version >/dev/null 2>&1; then
        error "主程序加载异常！该二进制程序无法在当前的 CPU 架构或系统环境下执行。"
        warn "可能原因：系统架构不兼容，或当前系统缺少标准 C 动态运行库库依赖。"
        return 1
    fi

    # 3. 验证 JSON 语法
    if [ ! -f "$SB_CONFIG" ]; then
        error "配置文件 $SB_CONFIG 缺失。"
        return 1
    fi

    info "正在对配置文件进行格式与语法完整性校验..."
    local check_output
    check_output=$("$SB_BIN" check -c "$SB_CONFIG" 2>&1)
    if [ $? -ne 0 ]; then
        error "校验未通过！配置文件中存在格式或参数类型错误，具体诊断如下："
        echo -e "${RED}${check_output}${PLAIN}"
        return 1
    else
        success "配置文件 JSON 校验完成，未发现语法缺陷。"
    fi

    # 4. 检查静态 Web 资源
    if [ ! -f "${SB_UI_DIR}/index.html" ]; then
        warn "静态网页资源文件夹为空，或缺少 index.html，这可能会导致服务异常退出。"
        info "正在尝试重新修复网页资源下载..."
        local re_temp=$(mktemp -d)
        deploy_web_ui "$re_temp"
        rm -rf "$re_temp"
    fi

    # 5. 排查端口抢占
    local web_port=$(jq -r '.experimental.clash_api.external_controller' "$SB_CONFIG" 2>/dev/null | cut -d':' -f2)
    local mixed_port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG" 2>/dev/null)
    
    if [[ -n "$web_port" && -n "$mixed_port" ]]; then
        info "正在检索系统中运行的端口是否与当前端口产生冲突..."
        local port_conflict=0
        if command -v ss &>/dev/null; then
            if ss -tunlp | grep -q ":${web_port} "; then
                error "端口 ${web_port} 已被服务器上其他服务抢占，导致核心无法启动！"
                port_conflict=1
            fi
            if ss -tunlp | grep -q ":${mixed_port} "; then
                error "混合监听端口 ${mixed_port} 已被其他进程绑定！"
                port_conflict=1
            fi
        fi

        if [ $port_conflict -eq 1 ]; then
            info "修复方案：请使用菜单选项 5 将端口变更为目前未使用的空闲端口。"
            return 1
        fi
    fi

    # 6. 前台测试与重构 Systemd
    info "正在进行前台运行环境试跑分析以获取深层报错..."
    local temp_run_log="/tmp/sb_dry.log"
    timeout 3 "$SB_BIN" run -c "$SB_CONFIG" > "$temp_run_log" 2>&1
    local run_status=$?

    # 124 代表 timeout 命令由于时间到正常退出，说明服务前台拉起一切正常
    if [ $run_status -eq 124 ]; then
        success "前台环境试跑验证成功，未返回致命异常代码。"
        info "确认是 Systemd 虚拟化配置兼容性引起，正在重构 Systemd 守护逻辑并修复权限..."
        
        # 强制重写极简开机启动
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${SB_BIN} run -c ${SB_CONFIG}
WorkingDirectory=${SB_DIR}
Restart=always
RestartSec=5
LimitN_FILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl restart sing-box
        sleep 2
        
        if systemctl is-active --quiet sing-box; then
            success "恭喜！Sing-Box 服务已成功重构修复，并正常启动成功。"
        else
            error "服务修复应用后依然未能按预期成功拉起，请使用选项 4 获取实时系统日志。"
        fi
    else
        error "核心启动阶段返回了致命错误，报错日志如下："
        cat "$temp_run_log"
    fi
    rm -f "$temp_run_log"
}

# 卸载功能
uninstall_singbox() {
    readp "此操作将彻底删除 Sing-Box 核心、静态面板以及所有的配置。确定卸载？(y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        systemctl stop sing-box >/dev/null 2>&1
        systemctl disable sing-box >/dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload >/dev/null 2>&1
        
        rm -rf "$SB_DIR"
        rm -f "$SB_BIN"
        
        success "Sing-Box 及其专属托管 Web 控制面板已从系统中彻底清除！"
    else
        info "卸载已取消。"
    fi
}

# 服务状态控制
manage_service() {
    echo -e "\n${BLUE}--- 服务控制选项 ---${PLAIN}"
    echo "1. 重启 Sing-Box 核心服务"
    echo "2. 停止 Sing-Box 服务"
    echo "3. 启动 Sing-Box 服务"
    echo "0. 返回主菜单"
    readp "请选择: " s_choice
    case "$s_choice" in
        1)
            systemctl restart sing-box && success "服务已成功重启。"
            ;;
        2)
            systemctl stop sing-box && success "服务已停止。"
            ;;
        3)
            systemctl start sing-box && success "服务已恢复运行。"
            ;;
        *)
            show_menu
            ;;
    esac
}

# 更改密钥与端口
change_settings() {
    if [ ! -f "$SB_CONFIG" ]; then
        error "未检测到已安装的 Sing-Box 配置，请先执行安装。"
        return
    fi
    
    echo -e "\n${BLUE}--- 修改面板及代理配置 ---${PLAIN}"
    readp "请输入新的 Web 访问端口: " new_port
    readp "请输入新的 Web 连接密钥 (Secret): " new_secret
    readp "请输入新的混合监听代理端口: " new_mixed_port
    
    if [[ -n "$new_port" ]]; then
        jq ".experimental.clash_api.external_controller = \"0.0.0.0:${new_port}\"" "$SB_CONFIG" > "${SB_CONFIG}.tmp" && mv "${SB_CONFIG}.tmp" "$SB_CONFIG"
    fi
    
    if [[ -n "$new_secret" ]]; then
        jq ".experimental.clash_api.secret = \"${new_secret}\"" "$SB_CONFIG" > "${SB_CONFIG}.tmp" && mv "${SB_CONFIG}.tmp" "$SB_CONFIG"
    fi

    if [[ -n "$new_mixed_port" ]]; then
        jq ".inbounds[0].listen_port = ${new_mixed_port}" "$SB_CONFIG" > "${SB_CONFIG}.tmp" && mv "${SB_CONFIG}.tmp" "$SB_CONFIG"
    fi

    systemctl restart sing-box
    success "参数更新成功，Sing-Box 已经重启应用新配置。"
}

# 查看运行日志
show_logs() {
    info "正在调取 Systemd 实时服务运行日志 (按 Ctrl+C 即可退出查看)..."
    sleep 1
    journalctl -u sing-box.service -f -n 50
}

# 显示主菜单
show_menu() {
    clear
    echo -e "${PURPLE}==================================================${PLAIN}"
    echo -e "${PURPLE}    🌌 Sing-Box 纯净安装 & 官方级 Web 托管面板 ${PLAIN}"
    echo -e "${PURPLE}==================================================${PLAIN}"
    echo -e " 1. 一键安装 Sing-Box & 官方托管 MetaCubeXD 面板"
    echo -e " 2. 彻底卸载 Sing-Box 及 Web 面板"
    echo -e "--------------------------------------------------"
    echo -e " 3. 管理 Sing-Box 服务的 运行/停止/重启"
    echo -e " 4. 实时查看 Sing-Box 核心系统运行日志"
    echo -e " 5. 变更 面板端口 / 安全密钥 (Secret) / 代理监听"
    echo -e " 6. 🛠️ 一键诊断核心启动失败原因并执行自动修复"
    echo -e "--------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo -e "${PURPLE}==================================================${PLAIN}"
    
    # 检测运行状态
    if [ -f "$SB_BIN" ]; then
        if systemctl is-active --quiet sing-box; then
            echo -e "当前核心状态: ${GREEN}运行中 (Active)${PLAIN}"
            # 动态获取配置文件中的 Web 控制器端口和 Secret
            local cur_port=$(jq -r '.experimental.clash_api.external_controller' "$SB_CONFIG" 2>/dev/null | cut -d':' -f2)
            local cur_secret=$(jq -r '.experimental.clash_api.secret' "$SB_CONFIG" 2>/dev/null)
            echo -e "面板访问路径: ${BLUE}http://服务器IP:${cur_port}/ui/${PLAIN}"
            echo -e "当前访问密钥: ${PURPLE}${cur_secret}${PLAIN}"
        else
            echo -e "当前核心状态: ${RED}未运行 (Stopped)${PLAIN}"
        fi
    else
        echo -e "当前核心状态: ${RED}未安装${PLAIN}"
    fi
    echo "=================================================="
    
    readp "请输入您的选择 [0-6]: " main_choice
    case "$main_choice" in
        1) install_singbox ;;
        2) uninstall_singbox ;;
        3) manage_service ;;
        4) show_logs ;;
        5) change_settings ;;
        6) diagnose_failures ;;
        0) exit 0 ;;
        *) error "输入错误，请重新选择！" && sleep 1 && show_menu ;;
    esac
}

# 循环保持
while true; do
    show_menu
    echo -e "\n按任意键返回主菜单..."
    read -n 1
done

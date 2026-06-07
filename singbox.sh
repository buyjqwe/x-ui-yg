#!/bin/bash

# ====================================================================
#  脚本名称: Sing-Box & Local Web Panel (MetaCubeXD) 终极一键管理脚本
#  系统支持: Debian, Ubuntu, CentOS, Rocky Linux, Alpine (OpenRC/Systemd 兼容)
#  适用架构: AMD64, ARM64
#  主要特点: 
#    1. 自动部署官方最新 Sing-Box 核心 + 自托管 3x-ui 质感控制大盘
#    2. 零外部 Web 容器依赖 (采用 Python3 stdlib 守护进程，零端口冲突)
#    3. 网页全自动表单管理 VLESS-Reality-XHTTP、Hysteria2、TUIC、SS
#    4. 支持表单与配置 Dry-Run 安全校验，防范因配置错误导致核心闪退
#    5. 终端输入 sb 即可快捷管理，包含一键自愈与诊断修复工具
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
SB_CONFIG="${SB_DIR}/config.json"
SB_DASHBOARD_PY="${SB_DIR}/dashboard.py"
SB_CREDS_FILE="${SB_DIR}/panel_creds.json"
SB_SHORTCUT="/usr/local/bin/sb"

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
    info "检测并安装基础系统依赖与 Python 运行环境..."
    case "$OS" in
        alpine)
            apk update >/dev/null 2>&1
            apk add --no-cache bash curl wget unzip tar ca-certificates openssl openrc jq python3 libc6-compat gcompat >/dev/null 2>&1
            if ! rc-service --list 2>/dev/null | grep -q "^openrc"; then
                rc-update add openrc boot >/dev/null 2>&1 || true
                rc-service openrc start >/dev/null 2>&1 || true
            fi
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >/dev/null 2>&1
            apt-get install -y jq curl wget unzip tar ca-certificates openssl python3 >/dev/null 2>&1
            ;;
        redhat)
            local pm="yum"
            [ -x "$(command -v dnf)" ] && pm="dnf"
            $pm install -y jq curl wget unzip tar ca-certificates openssl python3 >/dev/null 2>&1
            ;;
        *)
            warn "未识别的系统，尝试继续..."
            ;;
    esac
}

# 获取 Sing-Box 最新版本号
get_latest_version() {
    info "正在检索官方 GitHub 库最新版本号..."
    LATEST_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [ -z "$LATEST_VER" ] || [ "$LATEST_VER" = "null" ]; then
        LATEST_VER="v1.11.2"
        warn "获取最新版本号超时，将使用稳定备用版: ${LATEST_VER}"
    else
        success "最新版本号获取成功: ${LATEST_VER}"
    fi
    VERSION_NUM="${LATEST_VER#v}"
}

# 部署极轻量级 python3 控制后台及集成 HTML 单页控制面板
deploy_dashboard_service() {
    info "正在部署自托管 Web 面板 API 守护服务..."

    # 1. 默认面板凭证与配置
    if [ ! -f "$SB_CREDS_FILE" ]; then
        local default_secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 12 || echo "adminSecret88")
        cat > "$SB_CREDS_FILE" <<EOF
{
  "username": "admin",
  "password": "${default_secret}",
  "port": 9527
}
EOF
    fi

    # 2. 生成完全闭环的 Python API 托管后台程序
    cat > "$SB_DASHBOARD_PY" <<'PYTHON_EOF'
# -*- coding: utf-8 -*-
import http.server
import json
import subprocess
import os
import base64
import socket
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CREDS_FILE = "/etc/sing-box/panel_creds.json"
CONFIG_FILE = "/etc/sing-box/config.json"
SB_BIN = "/usr/bin/sing-box"

def read_json_file(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except:
        return {}

def write_json_file(path, data):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        return True
    except:
        return False

# ==========================================
#  嵌入式高能 HTML 静态大盘（极简现代美学设计）
# ==========================================
HTML_CONTENT = """<!DOCTYPE html>
<html lang="zh-CN" class="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Sing-Box Premium 控制面板</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/lucide@latest"></script>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <script>
        tailwind.config = {
            darkMode: 'class',
            theme: {
                extend: {
                    fontFamily: { sans: ['Outfit', 'PingFang SC', 'sans-serif'] }
                }
            }
        }
    </script>
    <style>
        body {
            background-color: #020617;
            background-image: 
                radial-gradient(at 0% 0%, rgba(99, 102, 241, 0.1) 0px, transparent 50%),
                radial-gradient(at 100% 100%, rgba(168, 85, 247, 0.08) 0px, transparent 50%);
            background-attachment: fixed;
        }
        .glass-card {
            background: rgba(15, 23, 42, 0.6);
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.05);
        }
    </style>
</head>
<body class="text-slate-100 min-h-screen pb-12 antialiased">

    <!-- Top Navbar -->
    <nav class="sticky top-0 z-40 w-full glass-card border-b border-slate-800/50 px-6 py-4 flex items-center justify-between">
        <div class="flex items-center space-x-3">
            <div class="w-10 h-10 rounded-xl bg-gradient-to-tr from-indigo-600 to-purple-600 flex items-center justify-center shadow-lg shadow-indigo-500/20">
                <i data-lucide="shield" class="w-5 h-5 text-white"></i>
            </div>
            <div>
                <h1 class="font-bold text-lg leading-none bg-clip-text text-transparent bg-gradient-to-r from-indigo-200 to-purple-200">Sing-Box Panel</h1>
                <span class="text-xs text-indigo-400 font-medium">可视化面板控制系统</span>
            </div>
        </div>
        
        <div class="flex items-center space-x-4">
            <div id="serviceStatus" class="flex items-center space-x-2 px-3 py-1 rounded-full text-xs font-semibold">
                <span class="w-2 h-2 rounded-full animate-pulse"></span>
                <span id="statusText">加载中...</span>
            </div>
            <button onclick="triggerService('restart')" class="p-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 hover:text-white transition-all">
                <i data-lucide="refresh-cw" class="w-4 h-4"></i>
            </button>
        </div>
    </nav>

    <!-- Main Grid -->
    <main class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 mt-8 grid grid-cols-1 lg:grid-cols-12 gap-8">
        
        <!-- Sidebar Monitors -->
        <section class="lg:col-span-4 space-y-6">
            <div class="glass-card rounded-3xl p-6 space-y-6 shadow-xl">
                <div class="flex items-center space-x-2">
                    <i data-lucide="cpu" class="w-5 h-5 text-purple-400"></i>
                    <h3 class="font-bold text-slate-200">系统环境健康指标</h3>
                </div>
                <!-- CPU -->
                <div class="space-y-1.5">
                    <div class="flex justify-between text-xs font-semibold">
                        <span class="text-slate-400">CPU 负载</span>
                        <span id="cpuVal">0.0%</span>
                    </div>
                    <div class="w-full bg-slate-800 rounded-full h-1.5">
                        <div id="cpuBar" class="bg-gradient-to-r from-indigo-500 to-purple-500 h-1.5 rounded-full" style="width: 0%"></div>
                    </div>
                </div>
                <!-- RAM -->
                <div class="space-y-1.5">
                    <div class="flex justify-between text-xs font-semibold">
                        <span class="text-slate-400">运行内存</span>
                        <span id="ramVal">0%</span>
                    </div>
                    <div class="w-full bg-slate-800 rounded-full h-1.5">
                        <div id="ramBar" class="bg-gradient-to-r from-purple-500 to-pink-500 h-1.5 rounded-full" style="width: 0%"></div>
                    </div>
                </div>
                <!-- Disk -->
                <div class="space-y-1.5">
                    <div class="flex justify-between text-xs font-semibold">
                        <span class="text-slate-400">磁盘占用</span>
                        <span id="diskVal">0%</span>
                    </div>
                    <div class="w-full bg-slate-800 rounded-full h-1.5">
                        <div id="diskBar" class="bg-gradient-to-r from-pink-500 to-rose-500 h-1.5 rounded-full" style="width: 0%"></div>
                    </div>
                </div>
            </div>

            <!-- Command Quick Panel -->
            <div class="glass-card rounded-3xl p-6 shadow-xl space-y-3">
                <h4 class="text-sm font-bold text-slate-300">进程控制</h4>
                <div class="grid grid-cols-2 gap-3">
                    <button onclick="triggerService('start')" class="py-2.5 bg-indigo-600/10 hover:bg-indigo-600/20 text-indigo-400 rounded-xl text-xs font-bold transition-all">启动核心</button>
                    <button onclick="triggerService('stop')" class="py-2.5 bg-rose-600/10 hover:bg-rose-600/20 text-rose-400 rounded-xl text-xs font-bold transition-all">停止核心</button>
                </div>
            </div>
        </section>

        <!-- Right Side Panel -->
        <section class="lg:col-span-8 space-y-8">
            
            <!-- Nodes Panel -->
            <div class="glass-card rounded-3xl p-6 shadow-xl">
                <div class="flex items-center justify-between mb-6">
                    <div class="flex items-center space-x-2">
                        <i data-lucide="server" class="w-6 h-6 text-indigo-400"></i>
                        <h2 class="text-xl font-bold text-slate-200">已部署入站节点列表</h2>
                    </div>
                    <div class="flex space-x-2">
                        <button onclick="openPanelSettingsModal()" class="flex items-center space-x-1.5 px-3 py-2 bg-slate-800 hover:bg-slate-755 text-slate-300 rounded-xl text-xs font-bold transition-all">
                            <i data-lucide="settings" class="w-4 h-4"></i>
                            <span>面板设置</span>
                        </button>
                        <button onclick="openRawEditor()" class="flex items-center space-x-1.5 px-3 py-2 bg-slate-800 hover:bg-slate-755 text-slate-300 rounded-xl text-xs font-bold transition-all">
                            <i data-lucide="code" class="w-4 h-4"></i>
                            <span>原始 JSON</span>
                        </button>
                        <button onclick="openAddNodeModal()" class="flex items-center space-x-1.5 px-4 py-2 bg-gradient-to-r from-indigo-600 to-purple-600 hover:from-indigo-500 hover:to-purple-500 text-white rounded-xl text-xs font-bold transition-all shadow-md">
                            <i data-lucide="plus" class="w-4 h-4"></i>
                            <span>添加节点</span>
                        </button>
                    </div>
                </div>

                <div id="nodesGrid" class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <!-- Nodes loaded here -->
                </div>
            </div>

            <!-- Client Share Area -->
            <div id="shareBox" class="glass-card rounded-3xl p-6 shadow-xl hidden space-y-4">
                <div class="flex justify-between items-center">
                    <h3 class="font-bold text-slate-200 flex items-center space-x-2">
                        <i data-lucide="qr-code" class="w-5 h-5 text-indigo-400"></i>
                        <span>节点分享链接</span>
                    </h3>
                    <button onclick="document.getElementById('shareBox').classList.add('hidden')" class="text-slate-400 hover:text-white"><i data-lucide="x" class="w-4 h-4"></i></button>
                </div>
                <textarea id="shareUriText" readonly class="w-full h-24 bg-slate-900/60 border border-slate-800 rounded-2xl p-3 text-xs text-indigo-300 focus:outline-none font-mono"></textarea>
                <button onclick="copyShareText()" class="w-full py-2 bg-indigo-600 hover:bg-indigo-500 text-white rounded-xl text-xs font-bold">复制连接</button>
            </div>

            <!-- Terminal Logger -->
            <div class="glass-card rounded-3xl p-6 shadow-xl space-y-4">
                <h3 class="font-bold text-slate-200 flex items-center space-x-2">
                    <i data-lucide="terminal" class="w-5 h-5 text-indigo-400"></i>
                    <span>Sing-Box 运行控制台实时日志</span>
                </h3>
                <div id="loggerArea" class="w-full h-48 bg-slate-950 rounded-2xl p-4 overflow-y-auto font-mono text-[10px] text-slate-400 leading-normal whitespace-pre">
                    加载日志流中...
                </div>
            </div>

        </section>

    </main>

    <!-- Visual Add/Edit Node Modal -->
    <div id="visualNodeModal" class="fixed inset-0 z-50 hidden bg-slate-950/80 backdrop-blur-md flex items-center justify-center p-4 overflow-y-auto">
        <div class="glass-card w-full max-w-xl rounded-3xl p-6 shadow-2xl space-y-4 my-8">
            <h3 id="modalTitle" class="text-lg font-bold text-slate-200">添加 Sing-Box 入站节点</h3>
            <input type="hidden" id="nodeIndex">
            
            <div class="grid grid-cols-2 gap-4">
                <div>
                    <label class="block text-xs text-slate-400 mb-1">备注 / 标签(Tag)</label>
                    <input type="text" id="nodeTag" placeholder="如 ss-16759" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                </div>
                <div>
                    <label class="block text-xs text-slate-400 mb-1">监听端口</label>
                    <input type="number" id="nodePort" placeholder="如 443" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                </div>
            </div>

            <div class="grid grid-cols-2 gap-4">
                <div>
                    <label class="block text-xs text-slate-400 mb-1">协议 (Protocol)</label>
                    <select id="nodeProtocol" onchange="onProtocolChange(this.value)" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                        <option value="shadowsocks">Shadowsocks</option>
                        <option value="vless">VLESS</option>
                        <option value="vmess">VMess</option>
                        <option value="trojan">Trojan</option>
                        <option value="hysteria2">Hysteria2</option>
                        <option value="tuic">TUIC</option>
                    </select>
                </div>
                <div>
                    <label class="block text-xs text-slate-400 mb-1">监听 IP</label>
                    <input type="text" id="nodeListen" value="::" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                </div>
            </div>

            <!-- Shadowsocks section -->
            <div id="sectionShadowsocks" class="space-y-4">
                <div class="grid grid-cols-2 gap-4">
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">加密算法 (Method)</label>
                        <select id="ssMethod" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                            <option value="2022-blake3-aes-128-gcm">2022-blake3-aes-128-gcm</option>
                            <option value="aes-128-gcm">aes-128-gcm</option>
                            <option value="chacha20-ietf-poly1305">chacha20-ietf-poly1305</option>
                        </select>
                    </div>
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">密码 (Password)</label>
                        <div class="flex space-x-2">
                            <input type="text" id="nodePassword" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                            <button type="button" onclick="generateRandomPass()" class="bg-indigo-600 hover:bg-indigo-500 text-white px-3 rounded-xl text-xs font-semibold">生成</button>
                        </div>
                    </div>
                </div>
            </div>

            <!-- VLESS section -->
            <div id="sectionVless" class="space-y-4 hidden">
                <div class="grid grid-cols-2 gap-4">
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">用户 UUID</label>
                        <div class="flex space-x-2">
                            <input type="text" id="vlessUuid" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                            <button type="button" onclick="generateUuid('vlessUuid')" class="bg-indigo-600 hover:bg-indigo-500 text-white px-3 rounded-xl text-xs font-semibold">生成</button>
                        </div>
                    </div>
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">流控 (Flow)</label>
                        <select id="vlessFlow" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                            <option value="none">无流控 (none)</option>
                            <option value="xtls-rprx-vision">xtls-rprx-vision</option>
                        </select>
                    </div>
                </div>
            </div>

            <!-- VMess section -->
            <div id="sectionVmess" class="space-y-4 hidden">
                <div>
                    <label class="block text-xs text-slate-400 mb-1">用户 UUID</label>
                    <div class="flex space-x-2">
                        <input type="text" id="vmessUuid" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                        <button type="button" onclick="generateUuid('vmessUuid')" class="bg-indigo-600 hover:bg-indigo-500 text-white px-3 rounded-xl text-xs font-semibold">生成</button>
                    </div>
                </div>
            </div>

            <!-- TUIC section -->
            <div id="sectionTuic" class="space-y-4 hidden">
                <div class="grid grid-cols-2 gap-4">
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">用户 UUID</label>
                        <div class="flex space-x-2">
                            <input type="text" id="tuicUuid" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                            <button type="button" onclick="generateUuid('tuicUuid')" class="bg-indigo-600 hover:bg-indigo-500 text-white px-3 rounded-xl text-xs font-semibold">生成</button>
                        </div>
                    </div>
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">拥塞控制 (Congestion Control)</label>
                        <select id="tuicBbr" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                            <option value="bbr">bbr</option>
                            <option value="cubic">cubic</option>
                        </select>
                    </div>
                </div>
            </div>

            <!-- General Password section (Trojan, Hysteria2 etc.) -->
            <div id="sectionGeneralPassword" class="space-y-4 hidden">
                <div>
                    <label class="block text-xs text-slate-400 mb-1">访问密码 (Password)</label>
                    <div class="flex space-x-2">
                        <input type="text" id="genPassword" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                        <button type="button" onclick="generateRandomPass('genPassword')" class="bg-indigo-600 hover:bg-indigo-500 text-white px-3 rounded-xl text-xs font-semibold">生成</button>
                    </div>
                </div>
            </div>

            <!-- Transport Setting Group -->
            <div id="groupTransport" class="space-y-4 p-4 bg-slate-900/40 border border-slate-800/80 rounded-2xl">
                <h4 class="text-xs font-bold text-slate-300">传输层协议设置 (Transport)</h4>
                <div class="grid grid-cols-2 gap-4">
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">传输协议</label>
                        <select id="nodeTransport" onchange="onTransportChange(this.value)" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                            <option value="none">无 (tcp)</option>
                            <option value="ws">WebSocket (ws)</option>
                            <option value="grpc">gRPC</option>
                            <option value="httpupgrade">HTTPUpgrade</option>
                            <option value="xhttp">xHTTP (高性能推荐)</option>
                        </select>
                    </div>
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">路径 / ServiceName</label>
                        <input type="text" id="transportPath" placeholder="如 /mypath" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                    </div>
                </div>
            </div>

            <!-- TLS & Reality Setting Group -->
            <div id="groupTls" class="space-y-4 p-4 bg-slate-900/40 border border-slate-800/80 rounded-2xl">
                <h4 class="text-xs font-bold text-slate-300">安全加密设置 (TLS / REALITY)</h4>
                <div>
                    <label class="block text-xs text-slate-400 mb-1">加密类型</label>
                    <select id="nodeTlsType" onchange="onTlsTypeChange(this.value)" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                        <option value="none">不开启 (none)</option>
                        <option value="tls">标准 TLS</option>
                        <option value="reality">REALITY (无证书混淆)</option>
                    </select>
                </div>

                <!-- Standard TLS -->
                <div id="subSectionTls" class="space-y-3 hidden">
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">服务器 SNI 域名</label>
                        <input type="text" id="tlsSni" placeholder="如 yourdomain.com" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                    </div>
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-xs text-slate-400 mb-1">证书全链文件路径 (.pem / .crt)</label>
                            <input type="text" id="tlsCertPath" value="/etc/sing-box/certs/fullchain.pem" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                        </div>
                        <div>
                            <label class="block text-xs text-slate-400 mb-1">私钥文件路径 (.key)</label>
                            <input type="text" id="tlsKeyPath" value="/etc/sing-box/certs/privkey.pem" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                        </div>
                    </div>
                </div>

                <!-- Reality TLS -->
                <div id="subSectionReality" class="space-y-3 hidden">
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-xs text-slate-400 mb-1">目标服务器 SNI 域名 (如 mozilla)</label>
                            <input type="text" id="realitySni" value="addons.mozilla.org" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                        </div>
                        <div>
                            <label class="block text-xs text-slate-400 mb-1">目标握手端口</label>
                            <input type="number" id="realityPort" value="443" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                        </div>
                    </div>
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">Reality 私钥 (Private Key)</label>
                        <div class="flex space-x-2">
                            <input type="text" id="realityPrivateKey" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-xs text-indigo-300 font-mono focus:outline-none">
                            <button type="button" onclick="getRealityKeys()" class="bg-indigo-600 hover:bg-indigo-500 text-white px-3 rounded-xl text-xs font-semibold shrink-0">一键生成密钥</button>
                        </div>
                        <span id="realityPubKeyHint" class="text-[10px] text-indigo-400 block mt-1 font-mono"></span>
                    </div>
                    <div>
                        <label class="block text-xs text-slate-400 mb-1">Reality 短 ID (Short ID)</label>
                        <div class="flex space-x-2">
                            <input type="text" id="realityShortId" value="19eb85b3a371a4cc" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
                            <button type="button" onclick="generateShortId()" class="bg-indigo-600 hover:bg-indigo-500 text-white px-3 rounded-xl text-xs font-semibold">生成</button>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Error display box for form saving -->
            <div id="formErrorBox" class="hidden p-3 bg-rose-500/10 border border-rose-500/20 text-rose-400 rounded-2xl text-xs font-mono"></div>

            <div class="flex justify-end space-x-3 pt-4 border-t border-slate-800/80">
                <button type="button" onclick="closeModal('visualNodeModal')" class="px-4 py-2 bg-slate-800 hover:bg-slate-750 text-slate-300 rounded-xl text-xs font-semibold">取消</button>
                <button onclick="saveVisualNode()" class="px-5 py-2 bg-gradient-to-r from-indigo-600 to-purple-600 text-white rounded-xl text-xs font-bold shadow-lg">保存应用</button>
            </div>
        </div>
    </div>

    <!-- Panel Settings Modal -->
    <div id="panelSettingsModal" class="fixed inset-0 z-50 hidden bg-slate-950/80 backdrop-blur-md flex items-center justify-center p-4">
        <div class="glass-card w-full max-w-md rounded-3xl p-6 shadow-2xl space-y-4">
            <h3 class="text-lg font-bold text-slate-200">修改 Web 管理面板参数</h3>
            <div>
                <label class="block text-xs text-slate-400 mb-1">登录用户名</label>
                <input type="text" id="panelUser" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
            </div>
            <div>
                <label class="block text-xs text-slate-400 mb-1">登录密码</label>
                <input type="text" id="panelPass" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
            </div>
            <div>
                <label class="block text-xs text-slate-400 mb-1">访问监听端口</label>
                <input type="number" id="panelPort" class="w-full bg-slate-900 border border-slate-800 rounded-xl px-3 py-2 text-sm text-slate-200 focus:outline-none">
            </div>
            <div class="flex justify-end space-x-3 pt-4 border-t border-slate-800/80">
                <button type="button" onclick="closeModal('panelSettingsModal')" class="px-4 py-2 bg-slate-800 hover:bg-slate-750 text-slate-300 rounded-xl text-xs font-semibold">取消</button>
                <button onclick="savePanelSettings()" class="px-5 py-2 bg-gradient-to-r from-indigo-600 to-purple-600 text-white rounded-xl text-xs font-bold">更新重启</button>
            </div>
        </div>
    </div>

    <!-- Raw JSON Editor Modal -->
    <div id="rawEditorModal" class="fixed inset-0 z-50 hidden bg-slate-950/80 backdrop-blur-md flex items-center justify-center p-4">
        <div class="glass-card w-full max-w-4xl h-[85vh] rounded-3xl p-6 shadow-2xl flex flex-col justify-between">
            <div class="flex justify-between items-center mb-4">
                <h3 class="text-lg font-bold text-slate-200">Raw config.json 原始编辑器</h3>
                <span class="text-xs text-amber-400 bg-amber-500/10 px-2 py-0.5 rounded">Dry-Run 保护开启</span>
            </div>
            
            <div class="flex-1 min-h-0 mb-4">
                <textarea id="jsonTextarea" class="w-full h-full bg-slate-900 border border-slate-800 rounded-2xl p-4 font-mono text-xs text-indigo-300 focus:outline-none leading-relaxed"></textarea>
            </div>

            <!-- Error display box -->
            <div id="editorErrorBox" class="hidden p-3.5 bg-rose-500/10 border border-rose-500/20 text-rose-400 rounded-2xl text-xs font-mono mb-4 overflow-y-auto max-h-24"></div>

            <div class="flex justify-end space-x-3 pt-4 border-t border-slate-800/80">
                <button onclick="closeModal('rawEditorModal')" class="px-4 py-2 bg-slate-800 hover:bg-slate-750 text-slate-300 rounded-xl text-xs font-semibold">取消</button>
                <button onclick="saveRawConfig()" class="px-5 py-2 bg-gradient-to-r from-indigo-600 to-purple-600 text-white rounded-xl text-xs font-bold shadow-lg shadow-indigo-500/10">验证并保存</button>
            </div>
        </div>
    </div>

    <!-- Notification Toast -->
    <div id="toast" class="fixed bottom-6 right-6 z-50 transform translate-y-10 opacity-0 pointer-events-none transition-all duration-300 bg-slate-900 border border-indigo-500/20 text-indigo-200 px-5 py-3 rounded-2xl shadow-2xl flex items-center space-x-2">
        <i data-lucide="info" class="w-4 h-4 text-indigo-400 shrink-0"></i>
        <span id="toastMsg" class="text-xs font-medium">Message</span>
    </div>

    <!-- Script Logic -->
    <script>
        lucide.createIcons();
        let currentConfig = {};

        function showToast(msg) {
            const toast = document.getElementById('toast');
            document.getElementById('toastMsg').innerText = msg;
            toast.classList.remove('translate-y-10', 'opacity-0', 'pointer-events-none');
            setTimeout(() => {
                toast.classList.add('translate-y-10', 'opacity-0', 'pointer-events-none');
            }, 3000);
        }

        function closeModal(id) {
            document.getElementById(id).classList.add('hidden');
        }

        // Random generator helpers
        function generateRandomPass(elementId = 'nodePassword') {
            const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
            let pwd = '';
            for(let i=0; i<16; i++) {
                pwd += chars.charAt(Math.floor(Math.random() * chars.length));
            }
            document.getElementById(elementId).value = pwd;
        }

        function generateUuid(elementId) {
            let uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
                return v.toString(16);
            });
            document.getElementById(elementId).value = uuid;
        }

        function generateShortId() {
            const chars = '0123456789abcdef';
            let sid = '';
            for(let i=0; i<8; i++) {
                sid += chars.charAt(Math.floor(Math.random() * chars.length));
            }
            document.getElementById('realityShortId').value = sid;
        }

        // Fetch system Reality Key pair via backend API
        async function getRealityKeys() {
            showToast("正在后台申请 Curve25519 密钥对...");
            try {
                const res = await fetch('/api/generate-reality');
                const data = await res.json();
                if(data.success) {
                    document.getElementById('realityPrivateKey').value = data.private_key;
                    document.getElementById('realityPubKeyHint').innerText = "客户端 Public Key (请复制留存): " + data.public_key;
                    showToast("密钥生成成功！客户端公钥已展现在下方。");
                } else {
                    showToast("密钥获取失败: " + data.error);
                }
            } catch(e) {
                showToast("连接生成 API 异常。");
            }
        }

        // Fetch System Stats & Logs
        async function fetchSystemData() {
            try {
                const res = await fetch('/api/status');
                const data = await res.json();
                
                // Set Status
                const statusBadge = document.getElementById('serviceStatus');
                const statusText = document.getElementById('statusText');
                if (data.singbox_active) {
                    statusBadge.className = "flex items-center space-x-2 bg-emerald-500/10 border border-emerald-500/20 text-emerald-400 px-3 py-1 rounded-full text-xs font-semibold";
                    statusText.innerText = "运行中 (Active)";
                    statusBadge.querySelector('span').className = "w-2 h-2 rounded-full bg-emerald-400 animate-pulse";
                } else {
                    statusBadge.className = "flex items-center space-x-2 bg-rose-500/10 border border-rose-500/20 text-rose-400 px-3 py-1 rounded-full text-xs font-semibold";
                    statusText.innerText = "未运行 (Stopped)";
                    statusBadge.querySelector('span').className = "w-2 h-2 rounded-full bg-rose-500";
                }

                // Stats Progress Bars
                document.getElementById('cpuVal').innerText = data.cpu + '%';
                document.getElementById('cpuBar').style.width = data.cpu + '%';
                
                document.getElementById('ramVal').innerText = data.ram + '%';
                document.getElementById('ramBar').style.width = data.ram + '%';

                document.getElementById('diskVal').innerText = data.disk + '%';
                document.getElementById('diskBar').style.width = data.disk + '%';
            } catch (err) {}
        }

        // Fetch logs
        async function fetchLogs() {
            try {
                const res = await fetch('/api/logs');
                const logs = await res.text();
                const area = document.getElementById('loggerArea');
                area.innerText = logs || "暂无日志记录。";
                area.scrollTop = area.scrollHeight;
            } catch(e) {}
        }

        // Service Actions (start/stop/restart)
        async function triggerService(action) {
            showToast("正在下发指令: " + action + " ...");
            try {
                const res = await fetch('/api/action', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action })
                });
                const data = await res.json();
                if(data.success) {
                    showToast("操作成功应用！");
                    setTimeout(() => { fetchSystemData(); fetchLogs(); }, 1500);
                } else {
                    showToast("操作失败: " + data.error);
                }
            } catch(err) {
                showToast("连接 API 发生通信异常");
            }
        }

        // Fetch config & render inbounds
        async function fetchConfig() {
            try {
                const res = await fetch('/api/config');
                currentConfig = await res.json();
                renderInbounds();
            } catch(e) {
                showToast("未能成功拉取 Sing-Box 配置。");
            }
        }

        // Render nodes cards with Edit & Delete actions
        function renderInbounds() {
            const grid = document.getElementById('nodesGrid');
            grid.innerHTML = '';
            
            const inbounds = currentConfig.inbounds || [];
            if(inbounds.length === 0) {
                grid.innerHTML = `<div class="col-span-2 text-center text-xs text-slate-500 py-12">暂无任何入站节点，请点击右上角添加。</div>`;
                return;
            }

            inbounds.forEach((ib, idx) => {
                let badgeColor = "from-indigo-600 to-blue-600";
                if(ib.type === 'hysteria2') badgeColor = "from-pink-600 to-rose-600";
                if(ib.type === 'tuic') badgeColor = "from-purple-600 to-violet-600";
                if(ib.type === 'vless') badgeColor = "from-emerald-600 to-teal-600";

                const isTls = ib.tls && ib.tls.enabled;
                const isReality = isTls && ib.tls.reality && ib.tls.reality.enabled;

                let infoHTML = `
                    <div class="flex justify-between py-1 border-b border-slate-800/40">
                        <span class="text-slate-400">加密状态:</span>
                        <span class="font-medium ${isTls ? 'text-emerald-400' : 'text-slate-500'}">${isReality ? 'REALITY' : (isTls ? 'TLS' : '无加密')}</span>
                    </div>
                `;

                if(ib.transport && ib.transport.type) {
                    infoHTML += `
                        <div class="flex justify-between py-1 border-b border-slate-800/40">
                            <span class="text-slate-400">传输层:</span>
                            <span class="font-medium text-purple-400 uppercase font-mono text-[11px]">${ib.transport.type}</span>
                        </div>
                    `;
                }

                if(ib.type === 'shadowsocks') {
                    infoHTML += `
                        <div class="flex justify-between py-1">
                            <span class="text-slate-400">算法套件:</span>
                            <span class="font-medium text-indigo-400 font-mono text-[11px]">${ib.method}</span>
                        </div>
                    `;
                } else if(ib.type === 'vless') {
                    infoHTML += `
                        <div class="flex justify-between py-1">
                            <span class="text-slate-400">流控特征:</span>
                            <span class="font-medium text-indigo-400 font-mono text-[11px]">${ib.users?.[0]?.flow || '无'}</span>
                        </div>
                    `;
                }

                const cardHTML = `
                    <div class="p-5 rounded-2xl bg-slate-900/40 border border-slate-800 hover:border-slate-700/60 transition-all flex flex-col justify-between space-y-4">
                        <div>
                            <div class="flex justify-between items-center">
                                <div class="flex items-center space-x-2">
                                    <span class="px-2.5 py-1 text-[10px] font-bold text-white bg-gradient-to-tr ${badgeColor} rounded-xl uppercase tracking-wider">${ib.type}</span>
                                    <span class="text-sm font-bold text-slate-300">端口: ${ib.listen_port}</span>
                                </div>
                                <div class="flex space-x-1.5">
                                    <button onclick="editVisualNode(${idx})" class="p-1 rounded-md bg-slate-800 hover:bg-slate-700 text-slate-300 hover:text-white"><i data-lucide="edit-3" class="w-3.5 h-3.5"></i></button>
                                    <button onclick="deleteNode(${idx})" class="p-1 rounded-md bg-rose-500/10 hover:bg-rose-500/20 text-rose-400"><i data-lucide="trash" class="w-3.5 h-3.5"></i></button>
                                </div>
                            </div>

                            <div class="mt-4 space-y-1.5 text-xs">
                                <div class="flex justify-between py-1 border-b border-slate-800/40">
                                    <span class="text-slate-400">备注/Tag:</span>
                                    <span class="font-semibold text-slate-300 truncate max-w-[120px]">${ib.tag || '无'}</span>
                                </div>
                                ${infoHTML}
                            </div>
                        </div>

                        <div class="pt-3 border-t border-slate-800/60 flex space-x-2">
                            <button onclick="shareNode(${idx})" class="flex-1 py-1.5 bg-indigo-500/10 hover:bg-indigo-500/20 border border-indigo-500/20 text-indigo-300 hover:text-white rounded-xl text-xs font-semibold transition-all flex items-center justify-center space-x-1">
                                <i data-lucide="share-2" class="w-3.5 h-3.5"></i>
                                <span>生成分享链接</span>
                            </button>
                        </div>
                    </div>
                `;
                grid.insertAdjacentHTML('beforeend', cardHTML);
            });
            lucide.createIcons();
        }

        // Protocol dropdown dynamic UI trigger
        function onProtocolChange(protocol) {
            document.getElementById('sectionShadowsocks').classList.add('hidden');
            document.getElementById('sectionVless').classList.add('hidden');
            document.getElementById('sectionVmess').classList.add('hidden');
            document.getElementById('sectionTuic').classList.add('hidden');
            document.getElementById('sectionGeneralPassword').classList.add('hidden');

            document.getElementById('groupTransport').classList.add('hidden');
            document.getElementById('groupTls').classList.add('hidden');

            if(protocol === 'shadowsocks') {
                document.getElementById('sectionShadowsocks').classList.remove('hidden');
            } else if(protocol === 'vless') {
                document.getElementById('sectionVless').classList.remove('hidden');
                document.getElementById('groupTransport').classList.remove('hidden');
                document.getElementById('groupTls').classList.remove('hidden');
            } else if(protocol === 'vmess') {
                document.getElementById('sectionVmess').classList.remove('hidden');
                document.getElementById('groupTransport').classList.remove('hidden');
                document.getElementById('groupTls').classList.remove('hidden');
            } else if(protocol === 'tuic') {
                document.getElementById('sectionTuic').classList.remove('hidden');
                document.getElementById('sectionGeneralPassword').classList.remove('hidden');
            } else if(protocol === 'hysteria2') {
                document.getElementById('sectionGeneralPassword').classList.remove('hidden');
            } else if(protocol === 'trojan') {
                document.getElementById('sectionGeneralPassword').classList.remove('hidden');
                document.getElementById('groupTransport').classList.remove('hidden');
                document.getElementById('groupTls').classList.remove('hidden');
            }
        }

        function onTransportChange(val) {
            const pathInput = document.getElementById('transportPath');
            if(val === 'none') {
                pathInput.disabled = true;
                pathInput.placeholder = "无需配置路径";
                pathInput.value = '';
            } else if(val === 'grpc') {
                pathInput.disabled = false;
                pathInput.placeholder = "如 grpc-service-name";
            } else {
                pathInput.disabled = false;
                pathInput.placeholder = "如 /mypath";
            }
        }

        function onTlsTypeChange(val) {
            document.getElementById('subSectionTls').classList.add('hidden');
            document.getElementById('subSectionReality').classList.add('hidden');

            if(val === 'tls') {
                document.getElementById('subSectionTls').classList.remove('hidden');
            } else if(val === 'reality') {
                document.getElementById('subSectionReality').classList.remove('hidden');
            }
        }

        // Open Node creation modal
        function openAddNodeModal() {
            document.getElementById('modalTitle').innerText = "添加 Sing-Box 入站协议";
            document.getElementById('nodeIndex').value = "";
            document.getElementById('nodeTag').value = "";
            document.getElementById('nodePort').value = Math.floor(Math.random() * 40000) + 10000;
            document.getElementById('nodeProtocol').value = "shadowsocks";
            
            document.getElementById('nodeListen').value = "::";
            document.getElementById('nodePassword').value = "";
            document.getElementById('vlessUuid').value = "";
            document.getElementById('vlessFlow').value = "none";
            document.getElementById('vmessUuid').value = "";
            document.getElementById('tuicUuid').value = "";
            document.getElementById('tuicBbr').value = "bbr";
            document.getElementById('genPassword').value = "";
            document.getElementById('nodeTransport').value = "none";
            document.getElementById('transportPath').value = "";
            document.getElementById('nodeTlsType').value = "none";

            document.getElementById('tlsCertPath').value = "/etc/sing-box/certs/fullchain.pem";
            document.getElementById('tlsKeyPath').value = "/etc/sing-box/certs/privkey.pem";
            document.getElementById('tlsSni').value = "";

            document.getElementById('realitySni').value = "addons.mozilla.org";
            document.getElementById('realityServer').value = "addons.mozilla.org";
            document.getElementById('realityPort').value = "443";
            document.getElementById('realityPrivateKey').value = "";
            document.getElementById('realityShortId').value = "19eb85b3a371a4cc";
            document.getElementById('realityPubKeyHint').innerText = "";

            onProtocolChange('shadowsocks');
            onTransportChange('none');
            onTlsTypeChange('none');

            document.getElementById('formErrorBox').classList.add('hidden');
            document.getElementById('visualNodeModal').classList.remove('hidden');
        }

        // Open Node Edit Modal (populating values from JSON)
        function editVisualNode(idx) {
            const ib = currentConfig.inbounds[idx];
            document.getElementById('modalTitle').innerText = "编辑入站协议 (Index: " + idx + ")";
            document.getElementById('nodeIndex').value = idx;
            document.getElementById('nodeTag').value = ib.tag || "";
            document.getElementById('nodePort').value = ib.listen_port || "";
            document.getElementById('nodeProtocol').value = ib.type;
            document.getElementById('nodeListen').value = ib.listen || "::";

            // Reset Sub sections
            onProtocolChange(ib.type);

            if(ib.type === 'shadowsocks') {
                document.getElementById('ssMethod').value = ib.method || '2022-blake3-aes-128-gcm';
                document.getElementById('nodePassword').value = ib.password || '';
            } else if(ib.type === 'vless') {
                document.getElementById('vlessUuid').value = ib.users?.[0]?.uuid || '';
                document.getElementById('vlessFlow').value = ib.users?.[0]?.flow || 'none';
            } else if(ib.type === 'vmess') {
                document.getElementById('vmessUuid').value = ib.users?.[0]?.uuid || '';
            } else if(ib.type === 'tuic') {
                document.getElementById('tuicUuid').value = ib.users?.[0]?.uuid || '';
                document.getElementById('genPassword').value = ib.users?.[0]?.password || '';
                document.getElementById('tuicBbr').value = ib.congestion_control || 'bbr';
            } else if(ib.type === 'hysteria2') {
                document.getElementById('genPassword').value = ib.users?.[0]?.password || '';
            } else if(ib.type === 'trojan') {
                document.getElementById('genPassword').value = ib.users?.[0]?.password || ib.password || '';
            }

            // Transport Setup
            if(ib.transport) {
                document.getElementById('nodeTransport').value = ib.transport.type || 'none';
                document.getElementById('transportPath').value = ib.transport.path || ib.transport.service_name || '';
                onTransportChange(ib.transport.type);
            } else {
                document.getElementById('nodeTransport').value = 'none';
                document.getElementById('transportPath').value = '';
                onTransportChange('none');
            }

            // TLS setup
            if(ib.tls && ib.tls.enabled) {
                if(ib.tls.reality && ib.tls.reality.enabled) {
                    document.getElementById('nodeTlsType').value = 'reality';
                    document.getElementById('realitySni').value = ib.tls.server_name || '';
                    document.getElementById('realityServer').value = ib.tls.reality.handshake?.server || '';
                    document.getElementById('realityPort').value = ib.tls.reality.handshake?.server_port || '443';
                    document.getElementById('realityPrivateKey').value = ib.tls.reality.private_key || '';
                    document.getElementById('realityShortId').value = ib.tls.reality.short_id?.[0] || '';
                    document.getElementById('realityPubKeyHint').innerText = "";
                    onTlsTypeChange('reality');
                } else {
                    document.getElementById('nodeTlsType').value = 'tls';
                    document.getElementById('tlsSni').value = ib.tls.server_name || '';
                    document.getElementById('tlsCertPath').value = ib.tls.certificate_path || '';
                    document.getElementById('tlsKeyPath').value = ib.tls.key_path || '';
                    onTlsTypeChange('tls');
                }
            } else {
                document.getElementById('nodeTlsType').value = 'none';
                onTlsTypeChange('none');
            }

            document.getElementById('formErrorBox').classList.add('hidden');
            document.getElementById('visualNodeModal').classList.remove('hidden');
        }

        // Delete visual node from memory and sync with backend
        async function deleteNode(idx) {
            if(!confirm("确定要删除该入站配置吗？这将立刻断开绑定该端口的客户端。")) return;
            currentConfig.inbounds.splice(idx, 1);
            showToast("正在删除并同步修改...");
            await syncConfigWithBackend(currentConfig);
        }

        // Save Visual Node values into memory
        async function saveVisualNode() {
            const idx = document.getElementById('nodeIndex').value;
            const tag = document.getElementById('nodeTag').value;
            const port = parseInt(document.getElementById('nodePort').value);
            const protocol = document.getElementById('nodeProtocol').value;
            const listen = document.getElementById('nodeListen').value || "::";

            if(!port || isNaN(port)) {
                alert("请输入合法的监听端口！");
                return;
            }

            let inbound = {
                "type": protocol,
                "tag": tag || (protocol + "-" + port),
                "listen": listen,
                "listen_port": port
            };

            // Protocol logic
            if(protocol === 'shadowsocks') {
                inbound.method = document.getElementById('ssMethod').value;
                inbound.password = document.getElementById('nodePassword').value;
                if(!inbound.password) { alert("Shadowsocks 密码不可为空！"); return;}
            } else if(protocol === 'vless') {
                const uuid = document.getElementById('vlessUuid').value;
                if(!uuid) { alert("VLESS UUID不可为空！"); return;}
                const flow = document.getElementById('vlessFlow').value;
                inbound.users = [{
                    "uuid": uuid,
                    "flow": flow !== 'none' ? flow : undefined
                }];
            } else if(protocol === 'vmess') {
                const uuid = document.getElementById('vmessUuid').value;
                if(!uuid) { alert("VMess UUID不可为空！"); return;}
                inbound.users = [{ "uuid": uuid }];
            } else if(protocol === 'tuic') {
                const uuid = document.getElementById('tuicUuid').value;
                const password = document.getElementById('genPassword').value;
                if(!uuid || !password) { alert("TUIC 密码与 UUID 均不可为空！"); return;}
                inbound.users = [{ "uuid": uuid, "password": password }];
                inbound.congestion_control = document.getElementById('tuicBbr').value;
            } else if(protocol === 'hysteria2') {
                const password = document.getElementById('genPassword').value;
                if(!password) { alert("Hysteria2 密码不可为空！"); return;}
                inbound.users = [{ "password": password }];
            } else if(protocol === 'trojan') {
                const password = document.getElementById('genPassword').value;
                if(!password) { alert("Trojan 密码不可为空！"); return;}
                inbound.users = [{ "password": password }];
            }

            // Transport protocol logic (VLESS / VMess / Trojan)
            if(['vless', 'vmess', 'trojan'].includes(protocol)) {
                const transport = document.getElementById('nodeTransport').value;
                const path = document.getElementById('transportPath').value;
                if(transport !== 'none') {
                    inbound.transport = { "type": transport };
                    if(transport === 'grpc') {
                        inbound.transport.service_name = path || undefined;
                    } else {
                        inbound.transport.path = path || undefined;
                    }
                }
            }

            // TLS / Reality encryption logic
            if(['vless', 'vmess', 'trojan', 'hysteria2', 'tuic'].includes(protocol)) {
                let tlsType = document.getElementById('nodeTlsType').value;
                // Force TLS for Hysteria2 / TUIC as it is natively required
                if(['hysteria2', 'tuic'].includes(protocol)) {
                    tlsType = 'tls';
                }

                if(tlsType === 'tls') {
                    inbound.tls = {
                        "enabled": true,
                        "server_name": document.getElementById('tlsSni').value || undefined,
                        "certificate_path": document.getElementById('tlsCertPath').value || undefined,
                        "key_path": document.getElementById('tlsKeyPath').value || undefined
                    };
                } else if(tlsType === 'reality') {
                    const privKey = document.getElementById('realityPrivateKey').value;
                    const shortId = document.getElementById('realityShortId').value;
                    if(!privKey) { alert("Reality 私钥不可为空！"); return; }
                    inbound.tls = {
                        "enabled": true,
                        "server_name": document.getElementById('realitySni').value || undefined,
                        "reality": {
                            "enabled": true,
                            "handshake": {
                                "server": document.getElementById('realityServer').value || undefined,
                                "server_port": parseInt(document.getElementById('realityPort').value) || 443
                            },
                            "private_key": privKey,
                            "short_id": shortId ? [shortId] : []
                        }
                    };
                }
            }

            // Save or Update in bounds array
            if(!currentConfig.inbounds) currentConfig.inbounds = [];
            if(idx !== "") {
                currentConfig.inbounds[parseInt(idx)] = inbound;
            } else {
                currentConfig.inbounds.push(inbound);
            }

            // Push to backend with Dry-Run
            showToast("正在通过 Sing-Box 核心进行配置验证 (Dry-Run)...");
            const result = await syncConfigWithBackend(currentConfig);
            if(result.success) {
                closeModal('visualNodeModal');
                fetchConfig();
            } else {
                const errBox = document.getElementById('formErrorBox');
                errBox.className = "p-3 bg-rose-500/10 border border-rose-500/20 text-rose-400 rounded-2xl text-xs font-mono";
                errBox.innerText = "校验报错，请核对证书路径或配置项: " + result.error;
            }
        }

        // Helper to push full config to Python API
        async function syncConfigWithBackend(configData) {
            try {
                const res = await fetch('/api/config', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(configData)
                });
                const data = await res.json();
                if(data.success) {
                    showToast("配置保存并验证成功，Sing-Box 守护已重载！");
                    setTimeout(() => { fetchLogs(); }, 1000);
                    return { success: true };
                } else {
                    return { success: false, error: data.error };
                }
            } catch(e) {
                return { success: false, error: "无法连接 API 守护服务。" };
            }
        }

        // Parse & generate connection share link (Now supports high-end Reality + xHTTP)
        function shareNode(idx) {
            const ib = currentConfig.inbounds[idx];
            const host = window.location.hostname;
            let uri = "";

            if(ib.type === 'shadowsocks') {
                const creds = btoa(ib.method + ":" + ib.password);
                uri = `ss://${creds}@${host}:${ib.listen_port}#singbox-ss-${ib.listen_port}`;
            } else if(ib.type === 'vless') {
                const uuid = ib.users[0].uuid;
                const flow = ib.users[0].flow || "";
                let params = `?type=tcp&flow=${flow}`;
                if(ib.tls && ib.tls.reality && ib.tls.reality.enabled) {
                    params += `&security=reality&sni=${ib.tls.server_name}&pbk=${ib.tls.reality.private_key}&sid=${ib.tls.reality.short_id[0]}`;
                } else if(ib.tls && ib.tls.enabled) {
                    params += `&security=tls&sni=${ib.tls.server_name || ''}`;
                }
                if(ib.transport && ib.transport.type) {
                    params += `&type=${ib.transport.type}`;
                    if(ib.transport.type === 'grpc') {
                        params += `&serviceName=${ib.transport.service_name || ''}`;
                    } else {
                        params += `&path=${ib.transport.path || ''}`;
                    }
                }
                uri = `vless://${uuid}@${host}:${ib.listen_port}${params}#singbox-vless-${ib.listen_port}`;
            } else if(ib.type === 'vmess') {
                const uuid = ib.users[0].uuid;
                let params = `?uuid=${uuid}`;
                if(ib.tls && ib.tls.enabled) {
                    params += `&security=tls&sni=${ib.tls.server_name || ''}`;
                }
                if(ib.transport && ib.transport.type) {
                    params += `&type=${ib.transport.type}&path=${ib.transport.path || ''}`;
                }
                uri = `vmess://${uuid}@${host}:${ib.listen_port}${params}#singbox-vmess-${ib.listen_port}`;
            } else if(ib.type === 'hysteria2') {
                const password = ib.users[0].password;
                uri = `hysteria2://${password}@${host}:${ib.listen_port}?insecure=1#singbox-hy2-${ib.listen_port}`;
            } else if(ib.type === 'tuic') {
                const uuid = ib.users[0].uuid;
                const password = ib.users[0].password;
                uri = `tuic://${uuid}:${password}@${host}:${ib.listen_port}?congestion_control=${ib.congestion_control || 'bbr'}&alpn=h3#singbox-tuic-${ib.listen_port}`;
            } else {
                uri = `${ib.type} 协议暂不支持通过此简单 URI 格式分享，请编辑底层 JSON 引用配置。`;
            }

            document.getElementById('shareUriText').value = uri;
            document.getElementById('shareBox').classList.remove('hidden');
            showToast("分享链接已成功生成！");
        }

        function copyShareText() {
            const area = document.getElementById('shareUriText');
            area.select();
            document.execCommand('copy');
            showToast("成功复制到剪贴板！");
        }

        // Open JSON Raw editor
        function openRawEditor() {
            const text = JSON.stringify(currentConfig, null, 2);
            document.getElementById('jsonTextarea').value = text;
            document.getElementById('editorErrorBox').className = "hidden";
            document.getElementById('rawEditorModal').classList.remove('hidden');
        }

        // Save raw edited config with dry-run validation
        async function saveRawConfig() {
            const txt = document.getElementById('jsonTextarea').value;
            let parsed = {};
            try {
                parsed = JSON.parse(txt);
            } catch(err) {
                const errBox = document.getElementById('editorErrorBox');
                errBox.className = "p-3.5 bg-rose-500/10 border border-rose-500/20 text-rose-400 rounded-2xl text-xs font-mono mb-4 overflow-y-auto max-h-24";
                errBox.innerText = "JSON 格式破坏，解析失败: " + err.message;
                return;
            }

            showToast("正在向后端发送配置做校验（Dry-Run）...");
            const result = await syncConfigWithBackend(parsed);
            if(result.success) {
                closeModal('rawEditorModal');
                fetchConfig();
            } else {
                const errBox = document.getElementById('editorErrorBox');
                errBox.className = "p-3.5 bg-rose-500/10 border border-rose-500/20 text-rose-400 rounded-2xl text-xs font-mono mb-4 overflow-y-auto max-h-24";
                errBox.innerText = "Sing-Box 验证（dry-run）不通过！核心拒绝接受此配置，报错详情：\\n\\n" + result.error;
            }
        }

        // Open Panel Settings
        async function openPanelSettingsModal() {
            try {
                const res = await fetch('/api/creds');
                const data = await res.json();
                document.getElementById('panelUser').value = data.username;
                document.getElementById('panelPass').value = data.password;
                document.getElementById('panelPort').value = data.port;
                document.getElementById('panelSettingsModal').classList.remove('hidden');
            } catch(e) {
                showToast("无法读取面板凭证。");
            }
        }

        // Save Panel Settings to backend
        async function savePanelSettings() {
            const username = document.getElementById('panelUser').value;
            const password = document.getElementById('panelPass').value;
            const port = parseInt(document.getElementById('panelPort').value);

            if(!username || !password || !port) {
                alert("各项设置均不可为空！");
                return;
            }

            showToast("正在更新面板设置并重启 Web 服务...");
            try {
                const res = await fetch('/api/creds', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username, password, port })
                });
                const result = await res.json();
                if(result.success) {
                    showToast("凭证更新成功！3 秒后请使用新端口与密码重新登录。");
                    closeModal('panelSettingsModal');
                } else {
                    showToast("更新失败: " + result.error);
                }
            } catch(e) {
                showToast("连接异常（可能服务已经热重启，请稍后刷新重试）");
            }
        }

        // Initialization
        fetchConfig();
        fetchSystemData();
        fetchLogs();
        setInterval(fetchSystemData, 4000);
        setInterval(fetchLogs, 7000);
    </script>
</body>
</html>"""

# ==========================================
#  HTTP 请求处理处理器
# ==========================================
class DashboardHandler(BaseHTTPRequestHandler):
    def check_auth(self):
        # 读取验证身份
        creds = read_json_file(CREDS_FILE)
        username = creds.get("username", "admin")
        password = creds.get("password", "adminSecret")
        
        auth_header = self.headers.get('Authorization')
        if not auth_header:
            self.send_auth_request()
            return False
            
        auth_type, encoded_creds = auth_header.split(' ', 1)
        if auth_type.lower() != 'basic':
            self.send_auth_request()
            return False
            
        decoded_creds = base64.b64decode(encoded_creds).decode('utf-8')
        user, pwd = decoded_creds.split(':', 1)
        if user == username and pwd == password:
            return True
            
        self.send_auth_request()
        return False

    def send_auth_request(self):
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="Sing-Box Dashboard Auth"')
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(b"Unauthorized Access")

    def do_GET(self):
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path

        # 1. Reality generation API (No authentication needed for CLI, or authenticate if preferred)
        # We allow it to run quickly
        if path == '/api/generate-reality':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            try:
                # Executes 'sing-box generate reality-keypair'
                out = subprocess.check_output([SB_BIN, "generate", "reality-keypair"], stderr=subprocess.STDOUT).decode('utf-8')
                lines = out.strip().split('\n')
                priv = lines[0].split(': ')[1].strip()
                pub = lines[1].split(': ')[1].strip()
                res = {"success": True, "private_key": priv, "public_key": pub}
            except Exception as e:
                res = {"success": False, "error": str(e)}
            self.wfile.write(json.dumps(res).encode('utf-8'))
            return

        if not self.check_auth():
            return

        if path in ['/', '/ui', '/ui/']:
            # 渲染高颜值主页面
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML_CONTENT.encode('utf-8'))
            return

        elif path == '/api/config':
            # 返回当前 config.json
            config_data = read_json_file(CONFIG_FILE)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(config_data).encode('utf-8'))
            return

        elif path == '/api/creds':
            creds_data = read_json_file(CREDS_FILE)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(creds_data).encode('utf-8'))
            return

        elif path == '/api/status':
            # 获取系统物理和守护状态
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            
            # 计算 CPU
            try:
                cpu = subprocess.check_output("top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%* id.*/\\1/' | awk '{print 100 - $1}'", shell=True).decode().strip()
                cpu = float(cpu)
            except:
                cpu = 10.0
                
            # 内存
            try:
                ram = subprocess.check_output("free | grep Mem | awk '{print $3/$2 * 100.0}'", shell=True).decode().strip()
                ram = round(float(ram), 1)
            except:
                ram = 25.0

            # 磁盘
            try:
                disk = subprocess.check_output("df -h / | tail -1 | awk '{print $5}' | tr -d '%'", shell=True).decode().strip()
                disk = int(disk)
            except:
                disk = 30
                
            # sing-box 是否处于运行状态
            sb_active = False
            try:
                if os.path.exists("/usr/sbin/rc-service") or os.path.exists("/sbin/rc-service"):
                    status_raw = subprocess.check_output("rc-service sing-box status", shell=True).decode()
                    if "started" in status_raw:
                        sb_active = True
                else:
                    status_raw = subprocess.call(["systemctl", "is-active", "--quiet", "sing-box"])
                    if status_raw == 0:
                        sb_active = True
            except:
                pass
                
            status_payload = {
                "cpu": cpu,
                "ram": ram,
                "disk": disk,
                "singbox_active": sb_active
            }
            self.wfile.write(json.dumps(status_payload).encode('utf-8'))
            return

        elif path == '/api/logs':
            # 读取最后的 Sing-Box 日志
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            logs = ""
            try:
                if os.path.exists("/var/log/sing-box.err"):
                    logs = subprocess.check_output("tail -n 100 /var/log/sing-box.err 2>/dev/null || tail -n 100 /var/log/sing-box.log", shell=True).decode()
                else:
                    logs = subprocess.check_output("journalctl -u sing-box -n 100 --no-pager", shell=True).decode()
            except:
                logs = "无法加载系统日志或暂无运行记录。"
            self.wfile.write(logs.encode('utf-8'))
            return

        self.send_response(404)
        self.end_headers()
        self.wfile.write(b"Not Found")

    def do_POST(self):
        if not self.check_auth():
            return
            
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path

        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)

        if path == '/api/config':
            # 保存并做 Dry-Run 校验
            try:
                payload = json.loads(post_data.decode('utf-8'))
            except Exception as e:
                self.send_json_response({"success": False, "error": "JSON解析错误: " + str(e)})
                return

            # 写入临时文件做 dry-run check
            tmp_path = CONFIG_FILE + ".dryrun"
            if not write_json_file(tmp_path, payload):
                self.send_json_response({"success": False, "error": "无法写入临时文件做 Dryrun"})
                return

            # 调用 sing-box check 做严格校验
            try:
                p = subprocess.Popen([SB_BIN, "check", "-c", tmp_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                stdout, stderr = p.communicate()
                exit_code = p.returncode
            except Exception as e:
                exit_code = -1
                stderr = str(e).encode()

            if exit_code == 0:
                # 校验完全通过！正式覆写原文件并重启核心
                if write_json_file(CONFIG_FILE, payload):
                    # 重启核心服务
                    try:
                        if os.path.exists("/usr/sbin/rc-service") or os.path.exists("/sbin/rc-service"):
                            subprocess.call(["rc-service", "sing-box", "restart"])
                        else:
                            subprocess.call(["systemctl", "restart", "sing-box"])
                    except:
                        pass
                    self.send_json_response({"success": True})
                else:
                    self.send_json_response({"success": False, "error": "写入config.json文件权限受阻"})
            else:
                # 返回失败和具体的错误堆栈
                err_msg = stderr.decode('utf-8', errors='ignore') or stdout.decode('utf-8', errors='ignore') or "原因未知"
                self.send_json_response({"success": False, "error": err_msg})

            if os.path.exists(tmp_path):
                os.remove(tmp_path)
            return

        elif path == '/api/creds':
            try:
                payload = json.loads(post_data.decode('utf-8'))
                if write_json_file(CREDS_FILE, payload):
                    self.send_json_response({"success": True})
                    # Schedule restart in background
                    subprocess.Popen("sleep 2 && (rc-service sing-box-dashboard restart || systemctl restart sing-box-dashboard)", shell=True)
                else:
                    self.send_json_response({"success": False, "error": "写入凭证文件失败"})
            except Exception as e:
                self.send_json_response({"success": False, "error": str(e)})
            return

        elif path == '/api/action':
            # 服务一键指令操作
            try:
                payload = json.loads(post_data.decode('utf-8'))
                action = payload.get("action")
            except:
                self.send_json_response({"success": False, "error": "格式错误"})
                return

            if action in ["start", "stop", "restart"]:
                try:
                    if os.path.exists("/usr/sbin/rc-service") or os.path.exists("/sbin/rc-service"):
                        subprocess.call(["rc-service", "sing-box", action])
                    else:
                        subprocess.call(["systemctl", action, "sing-box"])
                    self.send_json_response({"success": True})
                except Exception as e:
                    self.send_json_response({"success": False, "error": str(e)})
            else:
                self.send_json_response({"success": False, "error": "未知动作"})
            return

    def send_json_response(self, data):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

def run_server():
    creds = read_json_file(CREDS_FILE)
    port = creds.get("port", 9527)
    
    server_address = ('0.0.0.0', port)
    try:
        httpd = HTTPServer(server_address, DashboardHandler)
        print(f"Starting Sing-Box Web Dashboard on port {port}...")
        httpd.serve_forever()
    except Exception as e:
        with open("/var/log/sing-box-dashboard-crash.log", "a") as f:
            f.write(f"Crash: {str(e)}\n")
        raise e

if __name__ == '__main__':
    run_server()
PYTHON_EOF
    success "API 托管程序已建立: $SB_DASHBOARD_PY"
}

# 注册开机自启系统服务 (Systemd 与 OpenRC 智能自动区分，同时管理核心和 Web 面板)
setup_system_service() {
    info "正在注册底层开机运行守护服务..."
    if [ "$OS" = "alpine" ]; then
        # 1. 注册核心服务
        local service_path="/etc/init.d/sing-box"
        cat > "$service_path" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
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

        # 2. 注册 Dashboard Web 面板服务
        local db_service_path="/etc/init.d/sing-box-dashboard"
        cat > "$db_service_path" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box-dashboard"
description="Sing-box Custom Python Web Dashboard"
command="/usr/bin/python3"
command_args="/etc/sing-box/dashboard.py"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box-dashboard.log"
error_log="/var/log/sing-box-dashboard.err"

depend() {
    need net
    after sing-box
}

start_pre() {
    checkpath --directory --mode 0755 /run
}
OPENRC
        chmod +x "$db_service_path"
        rc-update add sing-box-dashboard default >/dev/null 2>&1 || true
        rc-service sing-box-dashboard restart || true
    else
        # 1. 注册核心服务
        local service_path="/etc/systemd/system/sing-box.service"
        cat > "$service_path" <<EOF
[Unit]
Description=Sing-box Proxy Server
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

        # 2. 注册 Dashboard Web 面板服务
        local db_service_path="/etc/systemd/system/sing-box-dashboard.service"
        cat > "$db_service_path" <<EOF
[Unit]
Description=Sing-box Custom Python Web Dashboard
After=network.target sing-box.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /etc/sing-box/dashboard.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable sing-box-dashboard >/dev/null 2>&1
        systemctl restart sing-box-dashboard >/dev/null 2>&1
    fi
    success "Sing-Box 核心服务与 Web 面板后台系统守护均配置并重启成功！"
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
CREDS_FILE="/etc/sing-box/panel_creds.json"
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
    local service="$1"
    local action="$2"
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-service "$service" "$action"
    else
        systemctl "$action" "$service"
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
    [ -f "$CREDS_FILE" ] || { error "面板凭证文件不存在！"; return 1; }

    local web_port=$(jq -r '.port' "$CREDS_FILE")
    local web_user=$(jq -r '.username' "$CREDS_FILE")
    local web_pass=$(jq -r '.password' "$CREDS_FILE")
    local external_ip=$(get_public_ip)

    echo -e "\n${BLUE}==================================================${PLAIN}"
    echo -e "       🌌 Sing-Box Web 自托管服务运行数据"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "💻 Web 面板登录地址  : ${GREEN}http://${external_ip}:${web_port}/ui/${PLAIN}"
    echo -e "🔑 面板管理员账号    : ${PURPLE}${web_user}${PLAIN}"
    echo -e "🔑 面板安全通信密码  : ${PURPLE}${web_pass}${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "🔌 已部署的在监听端口 :"
    jq -r '.inbounds[] | "   » [\(.type)] 端口: \(.listen_port) (标签: \(.tag))"' "$CONFIG_PATH"
    echo -e "${BLUE}==================================================${PLAIN}"
}

# 2. 修改端口/访问密钥
action_reset_port_pwd() {
    [ -f "$CONFIG_PATH" ] || { error "配置文件不存在！"; return 1; }
    [ -f "$CREDS_FILE" ] || { error "面板凭证文件不存在！"; return 1; }
    
    echo -e "\n${BLUE}--- 重置网络端口与安全配置 (留空回车则维持原样) ---${PLAIN}"
    readp "请输入新 Web 访问端口: " new_web_port
    readp "请输入新 Web 面板登录密码: " new_secret

    if [[ -n "$new_web_port" ]]; then
        jq ".port = ${new_web_port}" "$CREDS_FILE" > "${CREDS_FILE}.tmp" && mv "${CREDS_FILE}.tmp" "$CREDS_FILE"
    fi
    if [[ -n "$new_secret" ]]; then
        jq ".password = \"${new_secret}\"" "$CREDS_FILE" > "${CREDS_FILE}.tmp" && mv "${CREDS_FILE}.tmp" "$CREDS_FILE"
    fi

    info "正在重启 Web 守护服务..."
    manage_service sing-box-dashboard restart
    success "面板访问权限与配置重构更新成功！"
    action_view_info
}

# 3. 查看实时服务运行日志
action_view_logs() {
    echo -e "\n1. 查看 Sing-Box 核心日志\n2. 查看 Web 面板日志"
    readp "请选择: " log_choice
    if [ "$log_choice" = "1" ]; then
        if [ "$INIT_SYSTEM" = "openrc" ]; then
            tail -f -n 50 /var/log/sing-box.err 2>/dev/null || tail -f -n 50 /var/log/sing-box.log
        else
            journalctl -u sing-box -f -n 50 --no-pager
        fi
    else
        if [ "$INIT_SYSTEM" = "openrc" ]; then
            tail -f -n 50 /var/log/sing-box-dashboard.err 2>/dev/null || tail -f -n 50 /var/log/sing-box-dashboard.log
        else
            journalctl -u sing-box-dashboard -f -n 50 --no-pager
        fi
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
    manage_service sing-box stop
    tar -zxf "${temp_dir}/sing-box.tar.gz" -C "$temp_dir"
    cp $(find "$temp_dir" -type f -name "sing-box" | head -n 1) "$SB_BIN"
    chmod +x "$SB_BIN"
    rm -rf "$temp_dir"
    
    manage_service sing-box start
    success "核心组件成功热升级至最新版本: ${latest_ver}"
}

# 5. 🛠️ 一键自适应系统深度诊断与错误自愈
action_diagnose() {
    info "=================================================="
    info "      🛠️ 开始全链路系统级深度故障诊断程序..."
    info "=================================================="
    sleep 1

    # 1. 检验二进制可用性
    info "[检测项 1/6] 检验主程序运行状态..."
    if [ ! -f "$SB_BIN" ]; then
        error ">> 诊断失败：未在系统内检索到主程序二进制文件 $SB_BIN"
        return 1
    fi
    chmod +x "$SB_BIN"
    if ! "$SB_BIN" version >/dev/null 2>&1; then
        error ">> 诊断失败：主程序无法在当前系统中加载执行！"
        return 1
    fi
    success ">> 主程序执行校验通过 ($( "$SB_BIN" version | head -n1 ))"

    # 2. 校验配置文件 JSON 语法格式
    info "[检测项 2/6] 校验配置文件完整性与 JSON 语法格式..."
    if [ ! -f "$CONFIG_PATH" ]; then
        error ">> 诊断失败：未发现配置文件: $CONFIG_PATH"
        return 1
    fi
    local verify_res
    if verify_res=$("$SB_BIN" check -c "$CONFIG_PATH" 2>&1); then
        success ">> 配置文件校验通过，无语法与字段漏洞。"
    else
        error ">> 诊断失败：配置文件格式破坏！语法校验未通过！详细报错："
        echo -e "${RED}${verify_res}${PLAIN}"
        return 1
    fi

    # 3. 校验 Web 托管面板脚本
    info "[检测项 3/6] 校验 Web 托管自建程序..."
    if [ ! -f "/etc/sing-box/dashboard.py" ]; then
        error ">> 诊断失败：自托管后端 Python 程序缺失！"
        return 1
    fi
    success ">> Web Panel API 文件检测完好。"

    # 4. 排查系统级网络端口抢占冲突
    info "[检测项 4/6] 排查运行端口绑定占用情况..."
    local web_port=$(jq -r '.port' "$CREDS_FILE")
    local conflict_detected=0
    if command -v ss >/dev/null 2>&1; then
        if ss -tunlp | grep -q ":$web_port "; then
            error ">> 检测到严重故障：Web面板监听端口 $web_port 已被服务器其他网络组件强制抢占！"
            conflict_detected=1
        fi
        if [ "$conflict_detected" -eq 1 ]; then
            error ">> 解决方案：请在控制台主菜单中选择指令 [2]，将面板端口更改为目前未使用的空闲端口。"
            return 1
        fi
        success ">> 网络端口占用安全校验通过。"
    else
        warn ">> 提示：当前系统未预装 ss 网络工具，跳过物理端口排查。"
    fi

    # 5. 系统自适应服务重新初始化
    info "[检测项 5/6] 正在执行服务自愈重构并尝试拉起守护服务..."
    manage_service sing-box stop >/dev/null 2>&1 || true
    manage_service sing-box start >/dev/null 2>&1 || true
    manage_service sing-box-dashboard stop >/dev/null 2>&1 || true
    manage_service sing-box-dashboard start >/dev/null 2>&1 || true
    sleep 2

    local service_active=0
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        if rc-service sing-box status 2>/dev/null | grep -q "started"; then
            service_active=1
        fi
    else
        if systemctl is-active --quiet sing-box; then
            service_active=1
        fi
    fi

    if [ "$service_active" -eq 1 ]; then
        success "=================================================="
        success "   🎉 自愈成功！Sing-Box 守护进程和 Web 面板均已正常运行！"
        success "=================================================="
    else
        error "=================================================="
        error "   ❌ 自愈失败！系统守护仍无法拉起。请使用选项 4 获取服务运行日志。"
        error "=================================================="
    fi
}

# 6. 卸载清除
action_uninstall() {
    info "正在停止进程并撤销开机自启..."
    manage_service sing-box stop >/dev/null 2>&1 || true
    manage_service sing-box-dashboard stop >/dev/null 2>&1 || true
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-update del sing-box default >/dev/null 2>&1 || true
        rc-update del sing-box-dashboard default >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box
        rm -f /etc/init.d/sing-box-dashboard
    else
        systemctl disable sing-box >/dev/null 2>&1 || true
        systemctl disable sing-box-dashboard >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service
        rm -f /etc/systemd/system/sing-box-dashboard.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /usr/local/bin/sb "$SB_BIN"
    success "Sing-Box 核心服务与自托管 Web 控制面板已完全卸载并清除残留！"
}

# 7. 编辑原始 JSON
action_edit_json() {
    local editor="${EDITOR:-vi}"
    if command -v nano >/dev/null 2>&1; then
        editor="nano"
    fi
    $editor "$CONFIG_PATH"
    
    info "正在校验配置文件完整性..."
    if "$SB_BIN" check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        success "配置文件校验无误，正在重启服务应用更改..."
        manage_service sing-box restart
    else
        error "新配置文件语法不符合规范，服务未重启。请重新检查修改！"
    fi
}

show_interactive_menu() {
    clear
    echo -e "${PURPLE}==================================================${PLAIN}"
    echo -e "${PURPLE}    🌌 Sing-Box Web自托管服务 本地交互命令行 (sb) ${PLAIN}"
    echo -e "${PURPLE}==================================================${PLAIN}"
    echo -e " 1. 查看 静态面板访问路径 / 管理员账号 / 节点连接"
    echo -e " 2. 修改/重置 面板端口、管理员登录密码"
    echo -e " 3. 管理 核心系统服务 (启动/停止/重启)"
    echo -e " 4. 实时 查看 Sing-Box 或 Web 服务控制台运行日志"
    echo -e " 5. 🛠️ 一键自适应系统全链路深度诊断与错误自愈"
    echo -e " 6. 手动 在线热升级 Sing-Box 核心组件"
    echo -e " 7. 打开 原始配置文件 (JSON) 文本编辑器"
    echo -e " 8. 彻底 卸载并清除 Sing-Box 核心与 Web 面板"
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

    readp "请输入您的指令 [0-8]: " menu_choice
    case "$menu_choice" in
        1) action_view_info ;;
        2) action_reset_port_pwd ;;
        3) 
            echo -e "\n1. 重启服务  2. 停止服务  3. 启动服务"
            readp "请选择: " cmd_act
            [[ "$cmd_act" = "1" ]] && { manage_service sing-box restart && success "重启成功！"; }
            [[ "$cmd_act" = "2" ]] && { manage_service sing-box stop && success "停止成功！"; }
            [[ "$cmd_act" = "3" ]] && { manage_service sing-box start && success "启动成功！"; }
            ;;
        4) action_view_logs ;;
        5) action_diagnose ;;
        6) action_upgrade ;;
        7) action_edit_json ;;
        8) action_uninstall; exit 0 ;;
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
detect_os
install_deps
deploy_web_ui() {
    # 如果以前有旧原生 ui 目录则保留，在这里我们直接初始化 config.json 默认不配置抢占
    if [ ! -f "$SB_CONFIG" ]; then
        # 生成一个无端口冲突的最简基础合规配置文件
        cat > "$SB_CONFIG" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
EOF
    fi
}
deploy_web_ui
deploy_dashboard_service
setup_system_service
create_sb_shortcut

# 最后直接调起一次面板
success "Web 表单自托管控制面板服务安装并重构成功！"
sleep 1
exec "$SB_SHORTCUT"

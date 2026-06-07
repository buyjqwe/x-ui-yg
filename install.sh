#!/bin/bash

# ====================================================================
#  脚本名称: X-UI YG Premium 完美优化版 (纯净版)
#  系统支持: Debian, Ubuntu, CentOS, Alpine
#  适用架构: AMD64, ARM64
#  主要功能: X-UI 一键安装、多协议订阅、Argo隧道配置、WARP代理分流、系统底层优化
# ====================================================================

export LANG=en_US.UTF-8

# 颜色控制
sred='\033[5;31m'
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
bblue='\033[0;34m'
plain='\033[0m'

red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
blue() { echo -e "\033[36m\033[01m$1\033[0m"; }
white() { echo -e "\033[37m\033[01m$1\033[0m"; }
readp() { read -p "$(yellow "$1")" $2; }

# root权限检查
[[ $EUID -ne 0 ]] && yellow "请以 root 模式运行此脚本" && exit

stty erase $'\b' 2>/dev/null || stty erase '^H' 2>/dev/null

# 智能系统检测
if [[ -f /etc/redhat-release ]]; then
    release="Centos"
elif cat /etc/issue | grep -q -E -i "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -q -E -i "debian"; then
    release="Debian"
elif cat /etc/issue | grep -q -E -i "ubuntu"; then
    release="Ubuntu"
elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
    release="Centos"
elif cat /proc/version | grep -q -E -i "debian"; then
    release="Debian"
elif cat /proc/version | grep -q -E -i "ubuntu"; then
    release="Ubuntu"
elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
    release="Centos"
else 
    red "目前不支持您的系统，请选择使用 Ubuntu, Debian, Centos 或 Alpine 系统。" && exit
fi

vsid=$(grep -i version_id /etc/os-release | cut -d \" -f2 | cut -d . -f1)
op=$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep -i pretty_name | cut -d \" -f2)

if [[ $(echo "$op" | grep -i -E "arch") ]]; then
    red "脚本不支持当前的 $op 系统，请选择使用 Ubuntu, Debian, Centos 系统。" && exit
fi

version=$(uname -r | cut -d "-" -f1)
[[ -z $(systemd-detect-virt 2>/dev/null) ]] && vi=$(virt-what 2>/dev/null) || vi=$(systemd-detect-virt 2>/dev/null)

case $(uname -m) in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) red "目前脚本不支持 $(uname -m) 架构" && exit;;
esac

# 检测 BBR
if [[ -n $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk -F ' ' '{print $3}') ]]; then
    bbr=$(sysctl net.ipv4.tcp_congestion_control | awk -F ' ' '{print $3}')
elif [[ -n $(ping 10.0.0.2 -c 2 | grep ttl) ]]; then
    bbr="Openvz版bbr-plus"
else
    bbr="Openvz/Lxc"
fi

# 系统参数优化 (TCP/进程限制)
sys_optimize() {
    green "正在进行系统底层网络与文件描述符限制优化..."
    
    # 增加连接限制数量
    cat >> /etc/security/limits.conf <<EOF
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
EOF

    # 写入系统内核优化参数
    cat > /etc/sysctl.d/99-xui-optimize.conf <<EOF
fs.file-max = 65535
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
EOF
    sysctl --system >/dev/null 2>&1
    green "系统优化配置应用成功。"
}

# 依赖包安装
install_dependencies() {
    if [ ! -f xuiyg_update ]; then
        green "首次安装x-ui-yg脚本必要的系统依赖……"
        if [[ x"${release}" == x"alpine" ]]; then
            apk update
            apk add wget curl tar jq tzdata openssl expect git socat iproute2 coreutils util-linux dcron virt-what
        else
            if [[ $release = Centos && ${vsid} =~ 8 ]]; then
                cd /etc/yum.repos.d/ && mkdir backup && mv *repo backup/ 
                curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-8.repo
                sed -i -e "s|mirrors.cloud.aliyuncs.com|mirrors.aliyun.com|g " /etc/yum.repos.d/CentOS-*
                sed -i -e "s|releasever|releasever-stream|g" /etc/yum.repos.d/CentOS-*
                yum clean all && yum makecache
                cd
            fi

            if [ -x "$(command -v apt-get)" ]; then
                apt update -y
                apt install jq tzdata socat cron coreutils util-linux -y
            elif [ -x "$(command -v yum)" ]; then
                yum update -y && yum install epel-release -y
                yum install jq tzdata socat coreutils util-linux -y
            elif [ -x "$(command -v dnf)" ]; then
                dnf update -y
                dnf install jq tzdata socat coreutils util-linux -y
            fi
            
            if [ -x "$(command -v yum)" ] || [ -x "$(command -v dnf)" ]; then
                if ! command -v "cronie" &> /dev/null; then
                    if [ -x "$(command -v yum)" ]; then
                        yum install -y cronie
                    elif [ -x "$(command -v dnf)" ]; then
                        dnf install -y cronie
                    fi
                fi
            fi

            packages=("curl" "openssl" "tar" "expect" "xxd" "python3" "wget" "git")
            inspackages=("curl" "openssl" "tar" "expect" "xxd" "python3" "wget" "git")
            for i in "${!packages[@]}"; do
                package="${packages[$i]}"
                inspackage="${inspackages[$i]}"
                if ! command -v "$package" &> /dev/null; then
                    if [ -x "$(command -v apt-get)" ]; then
                        apt-get install -y "$inspackage"
                    elif [ -x "$(command -v yum)" ]; then
                        yum install -y "$inspackage"
                    elif [ -x "$(command -v dnf)" ]; then
                        dnf install -y "$inspackage"
                    fi
                fi
            done
        fi
        touch xuiyg_update
    fi
}

install_dependencies

if [[ $vi = openvz ]]; then
    TUN=$(cat /dev/net/tun 2>&1)
    if [[ ! $TUN =~ 'in bad state' ]] && [[ ! $TUN =~ '处于错误状态' ]] && [[ ! $TUN =~ 'Die Dateizugriffsnummer ist in schlechter Verfassung' ]]; then 
        red "检测到未开启TUN，现尝试添加TUN支持" && sleep 4
        cd /dev && mkdir net && mknod net/tun c 10 200 && chmod 0666 net/tun
        TUN=$(cat /dev/net/tun 2>&1)
        if [[ ! $TUN =~ 'in bad state' ]] && [[ ! $TUN =~ '处于错误状态' ]] && [[ ! $TUN =~ 'Die Dateizugriffsnummer ist in schlechter Verfassung' ]]; then 
            green "添加TUN支持失败，建议与VPS厂商沟通或后台设置开启" && exit
        else
            echo '#!/bin/bash' > /root/tun.sh && echo 'cd /dev && mkdir net && mknod net/tun c 10 200 && chmod 0666 net/tun' >> /root/tun.sh && chmod +x /root/tun.sh
            grep -qE "^ *@reboot root bash /root/tun.sh >/dev/null 2>&1" /etc/crontab || echo "@reboot root bash /root/tun.sh >/dev/null 2>&1" >> /etc/crontab
            green "TUN守护功能已启动"
        fi
    fi
fi

argopid(){
    ym=$(cat /usr/local/x-ui/xuiargoympid.log 2>/dev/null)
    ls=$(cat /usr/local/x-ui/xuiargopid.log 2>/dev/null)
}

v4v6(){
    v4=$(curl -s4m5 icanhazip.com || curl -s4m5 ip.sb || curl -s4m5 api64.ipify.org -k)
    v6=$(curl -s6m5 icanhazip.com || curl -s6m5 ip.sb -k)
    v4dq=$(curl -s4m5 -k https://myip.ipip.net | awk -F'来自于：' '{print $2}' 2>/dev/null)
    v6dq=$(curl -s6m5 -k https://ip.fm | sed -n 's/.*Location: //p' 2>/dev/null)
}

warpcheck(){
    wgcfv6=$(curl -s6m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    wgcfv4=$(curl -s4m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
}

v6(){
    warpcheck
    if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
        v4=$(curl -s4m5 icanhazip.com -k)
        if [ -z $v4 ]; then
            yellow "检测到纯 IPV6 VPS，添加 nat64"
            echo -e "nameserver 2a00:1098:2b::1\nnameserver 2a00:1098:2c::1" > /etc/resolv.conf
        fi
    fi
}

serinstall(){
    green "下载并安装x-ui相关组件……"
    cd /usr/local/
    curl -L -o /usr/local/x-ui-linux-${cpu}.tar.gz -# --retry 2 --insecure https://github.com/yonggekkk/x-ui-yg/releases/download/xui_yg/x-ui-linux-${cpu}.tar.gz
    tar zxvf x-ui-linux-${cpu}.tar.gz > /dev/null 2>&1
    rm x-ui-linux-${cpu}.tar.gz -f
    cd x-ui
    chmod +x x-ui bin/xray-linux-${cpu}
    cp -f x-ui.service /etc/systemd/system/ >/dev/null 2>&1
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable x-ui >/dev/null 2>&1
    systemctl start x-ui >/dev/null 2>&1
    cd
    rm /usr/bin/x-ui -f
    curl -L -o /usr/bin/x-ui -# --retry 2 --insecure https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/install.sh
    chmod +x /usr/bin/x-ui
    
    if [[ x"${release}" == x"alpine" ]]; then
        echo '#!/sbin/openrc-run
name="x-ui"
command="/usr/local/x-ui/x-ui"
directory="/usr/local/${name}"
pidfile="/var/run/${name}.pid"
command_background="yes"
depend() {
    need networking 
}' > /etc/init.d/x-ui
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui default
        rc-service x-ui start
    fi
    
    if [[ -f /usr/bin/x-ui && -f /usr/local/x-ui/bin/xray-linux-${cpu} ]]; then
        green "x-ui主控下载并安装成功。"
    else
        red "下载失败，请检测VPS网络是否正常，脚本退出"
        if [[ x"${release}" == x"alpine" ]]; then
            rc-service x-ui stop
            rc-update del x-ui default
            rm /etc/init.d/x-ui -f
        else
            systemctl stop x-ui
            systemctl disable x-ui
            rm /etc/systemd/system/x-ui.service -f
            systemctl daemon-reload
            systemctl reset-failed
        fi
        rm /usr/bin/x-ui -f
        rm /etc/x-ui-yg/ -rf
        rm /usr/local/x-ui/ -rf
        rm -rf xuiyg_update
        exit
    fi
}

userinstall(){
    # 安全随机名生成
    local rand_name=$(tr -dc 'a-z' < /dev/urandom 2>/dev/null | head -c 6)
    [[ -z "$rand_name" ]] && rand_name="yg$(shuf -i 1000-9999 -n 1)"
    
    readp "设置 x-ui 登录用户名（回车跳过为随机6位字符 ${rand_name}）：" username
    sleep 1
    if [[ -z ${username} ]]; then
        username="$rand_name"
    fi
    while true; do
        if [[ ${username} == *admin* ]]; then
            red "安全考虑，不支持包含有 admin 字样的用户名，请重新设置" 
            readp "设置 x-ui 登录用户名：" username
        else
            break
        fi
    done
    sleep 1
    green "x-ui登录用户名：${username}"
    echo
    
    local rand_pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 8)
    [[ -z "$rand_pass" ]] && rand_pass="pwd$(shuf -i 10000-99999 -n 1)"

    readp "设置 x-ui 登录密码（回车跳过为随机随机字符 ${rand_pass}）：" password
    sleep 1
    if [[ -z ${password} ]]; then
        password="$rand_pass"
    fi
    while true; do
        if [[ ${password} == *admin* ]]; then
            red "安全考虑，不支持包含有 admin 字样的密码，请重新设置" 
            readp "设置 x-ui 登录密码：" password
        else
            break
        fi
    done
    sleep 1
    green "x-ui登录密码：${password}"
    /usr/local/x-ui/x-ui setting -username ${username} -password ${password} >/dev/null 2>&1
}

portinstall(){
    echo
    readp "设置 x-ui 登录端口[1-65535]（回车跳过为随机端口）：" port
    sleep 1
    if [[ -z $port ]]; then
        port=$(shuf -i 20000-60000 -n 1)
        until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") && -z $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]] 
        do
            [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") || -n $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]] && yellow "\n端口被占用，请重新输入端口" && readp "自定义端口:" port
        done
    else
        until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") && -z $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]
        do
            [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") || -n $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]] && yellow "\n端口被占用，请重新输入端口" && readp "自定义端口:" port
        done
    fi
    sleep 1
    /usr/local/x-ui/x-ui setting -port $port >/dev/null 2>&1
    green "x-ui登录端口：${port}"
}

pathinstall(){
    echo
    local rand_path=$(tr -dc 'a-z' < /dev/urandom 2>/dev/null | head -c 4)
    [[ -z "$rand_path" ]] && rand_path="vps"
    readp "设置 x-ui 登录根路径（回车跳过为随机字符 /${rand_path}）：" path
    sleep 1
    if [[ -z $path ]]; then
        path="$rand_path"
    fi
    # 强制加上斜杠前缀
    path="/${path#/}"
    /usr/local/x-ui/x-ui setting -webBasePath ${path} >/dev/null 2>&1
    green "x-ui登录根路径：${path}"
}

showxuiip(){
    xuilogin(){
        v4v6
        if [[ -z $v4 ]]; then
            echo "[$v6]" > /usr/local/x-ui/xip
        elif [[ -n $v4 && -n $v6 ]]; then
            echo "$v4" > /usr/local/x-ui/xip
            echo "[$v6]" >> /usr/local/x-ui/xip
        else
            echo "$v4" > /usr/local/x-ui/xip
        fi
    }
    warpcheck
    if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
        xuilogin
    else
        systemctl stop wg-quick@wgcf >/dev/null 2>&1
        kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2
        xuilogin
        systemctl start wg-quick@wgcf >/dev/null 2>&1
        systemctl restart warp-go >/dev/null 2>&1
        systemctl enable warp-go >/dev/null 2>&1
        systemctl start warp-go >/dev/null 2>&1
    fi
}

resinstall(){
    echo "----------------------------------------------------------------------"
    restart
    curl -sL https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/version | awk -F "更新内容" '{print $1}' | head -n 1 > /usr/local/x-ui/v
    showxuiip
    sleep 2
    xuigo
    cronxui
    echo "----------------------------------------------------------------------"
    blue "x-ui-yg $(cat /usr/local/x-ui/v 2>/dev/null) 安装成功，自动进入 x-ui 显示管理菜单" && sleep 4
    echo
    show_menu
}

xuiinstall(){
    v6
    echo "----------------------------------------------------------------------"
    openyn
    echo "----------------------------------------------------------------------"
    sys_optimize     # 优化底层系统
    serinstall       # 下载主程序
    echo "----------------------------------------------------------------------"
    userinstall
    portinstall
    pathinstall
    mkdir -p /root/ygkkkcaz
    curl -Ls -o /root/ygkkkcaz/private.key https://github.com/yonggekkk/argosbx/releases/download/argosbx/private.key
    curl -Ls -o /root/ygkkkcaz/cert.crt https://github.com/yonggekkk/argosbx/releases/download/argosbx/cert.crt
    resinstall
}

update() {
    yellow "升级脚本有可能覆盖部分自定义设置，建议提前在控制页做好备份。"
    readp "确定升级，请按回车 (退出请按 Ctrl+C):" ins
    if [[ -z $ins ]]; then
        if [[ x"${release}" == x"alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        serinstall && sleep 2
        restart
        curl -sL https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/version | awk -F "更新内容" '{print $1}' | head -n 1 > /usr/local/x-ui/v
        green "x-ui 更新完成" && sleep 2 && x-ui
    else
        red "输入有误" && update
    fi
}

uninstall() {
    yellow "本次卸载将清除所有面板及节点数据！"
    readp "确定卸载，请按回车 (退出请按 Ctrl+C):" ins
    if [[ -z $ins ]]; then
        if [[ x"${release}" == x"alpine" ]]; then
            rc-service x-ui stop
            rc-update del x-ui default
            rm /etc/init.d/x-ui -f
        else
            systemctl stop x-ui
            systemctl disable x-ui
            rm /etc/systemd/system/x-ui.service -f
            systemctl daemon-reload
            systemctl reset-failed
        fi
        kill -15 $(cat /usr/local/x-ui/xuiargopid.log 2>/dev/null) >/dev/null 2>&1
        kill -15 $(cat /usr/local/x-ui/xuiargoympid.log 2>/dev/null) >/dev/null 2>&1
        kill -15 $(cat /usr/local/x-ui/xuiwpphid.log 2>/dev/null) >/dev/null 2>&1
        rm /usr/bin/x-ui -f
        rm /etc/x-ui-yg/ -rf
        rm /usr/local/x-ui/ -rf
        uncronxui
        rm -rf xuiyg_update ygkkkcaz
        echo
        green "x-ui 卸载成功。"
        echo
    else
        red "输入有误" && uninstall
    fi
}

reset_config() {
    /usr/local/x-ui/x-ui setting -reset
    sleep 1 
    portinstall
    pathinstall
}

stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-service x-ui stop
    else
        systemctl stop x-ui
    fi
    check_status
    if [[ $? == 1 ]]; then
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        sed -i '/goxui.sh/d' /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
        green "x-ui停止成功"
    else
        red "x-ui停止失败，请运行 x-ui log 查看日志并反馈" && exit
    fi
}

restart() {
    yellow "正在重启面板组件，请稍候……"
    if [[ x"${release}" == x"alpine" ]]; then
        rc-service x-ui restart
    else
        systemctl restart x-ui
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        sed -i '/goxui.sh/d' /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        echo "* * * * * /usr/local/x-ui/goxui.sh" >> /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
        green "x-ui 重启成功"
    else
        red "x-ui重启失败，请运行 x-ui log 查看日志" && exit
    fi
}

show_log() {
    if [[ x"${release}" == x"alpine" ]]; then
        yellow "暂不支持alpine查看系统级 journal 日志"
    else
        journalctl -u x-ui.service -e --no-pager -f
    fi
}

get_char(){
    SAVEDSTTY=`stty -g`
    stty -echo
    stty cbreak
    dd if=/dev/tty bs=1 count=1 2> /dev/null
    stty -raw
    stty echo
    stty $SAVEDSTTY
}

back(){
    white "------------------------------------------------------------------------------------"
    white " 返回主菜单，请按任意键；退出脚本请按 Ctrl+C"
    get_char && show_menu
}

acme() {
    bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/acme-yg/main/acme.sh)
    back
}

bbr() {
    bash <(curl -Ls https://raw.githubusercontent.com/teddysun/across/master/bbr.sh)
    back
}

cfwarp() {
    bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh)
    back
}

xuirestop(){
    echo
    readp "1. 停止 x-ui \n2. 重启 x-ui \n0. 返回主菜单\n请选择：" action
    if [[ $action == "1" ]]; then
        stop
    elif [[ $action == "2" ]]; then
        restart
    else
        show_menu
    fi
}

xuichange(){
    echo
    readp "1. 更改 x-ui 用户名与密码 \n2. 更改 x-ui 面板登录端口\n3. 更改 x-ui 面板根路径\n4. 重置出厂设置（保留账号密码，自定义端口和路径）\n0. 返回主菜单\n请选择：" action
    if [[ $action == "1" ]]; then
        userinstall && restart
    elif [[ $action == "2" ]]; then
        portinstall && restart
    elif [[ $action == "3" ]]; then
        pathinstall && restart
    elif [[ $action == "4" ]]; then
        reset_config && restart
    else
        show_menu
    fi
}

check_status() {
    if [[ x"${release}" == x"alpine" ]]; then
        if [[ ! -f /etc/init.d/x-ui ]]; then
            return 2
        fi
        temp=$(rc-service x-ui status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f /etc/systemd/system/x-ui.service ]]; then
            return 2
        fi
        temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(rc-status default | grep x-ui | awk '{print $1}')
        if [[ x"${temp}" == x"x-ui" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl is-enabled x-ui)
        if [[ x"${temp}" == x"enabled" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        yellow "x-ui 已经安装。如需重新安装，请先选择选项 [2] 卸载。" && sleep 3
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        yellow "检测到未安装 x-ui，请先执行选项 [1] 进行安装" && sleep 3
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "x-ui状态: $blue已运行$plain"
            show_enable_status
            ;;
        1)
            echo -e "x-ui状态: $yellow未运行$plain"
            show_enable_status
            ;;
        2)
            echo -e "x-ui状态: $red未安装$plain"
    esac
    show_xray_status
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "x-ui自启: $blue是$plain"
    else
        echo -e "x-ui自启: $red否$plain"
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "xray状态: $blue已启动$plain"
    else
        echo -e "xray状态: $red未启动$plain"
    fi
}

xuigo(){
    cat>/usr/local/x-ui/goxui.sh<<-\EOF
#!/bin/bash
xui=`ps -aux |grep "x-ui" |grep -v "grep" |wc -l`
xray=`ps -aux |grep "xray" |grep -v "grep" |wc -l`
if [ $xui = 0 ];then
    systemctl restart x-ui
fi
if [ $xray = 0 ];then
    systemctl restart x-ui
fi
EOF
    chmod +x /usr/local/x-ui/goxui.sh
}

cronxui(){
    uncronxui
    crontab -l 2>/dev/null > /tmp/crontab.tmp
    echo "* * * * * /usr/local/x-ui/goxui.sh" >> /tmp/crontab.tmp
    echo "0 2 * * * systemctl restart x-ui" >> /tmp/crontab.tmp
    crontab /tmp/crontab.tmp >/dev/null 2>&1
    rm /tmp/crontab.tmp
}

uncronxui(){
    get_crontab_out() {
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        sed -i '/goxui.sh/d' /tmp/crontab.tmp
        sed -i '/systemctl restart x-ui/d' /tmp/crontab.tmp
        sed -i '/xuiargoport.log/d' /tmp/crontab.tmp
        sed -i '/xuiargopid.log/d' /tmp/crontab.tmp
        sed -i '/xuiargoympid/d' /tmp/crontab.tmp
        sed -i '/xuiwpphid.log/d' /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
    }
    get_crontab_out
}

close(){
    systemctl stop firewalld.service >/dev/null 2>&1
    systemctl disable firewalld.service >/dev/null 2>&1
    setenforce 0 >/dev/null 2>&1
    ufw disable >/dev/null 2>&1
    iptables -P INPUT ACCEPT >/dev/null 2>&1
    iptables -P FORWARD ACCEPT >/dev/null 2>&1
    iptables -P OUTPUT ACCEPT >/dev/null 2>&1
    iptables -t mangle -F >/dev/null 2>&1
    iptables -F >/dev/null 2>&1
    iptables -X >/dev/null 2>&1
    netfilter-persistent save >/dev/null 2>&1
    if [[ -n $(apachectl -v 2>/dev/null) ]]; then
        systemctl stop httpd.service >/dev/null 2>&1
        systemctl disable httpd.service >/dev/null 2>&1
        service apache2 stop >/dev/null 2>&1
        systemctl disable apache2 >/dev/null 2>&1
    fi
    sleep 1
    green "防火墙已关闭，系统主要通信端口已完全开放。"
}

openyn(){
    echo
    readp "是否开放端口，关闭系统防火墙？\n1、是，强制开放端口并关闭防火墙(回车默认)\n2、否，跳过(请自行手动放行端口)\n请选择：" action
    if [[ -z $action ]] || [[ $action == "1" ]]; then
        close
    elif [[ $action == "2" ]]; then
        echo
    else
        red "输入错误,请重新选择" && openyn
    fi
}

changeserv(){
    echo
    readp "1：设置Argo临时、固定双重隧道\n2：设置vmess/vless节点订阅优选IP\n3：配置Gitlab跨平台托管订阅\n4：生成并获取Warp-Wireguard官方常规配置\n0：返回上层\n请选择【0-4】：" menu
    if [ "$menu" = "1" ];then
        xuiargo
    elif [ "$menu" = "2" ];then
        xuicfadd
    elif [ "$menu" = "3" ];then
        gitlabsub
    elif [ "$menu" = "4" ];then
        warpwg
    else 
        show_menu
    fi
}

warpwg(){
    warpcode(){
        reg(){
            keypair=$(openssl genpkey -algorithm X25519|openssl pkey -text -noout)
            private_key=$(echo "$keypair" | awk '/priv:/{flag=1; next} /pub:/{flag=0} flag' | tr -d '[:space:]' | xxd -r -p | base64)
            public_key=$(echo "$keypair" | awk '/pub:/{flag=1} flag' | tr -d '[:space:]' | xxd -r -p | base64)
            curl -X POST 'https://api.cloudflareclient.com/v0a2158/reg' -sL --tlsv1.3 \
            -H 'CF-Client-Version: a-7.21-0721' -H 'Content-Type: application/json' \
            -d \
            '{
            "key":"'${public_key}'",
            "tos":"'$(date +"%Y-%m-%dT%H:%M:%S.000Z")'"
            }' \
            | python3 -m json.tool | sed "/\"account_type\"/i\         \"private_key\": \"$private_key\","
        }
        reserved(){
            reserved_str=$(echo "$warp_info" | grep 'client_id' | cut -d\" -f4)
            reserved_hex=$(echo "$reserved_str" | base64 -d | xxd -p)
            reserved_dec=$(echo "$reserved_hex" | fold -w2 | while read HEX; do printf '%d ' "0x${HEX}"; done | awk '{print "["$1", "$2", "$3"]"}')
            echo -e "{\n    \"reserved_dec\": $reserved_dec,"
            echo -e "    \"reserved_hex\": \"0x$reserved_hex\","
            echo -e "    \"reserved_str\": \"$reserved_str\"\n}"
        }
        result() {
            echo "$warp_reserved" | grep -P "reserved" | sed "s/ //g" | sed 's/:"/: "/g' | sed 's/:\[/: \[/g' | sed 's/\([0-9]\+\),\([0-9]\+\),\([0-9]\+\)/\1, \2, \3/' | sed 's/^"/    "/g' | sed 's/"$/",/g'
            echo "$warp_info" | grep -P "(private_key|public_key|\"v4\": \"172.16.0.2\"|\"v6\": \"2)" | sed "s/ //g" | sed 's/:"/: "/g' | sed 's/^"/    "/g'
            echo "}"
        }
        warp_info=$(reg) 
        warp_reserved=$(reserved) 
        result
    }
    output=$(warpcode)
    if ! echo "$output" 2>/dev/null | grep -w "private_key" > /dev/null; then
        v6="2606:4700:110:8f20:f22e:2c8d:d8ee:fe7"
        pvk="SGU6hx3CJAWGMr6XYoChvnrKV61hxAw2S4VlgBAxzFs="
        res="[15,242,244]"
    else
        pvk=$(echo "$output" | sed -n 4p | awk '{print $2}' | tr -d ' "' | sed 's/.$//')
        v6=$(echo "$output" | sed -n 7p | awk '{print $2}' | tr -d ' "')
        res=$(echo "$output" | sed -n 1p | awk -F":" '{print $NF}' | tr -d ' ' | sed 's/.$//')
    fi
    green "成功生成 warp-wireguard 普通账号配置，请进入 x-ui 控制页进行替换："
    blue "Private_key私钥：$pvk"
    blue "IPV6地址：$v6"
    blue "reserved值：$res"
}

cloudflaredargo(){
    if [ ! -e /usr/local/x-ui/cloudflared ]; then
        case $(uname -m) in
            aarch64) cpu=arm64;;
            x86_64) cpu=amd64;;
        esac
        curl -L -o /usr/local/x-ui/cloudflared -# --retry 2 https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu
        chmod +x /usr/local/x-ui/cloudflared
    fi
}

xuiargo(){
    echo
    yellow "使用 Cloudflare Argo 隧道的三个条件："
    green "1. 节点传输协议必须为 WebSocket (WS)"
    green "2. 节点 TLS 必须处于关闭状态"
    green "3. 节点请求头需要留空"
    echo
    yellow "1：开启/重置 Argo 临时隧道"
    yellow "2：配置 Argo 固定域名隧道"
    yellow "0：返回上级"
    readp "请选择【0-2】：" menu
    if [ "$menu" = "1" ]; then
        cfargo
    elif [ "$menu" = "2" ]; then
        cfargoym
    else
        changeserv
    fi
}

cfargo(){
    echo
    yellow "1：重置Argo临时隧道域名"
    yellow "2：停止Argo临时隧道"
    yellow "0：返回上层"
    readp "请选择【0-2】：" menu
    if [ "$menu" = "1" ]; then
        readp "请输入Argo监听的WS节点端口：" port
        echo "$port" > /usr/local/x-ui/xuiargoport.log
        cloudflaredargo
        i=0
        while [ $i -le 4 ]; do let i++
            yellow "第$i次验证 Cloudflared Argo 隧道可用性，请稍等……"
            if [[ -n $(ps -e | grep cloudflared) ]]; then
                kill -15 $(cat /usr/local/x-ui/xuiargopid.log 2>/dev/null) >/dev/null 2>&1
            fi
            /usr/local/x-ui/cloudflared tunnel --url http://localhost:$port --edge-ip-version auto --no-autoupdate --protocol http2 > /usr/local/x-ui/argo.log 2>&1 &
            echo "$!" > /usr/local/x-ui/xuiargopid.log
            sleep 20
            if [[ -n $(curl -sL https://$(cat /usr/local/x-ui/argo.log 2>/dev/null | grep -a trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')/ -I | awk 'NR==1 && /404|400|503/') ]]; then
                argo=$(cat /usr/local/x-ui/argo.log 2>/dev/null | grep -a trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
                blue "Argo 临时域名申请成功：$argo" && sleep 2
                break
            fi
            if [ $i -eq 5 ]; then
                red "验证超时，请确保您输入的端口为面板中已开启的WS节点端口。"
            fi
        done
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        sed -i '/xuiargoport.log/d' /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        echo '@reboot sleep 10 && /bin/bash -c "/usr/local/x-ui/cloudflared tunnel --url http://localhost:$(cat /usr/local/x-ui/xuiargoport.log) --edge-ip-version auto --no-autoupdate --protocol http2 > /usr/local/x-ui/argo.log 2>&1 & pid=\$! && echo \$pid > /usr/local/x-ui/xuiargopid.log"' >> /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
    elif [ "$menu" = "2" ]; then
        kill -15 $(cat /usr/local/x-ui/xuiargopid.log 2>/dev/null) >/dev/null 2>&1
        rm -rf /usr/local/x-ui/argo.log /usr/local/x-ui/xuiargopid.log /usr/local/x-ui/xuiargoport.log
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        sed -i '/xuiargopid.log/d' /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
        green "已卸载Argo临时隧道"
    else
        xuiargo
    fi
}

cfargoym(){
    echo
    if [[ -f /usr/local/x-ui/xuiargotoken.log && -f /usr/local/x-ui/xuiargoym.log ]]; then
        green "当前Argo固定隧道域名：$(cat /usr/local/x-ui/xuiargoym.log 2>/dev/null)"
        green "当前Argo固定隧道Token：$(cat /usr/local/x-ui/xuiargotoken.log 2>/dev/null)"
    fi
    echo
    green "请确保 Cloudflare 官网中 Zero Trust -> Tunnels 已经设置完毕。"
    yellow "1：重置/设置Argo固定隧道"
    yellow "2：停止Argo固定隧道"
    yellow "0：返回上层"
    readp "请选择【0-2】：" menu
    if [ "$menu" = "1" ]; then
        readp "请输入Argo监听的WS节点端口：" port
        echo "$port" > /usr/local/x-ui/xuiargoymport.log
        cloudflaredargo
        readp "输入Argo固定隧道Token: " argotoken
        readp "输入Argo固定隧道域名: " argoym
        if [[ -n $(ps -e | grep cloudflared) ]]; then
            kill -15 $(cat /usr/local/x-ui/xuiargoympid.log 2>/dev/null) >/dev/null 2>&1
        fi
        echo
        if [[ -n "${argotoken}" && -n "${argoym}" ]]; then
            nohup setsid /usr/local/x-ui/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token ${argotoken} >/dev/null 2>&1 & echo "$!" > /usr/local/x-ui/xuiargoympid.log
            sleep 20
        fi
        echo ${argoym} > /usr/local/x-ui/xuiargoym.log
        echo ${argotoken} > /usr/local/x-ui/xuiargotoken.log
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        sed -i '/xuiargoympid/d' /tmp/crontab.tmp
        echo '@reboot sleep 10 && /bin/bash -c "nohup setsid /usr/local/x-ui/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $(cat /usr/local/x-ui/xuiargotoken.log 2>/dev/null) >/dev/null 2>&1 & pid=\$! && echo \$pid > /usr/local/x-ui/xuiargoympid.log"' >> /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
        argo=$(cat /usr/local/x-ui/xuiargoym.log 2>/dev/null)
        blue "Argo固定隧道配置完成。固定域名：$argo"
    elif [ "$menu" = "2" ]; then
        kill -15 $(cat /usr/local/x-ui/xuiargoympid.log 2>/dev/null) >/dev/null 2>&1
        rm -rf /usr/local/x-ui/xuiargoym.log /usr/local/x-ui/xuiargoymport.log /usr/local/x-ui/xuiargoympid.log /usr/local/x-ui/xuiargotoken.log
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        sed -i '/xuiargoympid/d' /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
        green "已成功移除 Argo 固定配置。"
    else
        xuiargo
    fi
}

xuicfadd(){
    [[ -s /usr/local/x-ui/bin/xuicdnip_ws.txt ]] && cdnwsname=$(cat /usr/local/x-ui/bin/xuicdnip_ws.txt 2>/dev/null)  || cdnwsname='域名或IP直连'
    [[ -s /usr/local/x-ui/bin/xuicdnip_argo.txt ]] && cdnargoname=$(cat /usr/local/x-ui/bin/xuicdnip_argo.txt 2>/dev/null)  || cdnargoname="www.visa.com.sg"
    echo
    green "推荐优选大厂节点以获得极佳延迟表现："
    blue "www.visa.com.sg"
    blue "www.wto.org"
    blue "www.web.com"
    echo
    yellow "1：设置所有主流 Vmess/Vless 节点订阅的客户端优选地址 【当前：$cdnwsname】"
    yellow "2：设置 Argo 专属节点客户端优选地址 【当前：$cdnargoname】"
    yellow "0：返回上层"
    readp "请选择【0-2】：" menu
    if [ "$menu" = "1" ]; then
        readp "输入自定义的优选IP/域名 (回车恢复直连)：" menu
        [[ -z "$menu" ]] && > /usr/local/x-ui/bin/xuicdnip_ws.txt || echo "$menu" > /usr/local/x-ui/bin/xuicdnip_ws.txt
        green "设置成功。可执行选项 7 生成更新。" && sleep 2 && show_menu
    elif [ "$menu" = "2" ]; then
        readp "输入 Argo 专用优选域名 (回车默认使用 www.visa.com.sg)：" menu
        [[ -z "$menu" ]] && > /usr/local/x-ui/bin/xuicdnip_argo.txt || echo "$menu" > /usr/local/x-ui/bin/xuicdnip_argo.txt
        green "设置成功。可执行选项 7 生成更新。" && sleep 2 && show_menu
    else
        changeserv
    fi
}

gitlabsub(){
    echo
    green "请确保您已经拥有 GitLab 项目及授权推送的私有访问 Token。"
    yellow "1：配置 Gitlab 订阅自动托管推送"
    yellow "0：返回上层"
    readp "请选择【0-1】：" menu
    if [ "$menu" = "1" ]; then
        chown -R root:root /usr/local/x-ui/bin /usr/local/x-ui
        cd /usr/local/x-ui/bin
        readp "输入您的GitLab账号邮箱: " email
        readp "输入生成的 GitLab Token: " token
        readp "输入您的 GitLab 用户名: " userid
        readp "输入托管的项目名称: " project
        echo
        readp "新建分支名称 (回车默认推送至 main 分支): " gitlabml
        echo
        sharesub_sbcl >/dev/null 2>&1
        if [[ -z "$gitlabml" ]]; then
            gitlab_ml=''
            git_sk=main
            rm -rf /usr/local/x-ui/bin/gitlab_ml_ml
        else
            gitlab_ml=":${gitlabml}"
            git_sk="${gitlabml}"
            echo "${gitlab_ml}" > /usr/local/x-ui/bin/gitlab_ml_ml
        fi
        echo "$token" > /usr/local/x-ui/bin/gitlabtoken.txt
        rm -rf /usr/local/x-ui/bin/.git
        git init >/dev/null 2>&1
        git add xui_singbox.json xui_clashmeta.yaml xui_ty.txt >/dev/null 2>&1
        git config --global user.email "${email}" >/dev/null 2>&1
        git config --global user.name "${userid}" >/dev/null 2>&1
        git commit -m "update_$(date +"%Y%m%d_%H%M%S")" >/dev/null 2>&1
        branches=$(git branch)
        if [[ $branches == *master* ]]; then
            git branch -m master main >/dev/null 2>&1
        fi
        git remote add origin https://${token}@gitlab.com/${userid}/${project}.git >/dev/null 2>&1
        if [[ $(ls -a | grep '^\.git$') ]]; then
            cat > /usr/local/x-ui/bin/gitpush.sh <<EOF
#!/usr/bin/expect
spawn bash -c "git push -f origin main${gitlab_ml}"
expect "Password for 'https://$(cat /usr/local/x-ui/bin/gitlabtoken.txt 2>/dev/null)@gitlab.com':"
send "$(cat /usr/local/x-ui/bin/gitlabtoken.txt 2>/dev/null)\r"
interact
EOF
            chmod +x gitpush.sh
            ./gitpush.sh "git push -f origin main${gitlab_ml}" cat /usr/local/x-ui/bin/gitlabtoken.txt >/dev/null 2>&1
            echo "https://gitlab.com/api/v4/projects/${userid}%2F${project}/repository/files/xui_singbox.json/raw?ref=${git_sk}&private_token=${token}" > /usr/local/x-ui/bin/sing_box_gitlab.txt
            echo "https://gitlab.com/api/v4/projects/${userid}%2F${project}/repository/files/xui_clashmeta.yaml/raw?ref=${git_sk}&private_token=${token}" > /usr/local/x-ui/bin/clash_meta_gitlab.txt
            echo "https://gitlab.com/api/v4/projects/${userid}%2F${project}/repository/files/xui_ty.txt/raw?ref=${git_sk}&private_token=${token}" > /usr/local/x-ui/bin/xui_ty_gitlab.txt
            sharesubshow
        else
            yellow "GitLab 配置初始化失败，请仔细核对您的参数配置。"
        fi
        cd
    else
        changeserv
    fi
}

sharesubshow(){
    green "当前 X-ui 各端订阅节点更新完毕，推送成功！"
    echo "------------------------------------------------------"
    green "Sing-Box 专属订阅地址："
    blue "$(cat /usr/local/x-ui/bin/sing_box_gitlab.txt 2>/dev/null)"
    echo "------------------------------------------------------"
    green "Clash-Meta (Mihomo) 专属 YAML 订阅地址："
    blue "$(cat /usr/local/x-ui/bin/clash_meta_gitlab.txt 2>/dev/null)"
    echo "------------------------------------------------------"
    green "聚合通用 Base64 传统订阅地址："
    blue "$(cat /usr/local/x-ui/bin/xui_ty_gitlab.txt 2>/dev/null)"
    echo "------------------------------------------------------"
}

sharesub(){
    sharesub_sbcl
    echo
    red "开始对 GitLab 远程订阅服务器进行同步更新..."
    echo
    cd /usr/local/x-ui/bin
    if [[ $(ls -a | grep '^\.git$') ]]; then
        if [ -f /usr/local/x-ui/bin/gitlab_ml_ml ]; then
            gitlab_ml=$(cat /usr/local/x-ui/bin/gitlab_ml_ml)
        fi
        git rm --cached xui_singbox.json xui_clashmeta.yaml xui_ty.txt >/dev/null 2>&1
        git commit -m "rm_old" >/dev/null 2>&1
        git add xui_singbox.json xui_clashmeta.yaml xui_ty.txt >/dev/null 2>&1
        git commit -m "add_new" >/dev/null 2>&1
        chmod +x gitpush.sh
        ./gitpush.sh "git push -f origin main${gitlab_ml}" cat /usr/local/x-ui/bin/gitlabtoken.txt >/dev/null 2>&1
        sharesubshow
    else
        yellow "未配置远程 GitLab 自动托管，当前仅在本地生成配置。"
    fi
    cd
    echo
    white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    red "🚀 本地聚合传统通用节点目录 (/usr/local/x-ui/bin/xui_ty.txt)："
    cat /usr/local/x-ui/bin/xui_ty.txt
    white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

sharesub_sbcl(){
    if [[ -s /usr/local/x-ui/bin/xuicdnip_argo.txt ]]; then
        cdnargo=$(cat /usr/local/x-ui/bin/xuicdnip_argo.txt 2>/dev/null)
    else
        cdnargo="www.visa.com.sg"
    fi
    green "正在构建跨平台订阅文件架构中，请稍后……"
    xip1=$(cat /usr/local/x-ui/xip 2>/dev/null | sed -n 1p)
    if [[ "$xip1" =~ : ]]; then
        dnsip='tls://[2001:4860:4860::8888]/dns-query'
    else
        dnsip='tls://8.8.8.8/dns-query'
    fi

    # 生成 Sing-Box 配置文件框架
    cat > /usr/local/x-ui/bin/xui_singbox.json <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "ui",
      "secret": "",
      "default_mode": "Rule"
    },
    "cache_file": {
      "enabled": true,
      "path": "cache.db",
      "store_fakeip": true
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "proxydns",
        "address": "$dnsip",
        "detour": "select"
      },
      {
        "tag": "localdns",
        "address": "h3://223.5.5.5/dns-query",
        "detour": "direct"
      },
      {
        "tag": "dns_fakeip",
        "address": "fakeip"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "localdns",
        "disable_cache": true
      },
      {
        "clash_mode": "Global",
        "server": "proxydns"
      },
      {
        "clash_mode": "Direct",
        "server": "localdns"
      }
    ],
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15",
      "inet6_range": "fc00::/18"
    },
    "final": "proxydns"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": [
        "172.19.0.1/30",
        "fd00::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "sniff": true,
      "sniff_override_destination": true
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct"
    },
    {
      "tag": "select",
      "type": "selector",
      "default": "auto",
      "outbounds": [
        "auto"
      ]
    },
    {
      "tag": "auto",
      "type": "urltest",
      "outbounds": [],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "1m",
      "tolerance": 50
    }
  ]
}
EOF

    # 生成 Clash-Meta 配置文件框架
    cat > /usr/local/x-ui/bin/xui_clashmeta.yaml <<EOF
port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
global-client-fingerprint: chrome
dns:
  enable: false
  listen: :53
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver: 
    - 223.5.5.5
  nameserver:
    - https://dns.alidns.com/dns-query

proxies:

#_0

proxy-groups:
- name: 负载均衡
  type: load-balance
  url: https://www.gstatic.com/generate_204
  interval: 300
  strategy: round-robin
  proxies: 

#_1

- name: 自动选择
  type: url-test
  url: https://www.gstatic.com/generate_204
  interval: 300
  tolerance: 50
  proxies:  

#_2         
    
- name: 🌍选择代理节点
  type: select
  proxies:
    - 负载均衡                                           
    - 自动选择
    - DIRECT

#_3

rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,🌍选择代理节点
EOF

    xui_sb_cl(){
        sed -i "/#_0/r /usr/local/x-ui/bin/cl${i}.log" /usr/local/x-ui/bin/xui_clashmeta.yaml
        sed -i "/#_1/ i\\    - $tag" /usr/local/x-ui/bin/xui_clashmeta.yaml
        sed -i "/#_2/ i\\    - $tag" /usr/local/x-ui/bin/xui_clashmeta.yaml
        sed -i "/#_3/ i\\    - $tag" /usr/local/x-ui/bin/xui_clashmeta.yaml
        sed -i "/\/\/_0/r /usr/local/x-ui/bin/sb${i}.log" /usr/local/x-ui/bin/xui_singbox.json
        sed -i "/\/\/_1/ i\\ \"$tag\"," /usr/local/x-ui/bin/xui_singbox.json
        sed -i "/\/\/_2/ i\\ \"$tag\"," /usr/local/x-ui/bin/xui_singbox.json
    }

    # 脚本内部将读取 xray 的 config.json 来生成订阅，如果不存在，则在上面默认创建过模板
    tag_count=$(jq '.inbounds | map(select(.protocol == "vless" or .protocol == "vmess" or .protocol == "trojan" or .protocol == "shadowsocks")) | length' /usr/local/x-ui/bin/config.json 2>/dev/null)
    [[ -z "$tag_count" ]] && tag_count=0
    
    for ((i=0; i<tag_count; i++))
    do
        jq -c ".inbounds | map(select(.protocol == \"vless\" or \"vmess\" or \"trojan\" or \"shadowsocks\"))[$i]" /usr/local/x-ui/bin/config.json > "/usr/local/x-ui/bin/$((i+1)).log"
    done
    rm -rf /usr/local/x-ui/bin/ty.txt
    xip1=$(cat /usr/local/x-ui/xip 2>/dev/null | sed -n 1p)
    ymip=$(cat /root/ygkkkca/ca.log 2>/dev/null)
    directory="/usr/local/x-ui/bin/"
    
    for i in $(seq 1 $tag_count); do
        file="${directory}${i}.log"
        if [ -f "$file" ]; then
            # VLESS XTLS Reality
            if grep -q "vless" "$file" && grep -q "reality" "$file" && grep -q "vision" "$file"; then
                finger=$(jq -r '.streamSettings.realitySettings.fingerprint' "$file")
                vl_name=$(jq -r '.streamSettings.realitySettings.serverNames[0]' "$file")
                public_key=$(jq -r '.streamSettings.realitySettings.publicKey' "$file")
                short_id=$(jq -r '.streamSettings.realitySettings.shortIds[0]' "$file")
                uuid=$(jq -r '.settings.clients[0].id' "$file")
                vl_port=$(jq -r '.port' "$file")
                tag=$vl_port-vless-reality-vision
                
                cat > /usr/local/x-ui/bin/sb${i}.log <<EOF
 {
      "type": "vless",
      "tag": "$tag",
      "server": "$xip1",
      "server_port": $vl_port,
      "uuid": "$uuid",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$vl_name",
        "utls": {
          "enabled": true,
          "fingerprint": "$finger"
        },
      "reality": {
          "enabled": true,
          "public_key": "$public_key",
          "short_id": "$short_id"
        }
      }
    },
EOF
                cat > /usr/local/x-ui/bin/cl${i}.log <<EOF
- name: $tag                
  type: vless
  server: $xip1                            
  port: $vl_port                                        
  uuid: $uuid   
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: $vl_name                 
  reality-opts: 
    public-key: $public_key    
    short-id: $short_id                      
  client-fingerprint: $finger   
EOF
                echo "vless://$uuid@$xip1:$vl_port?type=tcp&security=reality&sni=$vl_name&pbk=$public_key&flow=xtls-rprx-vision&sid=$short_id&fp=$finger#$tag" >>/usr/local/x-ui/bin/ty.txt
                xui_sb_cl

            # Vmess WS 节点生成
            elif grep -q "vmess" "$file" && grep -q "ws" "$file"; then
                ws_path=$(jq -r '.streamSettings.wsSettings.path' "$file")
                vm_port=$(jq -r '.port' "$file")
                tls=$(jq -r '.streamSettings.security' "$file")
                [[ $tls == 'tls' ]] && tls=true || tls=false
                uuid=$(jq -r '.settings.clients[0].id' "$file")
                vm_name=$(jq -r '.streamSettings.wsSettings.headers.Host' "$file")
                tag=$vm_port-vmess-ws
                
                cat > /usr/local/x-ui/bin/sb${i}.log <<EOF
 {
      "type": "vmess",
      "tag": "$tag",
      "server": "$xip1",
      "server_port": $vm_port,
      "uuid": "$uuid",
      "security": "auto",
      "transport": {
        "type": "ws",
        "path": "$ws_path",
        "headers": {
          "Host": "$vm_name"
        }
      }
 },
EOF
                cat > /usr/local/x-ui/bin/cl${i}.log <<EOF
- name: $tag
  type: vmess
  server: $xip1
  port: $vm_port
  uuid: $uuid
  alterId: 0
  cipher: auto
  network: ws
  ws-opts:
    path: "$ws_path"
    headers:
      Host: "$vm_name"
EOF
                echo -e "vmess://$(echo '{"add":"'$xip1'","aid":"0","host":"'$vm_name'","id":"'$uuid'","net":"ws","path":"'$ws_path'","port":"'$vm_port'","ps":"'$tag'","tls":"'$tls'","type":"none","v":"2"}' | base64 -w 0)" >>/usr/local/x-ui/bin/ty.txt
                xui_sb_cl
            fi
        fi
    done
    
    # 结尾文件规整
    line=$(grep -B1 "//_1" /usr/local/x-ui/bin/xui_singbox.json | grep -v "//_1")
    new_line=$(echo "$line" | sed 's/,//g')
    sed -i "/^$line$/s/.*/$new_line/g" /usr/local/x-ui/bin/xui_singbox.json
    sed -i '/\/\/_0\|\/\/_1\|\/\/_2/d' /usr/local/x-ui/bin/xui_singbox.json
    sed -i '/#_0\|#_1\|#_2\|#_3/d' /usr/local/x-ui/bin/xui_clashmeta.yaml
    find /usr/local/x-ui/bin -type f -name "*.log" -delete
    v2sub=$(cat /usr/local/x-ui/bin/ty.txt 2>/dev/null)
    echo "$v2sub" > /usr/local/x-ui/bin/xui_ty.txt
}

insxuiwpph(){
    ins(){
        if [ ! -e /usr/local/x-ui/xuiwpph ]; then
            case $(uname -m) in
                aarch64) cpu=arm64;;
                x86_64) cpu=amd64;;
            esac
            curl -L -o /usr/local/x-ui/xuiwpph -# --retry 2 --insecure https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/xuiwpph_$cpu
            chmod +x /usr/local/x-ui/xuiwpph
        fi
        if [[ -n $(ps -e | grep xuiwpph) ]]; then
            kill -15 $(cat /usr/local/x-ui/xuiwpphid.log 2>/dev/null) >/dev/null 2>&1
        fi
        v4v6
        if [[ -n $v4 ]]; then
            sw46=4
        else
            red "IPV4不存在，确保安装过WARP-IPV4模式"
            sw46=6
        fi
        echo
        readp "设置WARP-plus-Socks5端口（回车默认 40000）：" port
        if [[ -z $port ]]; then
            port=40000
        fi
    }
    unins(){
        kill -15 $(cat /usr/local/x-ui/xuiwpphid.log 2>/dev/null) >/dev/null 2>&1
        rm -rf /usr/local/x-ui/xuiwpph.log /usr/local/x-ui/xuiwpphid.log
        crontab -l 2>/dev/null > /tmp/crontab.tmp
        sed -i '/xuiwpphid.log/d' /tmp/crontab.tmp
        crontab /tmp/crontab.tmp >/dev/null 2>&1
        rm /tmp/crontab.tmp
    }
    echo
    yellow "1：启动/重置 WARP-plus-Socks5 本地原生 Warp 代理模式"
    yellow "2：启动/重置 WARP-plus-Socks5 Psiphon-VPN 跨国分流模式"
    yellow "3：停止并注销 WARP-plus-Socks5 代理"
    yellow "0：返回上层"
    readp "请选择【0-3】：" menu
    if [ "$menu" = "1" ]; then
        ins
        nohup setsid /usr/local/x-ui/xuiwpph -b 127.0.0.1:$port -$sw46 --endpoint 162.159.192.1:2408 >/dev/null 2>&1 & echo "$!" > /usr/local/x-ui/xuiwpphid.log
        green "正在向 Cloudflare 申请专属 Warp IP 分配中，请稍后..." && sleep 20
        resv1=$(curl -s --socks5 localhost:$port icanhazip.com)
        if [[ -z $resv1 ]]; then
            red "IP获取失败，请重试。" && unins && exit
        else
            echo "/usr/local/x-ui/xuiwpph -b 127.0.0.1:$port -$sw46 --endpoint 162.159.192.1:2408 >/dev/null 2>&1" > /usr/local/x-ui/xuiwpph.log
            crontab -l 2>/dev/null > /tmp/crontab.tmp
            sed -i '/xuiwpphid.log/d' /tmp/crontab.tmp
            echo '@reboot sleep 10 && /bin/bash -c "nohup setsid $(cat /usr/local/x-ui/xuiwpph.log 2>/dev/null) & pid=\$! && echo \$pid > /usr/local/x-ui/xuiwpphid.log"' >> /tmp/crontab.tmp
            crontab /tmp/crontab.tmp >/dev/null 2>&1
            rm /tmp/crontab.tmp
            green "Warp-Socks5 代理部署成功。本地端口：$port"
        fi
    elif [ "$menu" = "3" ]; then
        unins && green "已成功停止 Warp SOCKS5 守护进程。"
    else
        show_menu
    fi
}

sbsm(){
    echo
    green "欢迎加入和关注项目了解最新协议升级："
    blue "项目开源：https://github.com/yonggekkk/x-ui-yg"
    echo
}

show_menu(){
    clear
    white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"           
    echo -e "${bblue} ░██     ░██      ░██ ██ ██         ░█${plain}█   ░██     ░██   ░██     ░█${red}█   ░██${plain}  "
    echo -e "${bblue}  ░██   ░██      ░██    ░░██${plain}         ░██  ░██      ░██  ░██${red}      ░██  ░██${plain}   "
    echo -e "${bblue}   ░██ ░██      ░██ ${plain}                ░██ ██        ░██ █${red}█        ░██ ██  ${plain}   "
    echo -e "${bblue}     ░██        ░${plain}██    ░██ ██       ░██ ██        ░█${red}█ ██        ░██ ██  ${plain}  "
    echo -e "${bblue}     ░██ ${plain}        ░██    ░░██        ░██ ░██        ░${red}██ ░██        ░██ ░██ ${plain}  "
    echo -e "${bblue}     ░█${plain}█          ░██ ██ ██         ░██  ░░${red}██     ░██  ░░██     ░██  ░░██ ${plain}  "
    white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
    white " 甬哥一键管理：github.com/yonggekkk | Premium 深度重构优化版"
    white " 面板快捷管理命令：x-ui"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
    green " 1. 一键安装 x-ui 面板 (出厂自配 Reality/VMess 安全节点模板)"
    green " 2. 彻底卸载 x-ui 面板"
    echo "----------------------------------------------------------------------------------"
    green " 3. 高级传输设置 【Argo双隧道、CDN优选IP分流、Gitlab自动订阅】"
    green " 4. 修改 x-ui 管理面板设置 【用户名、登录密码、端口及路径】"
    green " 5. 重启 / 停止 x-ui 组件"
    green " 6. 在线升级 x-ui 脚本"
    echo "----------------------------------------------------------------------------------"
    green " 7. 更新并输出聚合通用、Clash-Meta 与 Sing-Box 客户端节点配置与订阅"
    green " 8. 查看 xray 运行日志"
    green " 9. 一键配置系统原生原版 BBR+FQ 拥塞控制网络加速"
    green " 10. 管理 Acme SSL 安全域名证书自动申请"
    green " 11. 调用 Warp 一键解锁流媒体限制检测"
    green " 12. 开启 WARP-plus-Socks5 本地出站代理"
    green " 13. 手动刷新 VPS 全球 IP 属性显示"
    echo "----------------------------------------------------------------------------------"
    green " 14. 脚本使用说明书"
    green " 0. 退出脚本"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
    
    insV=$(cat /usr/local/x-ui/v 2>/dev/null)
    latestV=$(curl -sL https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/version | awk -F "更新内容" '{print $1}' | head -n 1)
    if [[ -f /usr/local/x-ui/v ]]; then
        if [ "$insV" = "$latestV" ]; then
            echo -e "当前版本：${bblue}${insV}${plain} (已是最新)"
        else
            echo -e "当前版本：${bblue}${insV}${plain} | 最新版本：${yellow}${latestV}${plain} (请选择选项 6 升级)"
        fi
    else
        echo -e "面板状态：${red}未安装${plain}"
    fi
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
    echo -e "服务器环境信息："
    echo -e "系统: $blue$op$plain | 内核: $blue$version$plain | 架构: $blue$cpu$plain | BBR: $blue$bbr$plain"
    v4v6
    echo -e "公网IPv4: $blue$v4$plain | 公网IPv6: $blue$v6$plain | 物理位置: $blue$v4dq$plain"
    echo "------------------------------------------------------------------------------------"
    show_status
    echo "------------------------------------------------------------------------------------"
    acp=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null)
    if [[ -n $acp ]]; then
        xpath=$(echo $acp | awk '{print $8}')
        xport=$(echo $acp | awk '{print $6}')
        xip1=$(cat /usr/local/x-ui/xip 2>/dev/null | sed -n 1p)
        echo -e "面板登录地址（裸IP模式）: ${blue}http://${xip1}:${xport}${xpath}${plain}"
    fi
    echo "------------------------------------------------------------------------------------"
    readp "请输入您的选择 [0-14]: " Input
    case "$Input" in     
        1 ) check_uninstall && xuiinstall;;
        2 ) check_install && uninstall;;
        3 ) check_install && changeserv;;
        4 ) check_install && xuichange;;
        5 ) check_install && xuirestop;;
        6 ) check_install && update;;
        7 ) check_install && sharesub;;
        8 ) check_install && show_log;;
        9 ) bbr;;
        10 ) acme;;
        11 ) cfwarp;;
        12 ) check_install && insxuiwpph;;
        13 ) check_install && showxuiip && show_menu;;
        14 ) sbsm;;
        * ) exit 
    esac
}

show_menu

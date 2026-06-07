#!/bin/bash

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以 root 权限运行"
   exit 1
fi

SWAP_FILE="/swapfile"
SWAP_SIZE="1G"

# 1. 检查是否存在旧的 Swap 文件
if [ -f "$SWAP_FILE" ]; then
    echo "Swap 文件已存在，正在删除..."
    swapoff $SWAP_FILE
    rm $SWAP_FILE
fi

# 2. 创建 Swap 文件
echo "正在创建 1GB Swap 文件..."
fallocate -l $SWAP_SIZE $SWAP_FILE
chmod 600 $SWAP_FILE
mkswap $SWAP_FILE

# 3. 启用 Swap
echo "正在启用 Swap..."
swapon $SWAP_FILE

# 4. 写入 fstab 实现开机自启
if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    echo "已添加到 /etc/fstab"
fi

# 5. 优化 swappiness (可选，设置为 10，仅在内存压力大时才使用 Swap)
sysctl vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf

echo "Swap 创建完成，当前状态："
free -h

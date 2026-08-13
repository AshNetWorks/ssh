#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Debian 纯入口服务器网络优化
# 适用：
#   - nyanpass
#   - HAProxy
#   - Soga
#   - L4 TCP/UDP 入口
#   - 高并发代理入口
#
# 建议 Debian 11 / 12 / 13
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 运行此脚本"
    exit 1
fi

echo "================================================="
echo "        Entry Network Tuning V3"
echo "================================================="

SYSCTL_FILE="/etc/sysctl.conf"
LIMITS_FILE="/etc/security/limits.d/99-entry-nofile.conf"
SYSTEMD_LIMIT_DIR="/etc/systemd/system.conf.d"
SYSTEMD_LIMIT_FILE="${SYSTEMD_LIMIT_DIR}/99-entry-nofile.conf"
MODULE_FILE="/etc/modules-load.d/99-entry-tuning.conf"

DATE="$(date +%Y%m%d-%H%M%S)"

# ------------------------------------------------------------
# 获取内存
# ------------------------------------------------------------

MEM_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
MEM_MB=$((MEM_KB / 1024))

echo "检测到内存：${MEM_MB} MB"

# ------------------------------------------------------------
# 根据内存设置 conntrack
# ------------------------------------------------------------

if (( MEM_MB < 1024 )); then
    CONNTRACK_MAX=262144
elif (( MEM_MB < 2048 )); then
    CONNTRACK_MAX=524288
else
    CONNTRACK_MAX=1048576
fi

echo "nf_conntrack_max：${CONNTRACK_MAX}"

# ------------------------------------------------------------
# 备份
# ------------------------------------------------------------

backup_file() {
    local file="$1"

    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.${DATE}.bak"
        echo "已备份：${file}.${DATE}.bak"
    fi
}

backup_file "$SYSCTL_FILE"
backup_file "$LIMITS_FILE"
backup_file "$SYSTEMD_LIMIT_FILE"
backup_file "$MODULE_FILE"

# ------------------------------------------------------------
# 加载模块
# ------------------------------------------------------------

echo
echo "加载内核模块..."

modprobe sch_fq 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

# ------------------------------------------------------------
# 判断 BBR
# ------------------------------------------------------------

BBR_AVAILABLE=0

if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null \
    | grep -qw bbr; then

    BBR_AVAILABLE=1
    echo "BBR：可用"
else
    echo "警告：当前内核未检测到 BBR"
fi

# ------------------------------------------------------------
# 持久化模块
# ------------------------------------------------------------

: > "$MODULE_FILE"

if modinfo tcp_bbr >/dev/null 2>&1; then
    echo "tcp_bbr" >> "$MODULE_FILE"
fi

if modinfo nf_conntrack >/dev/null 2>&1; then
    echo "nf_conntrack" >> "$MODULE_FILE"
fi

# ------------------------------------------------------------
# 重写 /etc/sysctl.conf
# ------------------------------------------------------------

cat > "$SYSCTL_FILE" <<EOF
# ============================================================
# Entry Server Network Tuning
# ============================================================

# Memory / File
vm.swappiness = 10
fs.file-max = 2097152

# Network Queue
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

# TCP Buffer
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1

# TCP Basic
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0

# TCP Connection Queue
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 1048576

# TCP Connection Recycling
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 2

# KeepAlive（只有应用启用 SO_KEEPALIVE 时生效）
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# MTU：检测到 PMTU black hole 时启用 probing
net.ipv4.tcp_mtu_probing = 1

# Local Port
net.ipv4.ip_local_port_range = 1024 65535

# Routing
net.ipv4.ip_forward = 1

# Reverse Path：loose mode，适合多线路/非对称路由入口
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF

# ------------------------------------------------------------
# BBR
# ------------------------------------------------------------

if [[ "$BBR_AVAILABLE" -eq 1 ]]; then
cat >> "$SYSCTL_FILE" <<EOF

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
fi

# ------------------------------------------------------------
# conntrack
# ------------------------------------------------------------

if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
cat >> "$SYSCTL_FILE" <<EOF

# Conntrack
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
EOF
fi

# ------------------------------------------------------------
# 文件描述符限制
# ------------------------------------------------------------

cat > "$LIMITS_FILE" <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

# ------------------------------------------------------------
# systemd 默认文件描述符
# ------------------------------------------------------------

mkdir -p "$SYSTEMD_LIMIT_DIR"

cat > "$SYSTEMD_LIMIT_FILE" <<EOF
[Manager]
DefaultLimitNOFILE=1048576
EOF

# ------------------------------------------------------------
# 应用配置
# ------------------------------------------------------------

echo
echo "应用 sysctl..."

sysctl -p
systemctl daemon-reexec 2>/dev/null || true

# ------------------------------------------------------------
# conntrack hashsize
# ------------------------------------------------------------

if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
    if (( CONNTRACK_MAX >= 1048576 )); then
        echo 262144 > /sys/module/nf_conntrack/parameters/hashsize || true
    elif (( CONNTRACK_MAX >= 524288 )); then
        echo 131072 > /sys/module/nf_conntrack/parameters/hashsize || true
    fi
fi

# ------------------------------------------------------------
# 验证
# ------------------------------------------------------------

echo
echo "================================================="
echo "              当前网络参数"
echo "================================================="

echo
echo -n "拥塞算法："
sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true

echo -n "队列算法："
sysctl -n net.core.default_qdisc 2>/dev/null || true

echo -n "somaxconn："
sysctl -n net.core.somaxconn

echo -n "SYN backlog："
sysctl -n net.ipv4.tcp_max_syn_backlog

echo -n "netdev backlog："
sysctl -n net.core.netdev_max_backlog

echo -n "端口范围："
sysctl -n net.ipv4.ip_local_port_range

echo -n "rp_filter："
sysctl -n net.ipv4.conf.all.rp_filter

echo -n "IP Forward："
sysctl -n net.ipv4.ip_forward

if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    echo -n "Conntrack Max："
    cat /proc/sys/net/netfilter/nf_conntrack_max

    echo -n "Conntrack Current："
    cat /proc/sys/net/netfilter/nf_conntrack_count
fi

echo
echo "================================================="
echo "优化完成"
echo "================================================="
echo
echo "旧 /etc/sysctl.conf 已自动备份为带时间戳的 .bak 文件。"
echo
echo "建议重启入口程序，使新的文件描述符限制生效。"
echo
echo "例如："
echo "  soga restart"
echo
echo "或者直接重启服务器："
echo "  reboot"
echo

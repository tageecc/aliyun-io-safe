#!/bin/bash
# ==========================================================
# 阿里云/轻量服务器 I/O 防卡死配置管理脚本（自动探测版）
# 用法: sudo bash io-safe-auto.sh {start|stop|status}
# ==========================================================
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 配置路径
SYSCTL_FILE="/etc/sysctl.d/99-io-safe.conf"
UDEV_FILE="/etc/udev/rules.d/60-io-safe.rules"
SLICE_DIR="/etc/systemd/system/user.slice.d"
SLICE_FILE="${SLICE_DIR}/99-io-weight.conf"
FSTAB_FILE="/etc/fstab"
STATE_DIR="/var/lib/io-safe-auto"
STATE_FILE="${STATE_DIR}/state.env"

# 全局变量（将由自动探测函数赋值）
ROOT_DEV="vda"
DISK_SIZE_GB=0
NR_SAFE=32
NR_DEFAULT=128

# ================= 自动探测与计算 =================
auto_detect() {
    log_info "🔍 开始自动探测磁盘与系统环境..."

    # 1. 识别根分区物理盘
    local root_src
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null || echo "/dev/vda3")
    ROOT_DEV=$(lsblk -nro PKNAME "$root_src" 2>/dev/null || echo "vda")
    [[ -z "$ROOT_DEV" ]] && ROOT_DEV="vda"

    # 2. 获取磁盘容量 (GB)
    local size_bytes
    size_bytes=$(lsblk -b -n -d -o SIZE "/dev/${ROOT_DEV}" 2>/dev/null || echo "107374182400")
    DISK_SIZE_GB=$(( size_bytes / 1073741824 ))
    [[ $DISK_SIZE_GB -eq 0 ]] && DISK_SIZE_GB=100

    # 3. 读取当前队列深度默认值
    NR_DEFAULT=$(cat "/sys/block/${ROOT_DEV}/queue/nr_requests" 2>/dev/null || echo 128)

    # 4. 动态计算安全队列深度 (nr_requests)
    # 容量越大可容忍的队列稍深，但低配盘必须严格限制堆积。
    NR_SAFE=$(( 16 + DISK_SIZE_GB / 10 ))
    [[ $NR_SAFE -lt 16 ]] && NR_SAFE=16
    [[ $NR_SAFE -gt 64 ]] && NR_SAFE=64

    log_info "📊 探测结果: 设备=${ROOT_DEV} | 容量=${DISK_SIZE_GB}G | 默认队列=${NR_DEFAULT}"
    log_info "🎛️ 动态生成安全参数: nr_requests=${NR_SAFE} (范围: 16~64)"
}

# ================= 备份与回滚 =================
backup_file() {
    local f=$1
    [[ -f "$f" ]] || return 0
    local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$f" "$bak"
    log_info "已备份: $f -> $bak"
}

# ================= 启用配置 =================
cmd_start() {
    auto_detect

    log_info "🚀 开始应用防卡死配置..."

    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" << EOF
ROOT_DEV=${ROOT_DEV}
NR_DEFAULT=${NR_DEFAULT}
DISK_SIZE_GB=${DISK_SIZE_GB}
NR_SAFE=${NR_SAFE}
EOF
    log_info "已记录回滚状态: ${STATE_FILE}"

    # 1. 内核脏页调优 (8G 内存场景较常见)
    log_info "[1/4] 配置内核脏页参数..."
    cat > "$SYSCTL_FILE" << EOF
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_writeback_centisecs = 300
vm.dirty_expire_centisecs = 1500
vm.swappiness = 10
vm.vfs_cache_pressure = 150
EOF
    sysctl -p "$SYSCTL_FILE" > /dev/null

    # 2. 挂载参数优化
    log_info "[2/4] 优化挂载参数..."
    if mountpoint -q / && ! grep -q "noatime" "$FSTAB_FILE"; then
        backup_file "$FSTAB_FILE"
        sed -i.bak '/\s\/\s/ s/defaults/defaults,noatime,nodiratime/; /\s\/\s/ s/relatime/noatime,nodiratime/' "$FSTAB_FILE"
        mount -o remount /
        systemctl daemon-reload 2>/dev/null || true
        log_info "已更新 /etc/fstab 并重载根分区"
    else
        log_info "noatime 已存在，跳过"
    fi

    # 3. 限制块设备请求队列（核心防堆积）
    log_info "[3/4] 限制磁盘请求队列深度 -> ${NR_SAFE}..."
    echo "$NR_SAFE" > "/sys/block/${ROOT_DEV}/queue/nr_requests"
    cat > "$UDEV_FILE" << EOF
ACTION=="add|change", KERNEL=="${ROOT_DEV}", ATTR{queue/nr_requests}="${NR_SAFE}"
EOF

    # 4. Systemd 会话 I/O 权重降级
    log_info "[4/4] 配置用户会话 I/O 权重 (IOWeight=10)..."
    mkdir -p "$SLICE_DIR"
    cat > "$SLICE_FILE" << 'EOF'
[Slice]
# 降低终端命令的磁盘优先级，保障系统服务永远优先
IOWeight=10
EOF
    systemctl daemon-reload

    log_info "✅ 配置应用完成！"
    log_info "💡 请断开并重新连接 SSH，新会话将自动限速。"
    log_info "📊 验证: iostat -x ${ROOT_DEV} 1 | awk '/^${ROOT_DEV}/{printf \"IOPS:%d | await:%.1fms | util:%.1f%%\\n\", \$2+\$8, (\$6+\$12)/2, \$15}'"
}

# ================= 关闭配置 =================
cmd_stop() {
    if [[ -f "$STATE_FILE" ]]; then
        # 只写入脚本自己保存的简单变量，便于准确恢复启用前状态。
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        log_info "已读取回滚状态: ${STATE_FILE}"
    else
        auto_detect
        log_warn "未找到状态文件，将按当前探测结果尝试恢复"
    fi

    log_warn "⚠️ 开始恢复系统默认配置..."

    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f "$SYSCTL_FILE"
        sysctl -p /etc/sysctl.conf 2>/dev/null || true
        log_info "已移除脏页调优"
    fi

    if grep -q "noatime" "$FSTAB_FILE" 2>/dev/null; then
        backup_file "$FSTAB_FILE"
        sed -i 's/,noatime//g; s/,nodiratime//g; s/,,/,/g' "$FSTAB_FILE"
        mount -o remount /
        log_info "已恢复挂载参数"
    fi

    if [[ -f "$UDEV_FILE" ]]; then
        rm -f "$UDEV_FILE"
        echo "$NR_DEFAULT" > "/sys/block/${ROOT_DEV}/queue/nr_requests"
        log_info "已恢复队列深度 (=${NR_DEFAULT})"
    fi

    if [[ -f "$SLICE_FILE" ]]; then
        rm -f "$SLICE_FILE"
        systemctl daemon-reload
        log_info "已移除会话 I/O 权重限制"
    fi
    rmdir "$SLICE_DIR" 2>/dev/null || true
    rm -f "$STATE_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true

    log_info "✅ 配置已恢复。建议重启实例使内核状态完全重置: sudo reboot"
}

# ================= 查看状态 =================
cmd_status() {
    auto_detect

    echo -e "${YELLOW}=== I/O 防卡死配置状态 ===${NC}"
    [[ -f "$SYSCTL_FILE" ]] && echo "1. 脏页调优      : ${GREEN}✅ 已启用${NC}" || echo "1. 脏页调优      : ${RED}❌ 未启用${NC}"
    grep -q "noatime" "$FSTAB_FILE" 2>/dev/null && echo "2. noatime 挂载  : ${GREEN}✅ 已启用${NC}" || echo "2. noatime 挂载  : ${RED}❌ 未启用${NC}"
    cur_nr=$(cat "/sys/block/${ROOT_DEV}/queue/nr_requests" 2>/dev/null || echo "?")
    echo "3. 队列深度      : ${cur_nr} (当前安全阈值: ${NR_SAFE})"
    [[ -f "$SLICE_FILE" ]] && echo "4. 会话 IO 权重  : ${GREEN}✅ 已启用 (IOWeight=10)${NC}" || echo "4. 会话 IO 权重  : ${RED}❌ 未启用${NC}"
    echo ""
    echo "提示: sudo bash $0 {start|stop}"
}

# ================= 入口 =================
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 权限运行: sudo bash $0 $*"
fi

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    *)
        echo -e "用法: ${YELLOW}sudo bash $0 {start|stop|status}${NC}"
        echo "  start  : 自动探测并应用防卡死配置（推荐）"
        echo "  stop   : 恢复系统默认配置"
        echo "  status : 查看当前配置状态"
        exit 1
        ;;
esac

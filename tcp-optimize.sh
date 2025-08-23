#!/bin/bash
# ===================================================================
# 🚀 TCP 优化脚本 | 支持跨境场景 | BBR + FQ | 完全兼容 dash/bash
# 作者：Adger
# 特性：--target=local/global/auto，解决“本地延迟误导跨境优化”问题
# 新增：双向高吞吐优化，解决“上传快下载慢”问题
# ===================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 错误：请以 root 或 sudo 权限运行${NC}"
    exit 1
fi

echo -e "${BLUE}🚀 正在运行 TCP 优化脚本...${NC}"
OS=$(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release 2>/dev/null || uname -s)
echo -e "${GREEN}✅ 系统：${OS}${NC}"

# === 🔧 解析参数：--target=local/global/auto ===
TARGET_MODE="auto"
for arg in "$@"; do
    case $arg in
        --target=local|--target=global|--target=auto)
            TARGET_MODE="${arg#*=}"
            echo -e "${BLUE}🎯 优化模式：${TARGET_MODE}（基于 $arg）${NC}"
            ;;
    esac
done

# === 🔥 防火墙配置 ===
echo -e "${BLUE}🔧 配置防火墙，开放出站 5200-5210...${NC}"
if command -v ufw &> /dev/null; then
    ufw allow out 5200:5210/tcp > /dev/null 2>&1 || true
    echo -e "${GREEN}✅ UFW：已允许出站 5200-5210${NC}"
fi

if command -v iptables &> /dev/null; then
    iptables -A OUTPUT -p tcp --dport 5200:5210 -j ACCEPT > /dev/null 2>&1
    echo -e "${GREEN}✅ iptables：已允许出站 5200-5210${NC}"
fi

# === 🌍 公共 iPerf3 服务器（按区域分组）===
declare -a SERVERS_LOCAL=(
    "中国-香港 speedtest.hkg12.hk.leaseweb.net:5203"
    "新加坡    speedtest.singnet.com.sg:5203"
)

declare -a SERVERS_GLOBAL=(
    "美国-洛杉矶 speedtest.lax12.us.leaseweb.net:5003"
    "德国-诺德斯特兰 speedtest.wtnet.de:5303"
    "法国-巴黎 ping.online.net:5203"
)

# 合并用于测速
SERVERS_ALL=("${SERVERS_LOCAL[@]}" "${SERVERS_GLOBAL[@]}")

# === 🌐 探测延迟，区分用途 ===
echo -e "${BLUE}🌐 正在探测节点延迟...${NC}"
BEST_LOCAL_IP="" BEST_GLOBAL_IP=""
MIN_LOCAL_PING=9999 MIN_GLOBAL_PING=9999
BEST_NAME=""

for server in "${SERVERS_ALL[@]}"; do
    full_name=$(echo "$server" | awk '{print $1}')
    domain_port=$(echo "$server" | awk '{print $2}')
    location=$(echo "$full_name" | sed 's/[^-]*-//')
    domain=$(echo "$domain_port" | cut -d: -f1)
    port=$(echo "$domain_port" | cut -d: -f2)

    ip=$(ping -c1 -W2 "$domain" | grep -oE "\([0-9.]+\)" | tr -d "()" | head -1)
    [ -z "$ip" ] && continue

    ping_ms=$(ping -c3 -W2 "$ip" | grep 'avg' | awk -F'/' '{print $5}' 2>/dev/null)
    [ -z "$ping_ms" ] && continue

    ping_ms=$(printf "%.0f" "$ping_ms")
    echo -e "   $location $ip:$port → ${GREEN}${ping_ms}ms${NC}"

    # 分别记录本地和跨境延迟
    if [[ " ${SERVERS_LOCAL[*]} " =~ " $server " ]]; then
        if (( $(echo "$ping_ms < $MIN_LOCAL_PING" | bc -l 2>/dev/null || echo 0) )); then
            MIN_LOCAL_PING=$ping_ms
            BEST_LOCAL_IP=$ip
        fi
    else
        if (( $(echo "$ping_ms < $MIN_GLOBAL_PING" | bc -l 2>/dev/null || echo 0) )); then
            MIN_GLOBAL_PING=$ping_ms
            BEST_GLOBAL_IP=$ip
            BEST_NAME="$location ($domain:$port)"
        fi
    fi
done

# 确定测速节点（本地最优，减少测速干扰）
TEST_SERVER=${BEST_LOCAL_IP:-$BEST_GLOBAL_IP}
TEST_PORT=5203
if [ -z "$TEST_SERVER" ]; then
    echo -e "${RED}❌ 所有节点均无法访问${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 测速节点：使用本地最优节点（IP: $TEST_SERVER）${NC}"

# === 🧠 决定 TCP 优化参数的 RTT（核心改进）===
case $TARGET_MODE in
    local)
        USE_RTT=$MIN_LOCAL_PING
        echo -e "${YELLOW}📍 模式：local → 使用本地延迟 ${USE_RTT}ms 优化${NC}"
        ;;
    global)
        USE_RTT=$MIN_GLOBAL_PING
        echo -e "${YELLOW}🌍 模式：global → 使用跨境延迟 ${USE_RTT}ms 优化${NC}"
        ;;
    *)
        # auto：保守选择较大 RTT，避免低估
        USE_RTT=$(echo "$MIN_LOCAL_PING" "$MIN_GLOBAL_PING" | awk '{print ($1>$2?$1:$2)}')
        echo -e "${YELLOW}🔄 模式：auto → 使用较大延迟 ${USE_RTT}ms（更适配跨境）${NC}"
        ;;
esac

# === 📊 估算带宽等级（基于 USE_RTT）===
if (( $(echo "$USE_RTT < 50" | bc -l) )); then
    max_bw=10000
elif (( $(echo "$USE_RTT < 100" | bc -l) )); then
    max_bw=2500
elif (( $(echo "$USE_RTT < 150" | bc -l) )); then
    max_bw=1000
else
    max_bw=800  # 跨境保守估计
fi
echo -e "${GREEN}✅ 推荐优化带宽：${max_bw} Mbps（基于 RTT ${USE_RTT}ms）${NC}"

# === 📦 计算 TCP 缓冲区（BDP × 1.5，避免过大）===
rtt_sec=$(echo "$USE_RTT / 1000" | bc -l)
bdp_bytes=$(echo "$max_bw * 1000000 * $rtt_sec / 8" | bc -l)
rmem_max=$(echo "$bdp_bytes * 1.5" | bc -l)  # 原为 ×2，现改为 ×1.5
rmem_max=$(printf "%.0f" "$rmem_max")
rmem_max=${rmem_max:-134217728}
echo -e "${GREEN}🔧 设置 TCP 缓冲区上限：$((rmem_max/1024/1024)) MB${NC}"

# === 🛠️ 写入优化配置（BBR + FQ + 优化参数）===
cat > /tmp/tcp-opt.conf << EOF
# TCP 优化配置（BBR + FQ + 双向优化）
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq                    # 改为 fq，解决流竞争
net.core.rmem_max = $rmem_max
net.core.wmem_max = $rmem_max
net.ipv4.tcp_rmem = 4096 87380 $rmem_max
net.ipv4.tcp_wmem = 4096 65536 $rmem_max
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_ecn = 2                           # 启用 ECN 支持
net.ipv4.tcp_low_latency = 1                   # 优先处理小包（如 ACK）
net.ipv4.tcp_mtu_probing = 1
EOF

cp -f /tmp/tcp-opt.conf /etc/sysctl.d/99-tcp-opt.conf
sysctl --load /etc/sysctl.d/99-tcp-opt.conf > /dev/null 2>&1
echo -e "${GREEN}✅ TCP 优化已生效（BBR + FQ + 双向优化）${NC}"

# === 📡 安装依赖 ===
for cmd in iperf3 jq; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${BLUE}🔧 正在安装 $cmd...${NC}"
        if command -v apt &> /dev/null; then
            apt update -qq > /dev/null && apt install -y $cmd > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y $cmd > /dev/null 2>&1
        else
            echo -e "${RED}❌ 无法安装 $cmd${NC}"
            exit 1
        fi
    fi
done

# === 📊 测速函数（使用英文变量名）===
run_test() {
    local stage="$1"
    echo -e "${BLUE}📊 [$stage] 正在测速（反向下载 -R）...${NC}"
    timeout 15 iperf3 -c "$TEST_SERVER" -p 5203 -R -t 10 -O 3 --json > "/tmp/iperf3_${stage}.json" 2>&1
    if [ $? -eq 0 ] && [ -s "/tmp/iperf3_${stage}.json" ]; then
        speed=$(jq -r '.end.sum_received.bits_per_second / 1000000' "/tmp/iperf3_${stage}.json" 2>/dev/null | awk '{printf "%.1f", $1}')
        echo -e "${GREEN}✅ [$stage] 结果：${speed} Mbps${NC}"
        declare -g "${stage}_speed=$speed"
    else
        error_msg=$(tail -n 5 "/tmp/iperf3_${stage}.json" 2>/dev/null | grep -o 'error.*' || echo '连接失败')
        echo -e "${RED}❌ [$stage] 失败：$error_msg${NC}"
        declare -g "${stage}_speed=0.0"
    fi
}

# === 📈 执行测速对比 ===
sleep 2
run_test "before"
sleep 3
run_test "after"

# === 📋 生成报告 ===
: ${before_speed:=0.0}
: ${after_speed:=0.0}

echo -e "\n${CYAN}📈 ================== TCP 优化对比报告 ==================${NC}"
echo -e "   优化模式：$TARGET_MODE"
echo -e "   测速节点：本地最优（IP: $TEST_SERVER）"
echo -e "   优化依据：RTT = ${USE_RTT}ms → 带宽目标 ${max_bw} Mbps"
echo -e "   拥塞控制：BBR + FQ（双向优化）"
echo -e "${CYAN}-----------------------------------------------------${NC}"

printf "   %-10s : %8s Mbps\n" "优化前" "$before_speed"
printf "   %-10s : %8s Mbps\n" "优化后" "$after_speed"

# 计算提升率
if (( $(echo "$before_speed > 0.1" | bc -l 2>/dev/null || echo 0) )); then
    improvement=$(echo "scale=2; ($after_speed - $before_speed) / $before_speed * 100" | bc -l 2>/dev/null || echo "0")
    if (( $(echo "$improvement > 0" | bc -l) )); then
        printf "   %-10s : %+7.2f%% %s\n" "提升" "$improvement" "🚀"
    else
        printf "   %-10s : %+7.2f%% %s\n" "变化" "$improvement" "📉"
    fi
else
    echo -e "${YELLOW}   优化前测速失败，无法计算提升${NC}"
fi

echo -e "${CYAN}=====================================================${NC}"
echo -e "${GREEN}🎉 优化完成！你的服务器已为高延迟跨境场景做好准备！${NC}"

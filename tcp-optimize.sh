#!/bin/bash
# ===================================================================
# 🚀 TCP 优化脚本 | 支持跨境场景 | BBR + FQ/CAKE 自动选优
# 作者：Adger
# 特性：--target=local/global/auto，qdisc 自动对比选择最优
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
# === 📦 自动安装必要依赖 ===
echo -e "${BLUE}🔧 正在检查并安装必要工具...${NC}"
for cmd in iperf3 jq bc; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}⚠️  $cmd 未安装，正在安装...${NC}"
        if command -v apt &> /dev/null; then
            DEBIAN_FRONTEND=noninteractive apt update -qq > /dev/null && apt install -y "$cmd" > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y "$cmd" > /dev/null 2>&1
        elif command -v dnf &> /dev/null; then
            dnf install -y "$cmd" > /dev/null 2>&1
        elif command -v zypper &> /dev/null; then
            zypper install -y "$cmd" > /dev/null 2>&1
        else
            echo -e "${RED}❌ 无法安装 $cmd：不支持的包管理器${NC}"
            exit 1
        fi

        # 验证是否安装成功
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}❌ 安装 $cmd 失败，请手动安装后重试${NC}"
            exit 1
        else
            echo -e "${GREEN}✅ $cmd 安装成功${NC}"
        fi
    else
        echo -e "${GREEN}✅ $cmd 已安装${NC}"
    fi
done
OS=$(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release 2>/dev/null || uname -s)
echo -e "${GREEN}✅ 系统：${OS}${NC}"

# === 🔧 解析参数：--target=local/global/auto ===
TARGET_MODE="auto"
for arg in "$@"; do
    case $arg in
        --target=local|--target=global|--target=auto|--target=china-inbound)
            TARGET_MODE="${arg#*=}"
            echo -e "${BLUE}🎯 优化模式：${TARGET_MODE}（基于 $arg）${NC}"
            ;;
    esac
done

# === 🔥 防火墙配置 ===
echo -e "${BLUE}🔥 配置防火墙，开放出站 5200-5210...${NC}"
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
    "印度-孟买 BOM.proof.ovh.net:5203"
    "新加坡 speedtest.singnet.com.sg:5203"
    "新加坡 SGP.proof.ovh.net:5206"
)

declare -a SERVERS_GLOBAL=(
    "澳洲-悉尼 SYD.proof.ovh.net:5209"
    "法国-斯特拉斯堡 SBG.proof.ovh.net:5206"
    "法国-巴黎 ping.online.net:5203"
    "法国-鲁贝 RBX.proof.ovh.net:5206"
    "法国-格拉沃利讷 GRA.proof.ovh.net:5206"
    "美国-宾州 ERI.proof.ovh.net:5206"
)

# 合并用于测速
SERVERS_ALL=("${SERVERS_LOCAL[@]}" "${SERVERS_GLOBAL[@]}")

# === 🌐 探测延迟，区分用途 ===
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
        echo -e "${YELLOW}📈 模式：local → 使用本地延迟 ${USE_RTT}ms 优化${NC}"
        MULTIPLIER=1.5
        ;;
    global)
        USE_RTT=$MIN_GLOBAL_PING
        echo -e "${YELLOW}🌍 模式：global → 使用跨境延迟 ${USE_RTT}ms 优化${NC}"
        MULTIPLIER=1.8
        ;;
    china-inbound)
        USE_RTT=$MIN_GLOBAL_PING
        echo -e "${YELLOW}🇨🇳 模式：china-inbound → 专为‘境外→中国’优化，RTT=${USE_RTT}ms${NC}"
        MULTIPLIER=2.0
        ;;
    *)
        USE_RTT=$(echo "$MIN_LOCAL_PING" "$MIN_GLOBAL_PING" | awk '{print ($1>$2?$1:$2)}')
        echo -e "${YELLOW}🔧 模式：auto → 使用较大延迟 ${USE_RTT}ms（更适合跨境）${NC}"
        MULTIPLIER=1.8
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
    max_bw=800
fi
echo -e "${GREEN}✅ 推荐优化带宽：${max_bw} Mbps（基于 RTT ${USE_RTT}ms）${NC}"

# === 📦 计算 TCP 缓冲区（BDP × multiplier）===
rtt_sec=$(echo "scale=6; $USE_RTT / 1000" | bc -l)
bdp_bytes=$(echo "scale=6; $max_bw * 1000000 * $rtt_sec / 8" | bc -l)
rmem_max=$(echo "scale=0; $bdp_bytes * $multiplier" | bc -l)
rmem_max=$(printf "%.0f" "$rmem_max")
rmem_max=${rmem_max:-134217728}
rmem_max_clamped=$(echo "$rmem_max 67108864" | awk '{print ($1>$2)?67108864:$1}')
BUFFER_MB=$((rmem_max_clamped / 1024 / 1024))
echo -e "${GREEN}🔧 设置 TCP 缓冲区上限：${BUFFER_MB} MB${NC}"

# === 📦 安装依赖（新增 bc）===
for cmd in iperf3 jq bc; do
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

# === ⚖️  qdisc 对比测试：fq vs cake ===
echo -e "${BLUE}⚖️  正在对比 qdisc 性能：fq vs cake${NC}"

declare -A QDISC_RESULTS
BEST_QDISC="fq"
BEST_SPEED=0

for QDISC in fq cake; do
    echo -e "${CYAN}   → 测试 ${QDISC}...${NC}"

    # 临时应用配置
    echo "net.core.default_qdisc = $QDISC" > /tmp/tcp-temp.conf
    echo "net.core.rmem_max = $rmem_max_clamped" >> /tmp/tcp-temp.conf
    echo "net.core.wmem_max = $rmem_max_clamped" >> /tmp/tcp-temp.conf
    echo "net.ipv4.tcp_rmem = 4096 87380 $rmem_max_clamped" >> /tmp/tcp-temp.conf
    echo "net.ipv4.tcp_wmem = 4096 65536 $rmem_max_clamped" >> /tmp/tcp-temp.conf
    echo "net.ipv4.tcp_slow_start_after_idle = 0" >> /tmp/tcp-temp.conf
    echo "net.ipv4.tcp_ecn = 2" >> /tmp/tcp-temp.conf
    echo "net.ipv4.tcp_low_latency = 1" >> /tmp/tcp-temp.conf
    echo "net.ipv4.tcp_mtu_probing = 1" >> /tmp/tcp-temp.conf
    echo "net.ipv4.tcp_base_mss = 1400" >> /tmp/tcp-temp.conf
    echo "net.ipv4.tcp_notsent_lowat = 16384" >> /tmp/tcp-temp.conf
    echo "net.ipv4.tcp_comp_sack_delay_ns = 0" >> /tmp/tcp-temp.conf

    sysctl -p /tmp/tcp-temp.conf > /dev/null 2>&1
    sleep 2

    # 三次测速取平均
    total_speed=0
    valid_tests=0
    for i in {1..3}; do
        result=$(timeout 15 iperf3 -c "$TEST_SERVER" -p 5203 -R -t 10 -O 3 --json 2>/dev/null)
        if [ -n "$result" ]; then
            speed=$(echo "$result" | jq -r '.end.sum_received.bits_per_second / 1000000' 2>/dev/null | awk '{printf "%.1f", $1}')
            if (( $(echo "$speed > 1" | bc -l 2>/dev/null || echo 0) )); then
                total_speed=$(echo "$total_speed + $speed" | bc -l)
                valid_tests=$((valid_tests + 1))
            fi
        fi
    done

    avg_speed=0
    if [ $valid_tests -gt 0 ]; then
        avg_speed=$(echo "scale=1; $total_speed / $valid_tests" | bc -l)
    fi

    QDISC_RESULTS["$QDISC"]=$avg_speed
    echo -e "     ${QDISC^}: ${avg_speed} Mbps (${valid_tests}/3 成功)"

    if (( $(echo "$avg_speed > $BEST_SPEED" | bc -l) )); then
        BEST_SPEED=$avg_speed
        BEST_QDISC=$QDISC
    fi
done

echo -e "${GREEN}✅ 最优 qdisc: ${BEST_QDISC} (${BEST_SPEED} Mbps)${NC}"

# === 🛠️ 写入最终优化配置（使用胜出的 qdisc）===
cat > /tmp/tcp-opt.conf << EOF
# TCP 优化配置（自动选择最优 qdisc）
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = $BEST_QDISC
net.core.rmem_max = $rmem_max_clamped
net.core.wmem_max = $rmem_max_clamped
net.ipv4.tcp_rmem = 4096 87380 $rmem_max_clamped
net.ipv4.tcp_wmem = 4096 65536 $rmem_max_clamped
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1400
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_comp_sack_delay_ns = 0
EOF

cp -f /tmp/tcp-opt.conf /etc/sysctl.d/99-tcp-opt.conf
sysctl --load /etc/sysctl.d/99-tcp-opt.conf > /dev/null 2>&1
echo -e "${GREEN}✅ TCP 优化已生效（BBR + ${BEST_QDISC^} + 跨境增强）${NC}"

# === 🛠️ 设置初始拥塞窗口（initcwnd/initrwnd）
if command -v ip &> /dev/null; then
    DEFAULT_GW=$(ip route show default | awk '/default/ {print $3; exit}')
    DEFAULT_DEV=$(ip route show default | awk '/default/ {print $5; exit}')
    
    if [ -n "$DEFAULT_GW" ] && [ -n "$DEFAULT_DEV" ]; then
        ip route change default via "$DEFAULT_GW" dev "$DEFAULT_DEV" initcwnd 32 initrwnd 32 > /dev/null 2>&1 || true
        echo -e "${GREEN}✅ 初始窗口：initcwnd=32, initrwnd=32${NC}"
    fi
fi

# === 📊 测速函数（使用英文变量名）===
run_test() {
    local stage="$1"
    echo -e "${BLUE}📊 [$stage] 正在测速（反向下載 -R）...${NC}"
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
echo -e "   拥塞控制：BBR + ${BEST_QDISC^}（自动选优）"
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

# === 📊 追加 qdisc 对比结果 ===
echo -e "${CYAN}⚖️  qdisc 自动选优测试${NC}"
printf "   %-8s : %8s Mbps\n" "FQ"    "${QDISC_RESULTS[fq]:-0.0}"
printf "   %-8s : %8s Mbps\n" "CAKE"  "${QDISC_RESULTS[cake]:-0.0}"
echo -e "${CYAN}→ 最终选用: ${BEST_QDISC^}${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo -e "${GREEN}🎉 优化完成！你的服务器已为高延迟跨境场景做好准备！${NC}"

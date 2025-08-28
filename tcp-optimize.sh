#!/bin/bash
# ===================================================================
# 🚀 TCP 优化脚本 | 支持跨境场景 | BBR + FQ/CAKE 自动优选 | 支持自定义测速服务器
# 作者：Adger
# 特性：--target=local/global/auto/china-inbound, --custom-server=[IP/DOMAIN][:PORT], -p PORT
# ===================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# === 🔧 解析参数：--target=..., --custom-server=..., -p ... ===
TARGET_MODE="auto"
CUSTOM_SERVER=""
CUSTOM_PORT=""
# 使用 while 循环和 shift 来正确处理参数，特别是 -p PORT 这种形式
while [[ $# -gt 0 ]]; do
    case $1 in
        --target=local|--target=global|--target=auto|--target=china-inbound)
            TARGET_MODE="${1#*=}"
            echo -e "${BLUE}🎯 优化模式：${TARGET_MODE}（基于 $1）${NC}"
            shift # 移除已处理的参数
            ;;
        --custom-server=*)
            CUSTOM_SERVER="${1#*=}"
            echo -e "${BLUE}🎯 自定义测速服务器（来自 --custom-server）：${CUSTOM_SERVER}${NC}"
            shift # 移除已处理的参数
            ;;
        -p)
            CUSTOM_PORT="$2"
            echo -e "${BLUE}🎯 自定义测速端口（来自 -p）：${CUSTOM_PORT}${NC}"
            shift # 移除 -p
            shift # 移除端口号值
            ;;
        *)
            # 忽略未知参数或将其视为错误
            echo -e "${YELLOW}⚠️  忽略未知参数: $1${NC}"
            shift # 移除未知参数
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

# 初始化变量
BEST_LOCAL_IP="" BEST_GLOBAL_IP=""
MIN_LOCAL_PING=9999 MIN_GLOBAL_PING=9999
BEST_NAME=""
TEST_SERVER=""
TEST_PORT=""

# === 🎯 处理自定义服务器逻辑 (增强版) ===
if [ -n "$CUSTOM_SERVER" ]; then
    echo -e "${BLUE}🔍 正在处理自定义服务器参数...${NC}"
    
    # 从 --custom-server 中尝试解析地址和端口
    CUSTOM_SERVER_PART=$(echo "$CUSTOM_SERVER" | cut -d: -f1)
    CUSTOM_PORT_PART=$(echo "$CUSTOM_SERVER" | cut -d: -f2)
    
    # 如果 --custom-server 中包含了端口，则使用它
    if [ -n "$CUSTOM_PORT_PART" ] && [ "$CUSTOM_PORT_PART" != "$CUSTOM_SERVER" ]; then
        CUSTOM_DOMAIN_OR_IP=$CUSTOM_SERVER_PART
        FINAL_CUSTOM_PORT=$CUSTOM_PORT_PART
        echo -e "${BLUE}🔍 从 --custom-server 解析到地址: $CUSTOM_DOMAIN_OR_IP, 端口: $FINAL_CUSTOM_PORT${NC}"
    else
        # 否则，使用 --custom-server 的全部内容作为地址，并检查 -p 参数
        CUSTOM_DOMAIN_OR_IP=$CUSTOM_SERVER
        FINAL_CUSTOM_PORT=$CUSTOM_PORT # 如果 -p 未设置，这里会是空，后面会处理
        echo -e "${BLUE}🔍 从 --custom-server 解析到地址: $CUSTOM_DOMAIN_OR_IP${NC}"
        if [ -n "$CUSTOM_PORT" ]; then
            echo -e "${BLUE}🔍 从 -p 参数解析到端口: $CUSTOM_PORT${NC}"
        fi
    fi
    
    # 如果到这里 FINAL_CUSTOM_PORT 还是空，则使用默认端口 5201
    if [ -z "$FINAL_CUSTOM_PORT" ]; then
        FINAL_CUSTOM_PORT=5201
        echo -e "${YELLOW}⚠️  未指定端口，使用默认端口: $FINAL_CUSTOM_PORT${NC}"
    fi

    # 尝试解析 IP
    CUSTOM_IP=$(ping -c1 -W2 "$CUSTOM_DOMAIN_OR_IP" | grep -oE "\([0-9.]+\)" | tr -d "()" | head -1)
    if [ -z "$CUSTOM_IP" ]; then
        CUSTOM_IP=$CUSTOM_DOMAIN_OR_IP # 如果不是域名，假设是IP
    fi

    if [ -z "$CUSTOM_IP" ]; then
        echo -e "${RED}❌ 无法解析自定义服务器地址: $CUSTOM_DOMAIN_OR_IP${NC}"
        exit 1
    fi

    # 测试连通性 (简单 ping)
    echo -e "${BLUE}🔍 测试自定义服务器 $CUSTOM_IP:$FINAL_CUSTOM_PORT 连通性...${NC}"
    if ! ping -c1 -W2 "$CUSTOM_IP" > /dev/null 2>&1; then
        echo -e "${RED}❌ 无法 ping 通自定义服务器: $CUSTOM_IP${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 自定义服务器 $CUSTOM_IP 可达${NC}"

    # 使用自定义服务器作为测速目标
    TEST_SERVER=$CUSTOM_IP
    TEST_PORT=$FINAL_CUSTOM_PORT
    echo -e "${GREEN}✅ 测速节点：使用自定义服务器（IP: $TEST_SERVER, 端口: $TEST_PORT）${NC}"

else
    # === 🌐 探测延迟，区分用途 (原有逻辑) ===
    echo -e "${BLUE}🌐 正在探测默认节点延迟...${NC}"
    for server in "${SERVERS_ALL[@]}"; do
        full_name=$(echo "$server" | awk '{print $1}')
        domain_port=$(echo "$server" | awk '{print $2}')
        location=$(echo "$full_name" | sed 's/[^-]*-//')
        domain=$(echo "$domain_port" | cut -d: -f1)
        port=$(echo "$domain_port" | cut -d: -f2)

        # 尝试解析 IP
        ip=$(ping -c1 -W2 "$domain" | grep -oE "\([0-9.]+\)" | tr -d "()" | head -1)
        [ -z "$ip" ] && continue

        # Ping 3 次取平均
        ping_ms=$(ping -c3 -W2 "$ip" | grep 'avg' | awk -F'/' '{print $5}' 2>/dev/null)
        [ -z "$ping_ms" ] && continue

        # 四舍五入
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
    TEST_PORT=5203 # 默认公共服务器端口
    if [ -z "$TEST_SERVER" ]; then
        echo -e "${RED}❌ 所有默认节点均无法访问${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 测速节点：使用默认最优节点（IP: $TEST_SERVER）${NC}"
fi

# === 🧠 决定 TCP 优化参数的 RTT（核心改进）===
# 如果使用自定义服务器，我们无法预先知道其属于哪个区域，因此使用一个通用的 RTT 和 MULTIPLIER
if [ -n "$CUSTOM_SERVER" ]; then
    echo -e "${BLUE}🔧 使用自定义服务器，采用通用 RTT 估算...${NC}"
    # 这里可以做一个简单的 ping 来估算 RTT，或者使用默认值
    CUSTOM_PING_MS=$(ping -c3 -W2 "$TEST_SERVER" | grep 'avg' | awk -F'/' '{print $5}' 2>/dev/null)
    if [ -n "$CUSTOM_PING_MS" ]; then
        CUSTOM_PING_MS=$(printf "%.0f" "$CUSTOM_PING_MS")
        echo -e "${BLUE}⏱️  自定义服务器 ping 延迟: ${CUSTOM_PING_MS}ms${NC}"
        USE_RTT=$CUSTOM_PING_MS
    else
        # 如果 ping 失败，使用一个中等延迟作为 fallback
        echo -e "${YELLOW}⚠️  无法获取自定义服务器精确延迟，使用默认 100ms${NC}"
        USE_RTT=100
    fi
    # 为自定义服务器选择一个中等的 multiplier
    MULTIPLIER=1.8
    echo -e "${YELLOW}🔧 模式：custom → 使用估算延迟 ${USE_RTT}ms 优化${NC}"
else
    # 原有逻辑
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
fi

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

# === 📦 计算 TCP 缓冲区（BDP × MULTIPLIER） - 修复核心问题 ===
echo "Debug: USE_RTT=$USE_RTT, max_bw=$max_bw, MULTIPLIER=$MULTIPLIER" # 可选的调试信息
rtt_sec=$(echo "scale=6; $USE_RTT / 1000" | bc -l)
if [ $? -ne 0 ] || [ -z "$rtt_sec" ]; then
    echo -e "${RED}❌ 错误: 计算 rtt_sec 时出错${NC}"
    exit 1
fi

bdp_bytes=$(echo "scale=6; $max_bw * 1000000 * $rtt_sec / 8" | bc -l)
if [ $? -ne 0 ] || [ -z "$bdp_bytes" ]; then
    echo -e "${RED}❌ 错误: 计算 bdp_bytes 时出错${NC}"
    exit 1
fi

# 关键修复：将 $multiplier 更正为 $MULTIPLIER
rmem_max=$(echo "scale=0; $bdp_bytes * $MULTIPLIER / 1" | bc -l) # <--- 修复点
if [ $? -ne 0 ] || [ -z "$rmem_max" ]; then
    echo -e "${RED}❌ 错误: 计算 rmem_max 时出错${NC}"
    exit 1
fi

rmem_max=$(printf "%.0f" "$rmem_max")
# 确保如果上面 printf 失败，也有一个默认值
rmem_max=${rmem_max:-134217728}

# 限制最大缓冲区 (例如 64MB = 67108864 bytes)
rmem_max_clamped=$(echo "$rmem_max 67108864" | awk '{print ($1>$2)?$2:$1}') # 修正为限制最大值
BUFFER_MB=$((rmem_max_clamped / 1024 / 1024))
echo -e "${GREEN}🔧 设置 TCP 缓冲区上限：${BUFFER_MB} MB${NC}"

# === ⚖️  qdisc 对比测试：fq vs cake ===
echo -e "${BLUE}⚖️  正在对比 qdisc 性能：fq vs cake${NC}"

declare -A QDISC_RESULTS
BEST_QDISC="fq"
BEST_SPEED=0

for QDISC in fq cake; do
    echo -e "${CYAN}   → 测试 ${QDISC}...${NC}"

    # 临时应用配置
    cat > /tmp/tcp-temp.conf << EOF
net.core.default_qdisc = $QDISC
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
    sysctl -p /tmp/tcp-temp.conf > /dev/null 2>&1
    sleep 2

    # 三次测速取平均
    total_speed=0
    valid_tests=0
    for i in {1..3}; do
        # 增加超时时间和重试，提高成功率
        result=$(timeout 20 iperf3 -c "$TEST_SERVER" -p "$TEST_PORT" -R -t 10 -O 3 --json 2>/dev/null)
        if [ -n "$result" ]; then
            speed_mbps=$(echo "$result" | jq -r '.end.sum_received.bits_per_second' 2>/dev/null)
            # 检查 jq 是否成功解析且结果是数字
            if [ -n "$speed_mbps" ] && [[ $speed_mbps =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$speed_mbps > 1000000" | bc -l 2>/dev/null || echo 0) )); then
                 speed=$(echo "scale=1; $speed_mbps / 1000000" | bc -l)
                 speed=$(printf "%.1f" "$speed")
                 total_speed=$(echo "$total_speed + $speed" | bc -l)
                 valid_tests=$((valid_tests + 1))
                 echo -e "       测试 $i: ${speed} Mbps" # 调试信息
            else
                 echo -e "       测试 $i: 解析速度失败或速度过低 (${speed_mbps})" # 调试信息
            fi
        else
             echo -e "       测试 $i: iperf3 运行失败或超时" # 调试信息
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

echo -e "${GREEN}🎉 TCP 优化配置已应用并持久化到 /etc/sysctl.d/99-tcp-opt.conf${NC}"
echo -e "${BLUE}💡 建议：重启系统以确保所有优化完全生效${NC}"




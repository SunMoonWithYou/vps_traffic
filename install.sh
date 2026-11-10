#!/bin/bash
# =================================================================
# 名称: 流量统计 & TG 管理工具
# 版本: v4.0
# 功能:
#   - 每日 Telegram 日报
#   - 每小时上报到 Cloudflare Worker（仅 Worker，不发 TG）
#   - 时段流量转北京时间
#   - 支持多种 vnstat 日期格式
# =================================================================
VERSION="v4.0"
CONFIG_FILE="/etc/vnstat_tg.conf"
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"

# ---------- 环境准备 ----------
prepare_env() {
    echo "🔍 正在检查系统环境..."
    local deps=("vnstat" "bc" "curl" "cron")

    if [ -f /etc/debian_version ]; then
        PACKAGE_MANAGER="apt-get"
    elif [ -f /etc/redhat-release ]; then
        PACKAGE_MANAGER="yum"
    else
        echo "❌ 未知操作系统"
        exit 1
    fi

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo "安装依赖: $dep"
            if [ "$PACKAGE_MANAGER" = "apt-get" ]; then
                sudo apt-get install -y "$dep"
            else
                sudo yum install -y "$dep"
            fi
        fi
    done

    # cron 包名在不同系统不一样
    if ! command -v cron &>/dev/null && ! command -v crond &>/dev/null; then
        if [ "$PACKAGE_MANAGER" = "apt-get" ]; then
            sudo apt-get install -y cron
        else
            sudo yum install -y cronie
        fi
    fi

    sudo systemctl enable cron --now >/dev/null 2>&1 || sudo systemctl enable crond --now >/dev/null 2>&1
    sudo systemctl enable vnstat --now >/dev/null 2>&1
    sudo vnstat -u >/dev/null 2>&1
    echo "✅ 环境就绪"
}

# ---------- 生成上报脚本 ----------
generate_report_logic() {
    local BC_P=$(command -v bc)
    local VN_P=$(command -v vnstat)
    local CL_P=$(command -v curl)

    cat > "$BIN_PATH" << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 加载配置
[ -f "/etc/vnstat_tg.conf" ] && source "/etc/vnstat_tg.conf" || exit 1
[ -z "$TRAFFIC_MODE" ] && TRAFFIC_MODE=1
REPORT_TYPE="${1:-daily}"

# ---------- 工具函数 ----------

# 补零：.5 -> 0.5
fix_zero() {
    [[ $1 == .* ]] && echo "0$1" || echo "$1"
}

# 流量单位转 MB
val_to_mb() {
    local raw=$(echo "$1" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    local num=$(echo "$raw" | grep -oE '[0-9.]+' | head -n1)
    [ -z "$num" ] && num=0
    case "$raw" in
        *T*) echo "scale=2;$num*1048576" | $BC ;;
        *G*) echo "scale=2;$num*1024" | $BC ;;
        *K*) echo "scale=2;$num/1024" | $BC ;;
        *)   echo "$num" ;;
    esac
}

# 从 vnstat 行中提取第 N 个流量值
get_traffic() {
    echo "$1" | cut -c13- | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z/]+' | sed -n "${2}p" | xargs
}

# JSON 字符串转义（防止特殊字符破坏 JSON）
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# ---------- 初始化 ----------
$VN -i "$INTERFACE" --update >/dev/null 2>&1
SERVER_IP=$(hostname -I | awk '{print $1}')

# 预先获取日统计，后续复用
all_daily=$($VN -d 2>/dev/null)

# 计算计费周期起止
TODAY_D=$(date +%d | sed 's/^0//')
THIS_Y=$(date +%Y)
THIS_M=$(date +%m)
if [ "$TODAY_D" -lt "$RESET_DAY" ]; then
    START_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} -1 month" +%Y-%m-%d)
    END_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} -1 day" +%Y-%m-%d)
else
    START_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY}" +%Y-%m-%d)
    END_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} +1 month -1 day" +%Y-%m-%d)
fi

# 计算周期内累计流量（MB）
# 兼容多种 vnstat 日期格式
calc_period() {
    local until_ts=$1
    local total=0
    local all_data="${all_daily}"
    local cur_ts=$(date -d "$START_DATE" +%s)

    while [ "$cur_ts" -le "$until_ts" ]; do
        local d1=$(date -d "@$cur_ts" "+%Y-%m-%d")
        local d2=$(date -d "@$cur_ts" "+%m/%d/%y")
        local d3=$(date -d "@$cur_ts" "+%d.%m.%y")
        local d4=$(date -d "@$cur_ts" "+%m/%d/%Y")
        local line=$(echo "$all_data" | grep -E "$d1|$d2|$d3|$d4" | head -1)

        if [ -n "$line" ]; then
            local rx_s=$(get_traffic "$line" 1)
            local tx_s=$(get_traffic "$line" 2)
            local rx_mb=$(val_to_mb "$rx_s")
            local tx_mb=$(val_to_mb "$tx_s")
            local add=0
            case "$TRAFFIC_MODE" in
                2) add=$rx_mb ;;
                3) add=$tx_mb ;;
                4) (( $(echo "$rx_mb > $tx_mb" | $BC -l) )) && add=$rx_mb || add=$tx_mb ;;
                *) add=$(echo "$rx_mb + $tx_mb" | $BC) ;;
            esac
            total=$(echo "$total + $add" | $BC)
        fi
        cur_ts=$((cur_ts + 86400))
    done
    echo "$total"
}

# 流量模式名称
case "$TRAFFIC_MODE" in
    2) MODE_NAME="仅入站" ;;
    3) MODE_NAME="仅出站" ;;
    4) MODE_NAME="入/出取大" ;;
    *) MODE_NAME="入+出" ;;
esac

NOW=$(date "+%Y-%m-%d %H:%M")
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BJ_NOW=$(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M")

# 预先计算本地时区到北京时间的小时差（只算一次）
LOCAL_OFFSET=$(date +%z)
LOCAL_SIGN="${LOCAL_OFFSET:0:1}"
LOCAL_H=$((10#${LOCAL_OFFSET:1:2}))
[ "$LOCAL_SIGN" = "-" ] && LOCAL_H=$((-LOCAL_H))
BJ_DIFF=$((8 - LOCAL_H))

# 采集上一个完整小时的流量，并转为北京时间
collect_hourly() {
    local hours_json="["
    local hourly_data=$($VN -h 2>/dev/null | tail -n +5)
    local lines=()

    while IFS= read -r line; do
        if echo "$line" | grep -qE '[0-9]{2}:[0-9]{2}'; then
            lines+=("$line")
        fi
    done <<< "$hourly_data"

    local target_line=""
    local count=${#lines[@]}
    # 取倒数第二条（上一个完整小时），跳过当前未完成的小时
    if [ "$count" -ge 2 ]; then
        target_line="${lines[$((count-2))]}"
    elif [ "$count" -eq 1 ]; then
        target_line="${lines[0]}"
    fi

    if [ -n "$target_line" ]; then
        local hour=$(echo "$target_line" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1)
        local h=$(echo "$hour" | cut -d: -f1)
        local m=$(echo "$hour" | cut -d: -f2)
        local new_h=$((10#$h + BJ_DIFF))

        # 跨天处理
        if [ "$new_h" -ge 24 ]; then
            new_h=$((new_h - 24))
        elif [ "$new_h" -lt 0 ]; then
            new_h=$((new_h + 24))
        fi
        hour=$(printf "%02d:%s" "$new_h" "$m")

        local rx=$(echo "$target_line" | grep -oE '[0-9.]+[[:space:]]*[KMG]?i?B' | sed -n '1p')
        local tx=$(echo "$target_line" | grep -oE '[0-9.]+[[:space:]]*[KMG]?i?B' | sed -n '2p')
        [ -z "$rx" ] && rx="0"
        [ -z "$tx" ] && tx="0"

        local rx_mb=$(val_to_mb "$rx")
        local tx_mb=$(val_to_mb "$tx")
        local total_mb=$(echo "$rx_mb + $tx_mb" | $BC)

        hours_json+="{\"hour\":\"$hour\",\"rx_mb\":$rx_mb,\"tx_mb\":$tx_mb,\"total_mb\":$total_mb}"
    fi
    hours_json+="]"
    echo "$hours_json"
}

HOURLY_DATA=$(collect_hourly)

# ---------- 计算流量 ----------
if [ "$REPORT_TYPE" = "hourly" ]; then
    # 实时上报：统计到今天
    TODAY_TS=$(date +%s)
    TOTAL_MB=$(calc_period "$TODAY_TS")
    USED_GB=$(fix_zero $(echo "scale=2;$TOTAL_MB/1024" | $BC))
    PCT=$(echo "scale=0;$USED_GB*100/$MAX_GB" | $BC 2>/dev/null)
    [ -z "$PCT" ] && PCT=0

    TODAY_D_FULL=$(date +%Y-%m-%d)
    TODAY_LINE=$(echo "$all_daily" | grep -E "$TODAY_D_FULL|$(date +%m/%d/%y)|$(date +%d.%m.%y)" | head -1)
    if [ -n "$TODAY_LINE" ]; then
        T_RX=$(get_traffic "$TODAY_LINE" 1)
        T_TX=$(get_traffic "$TODAY_LINE" 2)
        DISP_RX="${T_RX/GiB/GB}"
        DISP_TX="${T_TX/GiB/GB}"
        TODAY_TOTAL=$(echo "$(val_to_mb "$T_RX") + $(val_to_mb "$T_TX")" | $BC)
        TODAY_GB=$(fix_zero $(echo "scale=2;$TODAY_TOTAL/1024" | $BC))
    else
        DISP_RX="0.00 GB"
        DISP_TX="0.00 GB"
        TODAY_GB="0.00"
    fi
    TITLE="流量实时上报"
    YEST_GB="-"
else
    # 日报：统计到昨天
    Y_D=$(date -d "yesterday" "+%Y-%m-%d")
    RAW_LINE=$(echo "$all_daily" | grep -Ei "yesterday|$Y_D" | head -1)
    if [ -n "$RAW_LINE" ]; then
        RX_STR=$(get_traffic "$RAW_LINE" 1)
        TX_STR=$(get_traffic "$RAW_LINE" 2)
        RX_MB=$(val_to_mb "$RX_STR")
        TX_MB=$(val_to_mb "$TX_STR")
        case "$TRAFFIC_MODE" in
            2) TOTAL_MB=$RX_MB ;;
            3) TOTAL_MB=$TX_MB ;;
            4) (( $(echo "$RX_MB > $TX_MB" | $BC -l) )) && TOTAL_MB=$RX_MB || TOTAL_MB=$TX_MB ;;
            *) TOTAL_MB=$(echo "$RX_MB + $TX_MB" | $BC) ;;
        esac
        TOTAL_YEST_GB=$(fix_zero $(echo "scale=2;$TOTAL_MB/1024" | $BC))
        DISP_RX="${RX_STR/GiB/GB}"
        DISP_TX="${TX_STR/GiB/GB}"
    else
        DISP_RX="0.00 GB"
        DISP_TX="0.00 GB"
        TOTAL_YEST_GB="0.00"
    fi
    YEST_TS=$(date -d "yesterday" +%s)
    TOTAL_PERIOD_MB=$(calc_period "$YEST_TS")
    USED_GB=$(fix_zero $(echo "scale=2;$TOTAL_PERIOD_MB/1024" | $BC))
    PCT=$(echo "scale=0;$USED_GB*100/$MAX_GB" | $BC 2>/dev/null)
    [ -z "$PCT" ] && PCT=0
    TITLE="流量日报"
    YEST_GB="$TOTAL_YEST_GB"
    TODAY_GB="-"
fi

# ---------- 发送 Telegram（仅日报）----------
if [ "$REPORT_TYPE" = "daily" ]; then
    MSG=$(printf "📊 *%s*\n\n💻主机：*%s*\n🛜 地址： \`%s\`\n\n⬇️ 下载： \`%s\`\n⬆️ 上传： \`%s\`\n📈 模式： \`%s\`\n\n🧮 昨日： \`%s GB\`\n📅 今日： \`%s GB\`\n\n📅 周期： \`%s ~ %s\`\n🔄 重置： 每月 %s 号\n\n⏳ 累计： \`%s / %s GB\`\n🎯 进度： \`%d%%\`\n\n🕙 \`%s\`" \
        "$TITLE" "$HOST_ALIAS" "$SERVER_IP" "$DISP_RX" "$DISP_TX" "$MODE_NAME" \
        "$YEST_GB" "$TODAY_GB" "$START_DATE" "$END_DATE" "$RESET_DAY" "$USED_GB" "$MAX_GB" "$PCT" "$NOW")

    $CL --connect-timeout 10 --retry 3 -s \
        -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$MSG" \
        -d "parse_mode=Markdown" \
        -d "disable_notification=true" >/dev/null
    echo "✅ Telegram 日报已发送"
fi

# ---------- 发送到 Worker（仅实时，带北京时间）----------
if [ "$REPORT_TYPE" = "hourly" ] && [ -n "$WORKER_URL" ] && [ -n "$UPLOAD_KEY" ]; then
    # 转义可能含特殊字符的字段
    ESC_HOST=$(json_escape "$HOST_ALIAS")
    ESC_IP=$(json_escape "$SERVER_IP")
    ESC_MODE=$(json_escape "$MODE_NAME")

    JSON=$(printf '{"host":"%s","ip":"%s","type":"%s","mode":"%s","rx":"%s","tx":"%s","yest_gb":"%s","today_gb":"%s","used_gb":"%s","max_gb":"%s","pct":"%s","period_start":"%s","period_end":"%s","reset_day":"%s","time":"%s","iso":"%s","hourly":%s}' \
        "$ESC_HOST" "$ESC_IP" "$REPORT_TYPE" "$ESC_MODE" "$DISP_RX" "$DISP_TX" \
        "$YEST_GB" "$TODAY_GB" "$USED_GB" "$MAX_GB" "$PCT" "$START_DATE" "$END_DATE" "$RESET_DAY" "$BJ_NOW" "$NOW_ISO" "$HOURLY_DATA")

    RESP=$($CL --connect-timeout 10 --retry 2 -s -w "\nHTTP_CODE:%{http_code}" \
        -X POST "$WORKER_URL" \
        -H "Content-Type: application/json" \
        -H "X-Upload-Key: $UPLOAD_KEY" \
        -d "$JSON")

    HTTP_CODE=$(echo "$RESP" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ Worker 已上报"
    else
        echo "⚠️  Worker 上报失败 (HTTP $HTTP_CODE)"
    fi
elif [ "$REPORT_TYPE" = "hourly" ]; then
    echo "ℹ️  未配置 Worker，跳过上报"
fi
EOF

    # 注入 bc / vnstat / curl 的实际路径
    sed -i "4i BC=\"$BC_P\"\nVN=\"$VN_P\"\nCL=\"$CL_P\"" "$BIN_PATH"
    chmod +x "$BIN_PATH"
}

# ---------- 配置录入 ----------
collect_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    echo "--- 请输入配置参数 ---"
    read -p "👤 主机别名 [${HOST_ALIAS}]: " input_val
    HOST_ALIAS=${input_val:-$HOST_ALIAS}

    read -p "🤖 Bot Token [${TG_TOKEN}]: " input_val
    TG_TOKEN=${input_val:-$TG_TOKEN}

    read -p "🆔 Chat ID [${TG_CHAT_ID}]: " input_val
    TG_CHAT_ID=${input_val:-$TG_CHAT_ID}

    read -p "📅 重置日 (1-31) [${RESET_DAY}]: " input_val
    RESET_DAY=${input_val:-$RESET_DAY}

    read -p "📊 限额 (GB) [${MAX_GB}]: " input_val
    MAX_GB=${input_val:-$MAX_GB}

    echo ""
    echo "📈 流量统计方式"
    echo " 1. 入+出（默认）  2. 仅入站  3. 仅出站  4. 入/出取大"
    read -p "选择 [${TRAFFIC_MODE:-1}]: " input_val
    TRAFFIC_MODE=${input_val:-${TRAFFIC_MODE:-1}}
    case "$TRAFFIC_MODE" in
        1|2|3|4) ;;
        *) TRAFFIC_MODE=1 ;;
    esac

    echo ""
    read -p "⏱️  后台每小时上报 (0=关闭 1=开启) [${HOURLY_REPORT:-0}]: " input_val
    HOURLY_REPORT=${input_val:-${HOURLY_REPORT:-0}}
    [[ "$HOURLY_REPORT" != "1" ]] && HOURLY_REPORT=0

    read -p "🌐 Worker 上报地址 (留空不启用) [${WORKER_URL}]: " input_val
    WORKER_URL=${input_val:-$WORKER_URL}

    read -p "🔑 上传密钥 (与 Worker 配置一致) [${UPLOAD_KEY}]: " input_val
    UPLOAD_KEY=${input_val:-$UPLOAD_KEY}

    IF_DEF=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
    read -p "🌐 网卡 [${INTERFACE:-$IF_DEF}]: " input_val
    INTERFACE=${input_val:-${INTERFACE:-$IF_DEF}}

    read -p "⏰ 每日报表时间 (HH:MM) [${RUN_TIME:-01:30}]: " input_val
    RUN_TIME=${input_val:-${RUN_TIME:-01:30}}

    cat > "$CONFIG_FILE" << EOF
HOST_ALIAS="$HOST_ALIAS"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
RESET_DAY=$RESET_DAY
MAX_GB=$MAX_GB
INTERFACE="$INTERFACE"
RUN_TIME="$RUN_TIME"
TRAFFIC_MODE=$TRAFFIC_MODE
HOURLY_REPORT=$HOURLY_REPORT
WORKER_URL="$WORKER_URL"
UPLOAD_KEY="$UPLOAD_KEY"
EOF

    generate_report_logic

    # 设置 cron
    H=$(echo "$RUN_TIME" | cut -d: -f1 | sed 's/^0//')
    M=$(echo "$RUN_TIME" | cut -d: -f2 | sed 's/^0//')
    [ -z "$H" ] && H=0
    [ -z "$M" ] && M=0

    # 每日日报
    (crontab -l 2>/dev/null | grep -Fv "$BIN_PATH"; echo "$M $H * * * /bin/bash $BIN_PATH daily") | crontab -

    # 每小时实时上报
    if [ "$HOURLY_REPORT" = "1" ]; then
        (crontab -l 2>/dev/null | grep -Fv "hourly"; echo "0 * * * * /bin/bash $BIN_PATH hourly") | crontab -
        echo "🚀 立即执行一次实时上报..."
        /bin/bash "$BIN_PATH" hourly
    else
        (crontab -l 2>/dev/null | grep -v "hourly") | crontab -
    fi
}

# ---------- 主菜单 ----------
while true; do
    clear
    echo "==========================================="
    echo "      流量统计管理工具  $VERSION"
    echo "==========================================="
    echo ""
    echo "  1) 全新安装"
    echo "  2) 修改配置"
    echo "  3) 更新脚本逻辑"
    echo ""
    echo "  4) 测试日报      (仅 Telegram)"
    echo "  5) 测试实时上报  (仅 Worker)"
    echo ""
    echo "  6) 彻底卸载"
    echo "  7) 退出"
    echo ""
    echo "==========================================="
    read -p "请选择 [1-7]: " choice

    case $choice in
        1)
            prepare_env
            collect_config
            echo "✅ 安装完成！"
            sleep 2
            ;;
        2)
            collect_config
            echo "✅ 配置更新成功！"
            sleep 2
            ;;
        3)
            generate_report_logic
            echo "✅ 逻辑已更新！"
            sleep 1
            ;;
        4)
            echo "正在发送日报..."
            "$BIN_PATH" daily
            sleep 2
            ;;
        5)
            echo "正在发送实时上报（仅 Worker）..."
            "$BIN_PATH" hourly
            sleep 2
            ;;
        6)
            (crontab -l 2>/dev/null | grep -v "$BIN_PATH") | crontab -
            rm -f "$BIN_PATH" "$CONFIG_FILE"
            echo "✅ 已卸载"
            sleep 2
            ;;
        7)
            exit 0
            ;;
        *)
            echo "无效选项"
            sleep 1
            ;;
    esac
done

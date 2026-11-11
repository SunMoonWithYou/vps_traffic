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
# ---------- 生成上报脚本 ----------
generate_report_logic() {
    local BC_P=$(command -v bc)
    local VN_P=$(command -v vnstat)
    local CL_P=$(command -v curl)

    cat > "$BIN_PATH" << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG="/tmp/vnstat_tg.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始执行 $1" >> "$LOG"

# 加载配置
[ -f "/etc/vnstat_tg.conf" ] && source "/etc/vnstat_tg.conf" || exit 1
[ -z "$TRAFFIC_MODE" ] && TRAFFIC_MODE=1
REPORT_TYPE="${1:-daily}"

# ---------- 工具函数 ----------

# 补零：.5 -> 0.5
fix_zero() {
    [[ $1 == .* ]] && echo "0$1" || echo "$1"
}

# 流量单位转 MB（统一补零，保证可拼 JSON）
val_to_mb() {
    local raw=$(echo "$1" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    local num=$(echo "$raw" | grep -oE '[0-9.]+' | head -n1)
    [ -z "$num" ] && num=0
    local result
    case "$raw" in
        *T*) result=$(echo "scale=2;$num*1048576" | $BC) ;;
        *G*) result=$(echo "scale=2;$num*1024" | $BC) ;;
        *K*) result=$(echo "scale=2;$num/1024" | $BC) ;;
        *)   result="$num" ;;
    esac
    fix_zero "$result"
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

# 安全计算百分比（MAX_GB=0 或异常时兜底为 0）
calc_pct() {
    local used=$1 max=$2 pct
    pct=$(echo "scale=0;$used*100/$max" | $BC 2>/dev/null)
    pct=${pct:-0}
    [[ "$pct" =~ ^-?[0-9]+$ ]] || pct=0
    echo $((10#$pct))
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
    local hourly_data=$($VN -h 2>/dev/null)

    # 目标本地时间：上一个完整小时
    local target_ts=$(date -d '1 hour ago' +%s)
    local target_date=$(date -d "@$target_ts" +%Y-%m-%d)
    local target_hour=$(date -d "@$target_ts" +%H)

    local cur_date=""
    local target_line=""
    local target_line_date=""

    # 滚动保存最后两行，用于回退
    local last_line="" last_line_date=""
    local prev_line="" prev_line_date=""

    local line
    while IFS= read -r line; do
        # 日期分组行：2026-11-09
        if echo "$line" | grep -qE '^[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
            cur_date=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
            continue
        fi
        # 小时行：18:00
        if echo "$line" | grep -qE '^[[:space:]]*[0-9]{2}:[0-9]{2}'; then
            local hh=$(echo "$line" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1 | cut -d: -f1)
            # 精确匹配 (日期, 小时)
            if [ -n "$cur_date" ] && [ "$cur_date" = "$target_date" ] && [ "$hh" = "$target_hour" ]; then
                target_line="$line"
                target_line_date="$cur_date"
            fi
            # 滚动保存最后两条
            prev_line="$last_line"; prev_line_date="$last_line_date"
            last_line="$line"; last_line_date="$cur_date"
        fi
    done <<< "$hourly_data"

    # 回退：精确匹配不到，用倒数第二条，再不行用最后一条
    if [ -z "$target_line" ]; then
        if [ -n "$prev_line" ]; then
            target_line="$prev_line"; target_line_date="$prev_line_date"
        elif [ -n "$last_line" ]; then
            target_line="$last_line"; target_line_date="$last_line_date"
        fi
    fi

    if [ -n "$target_line" ] && [ -n "$target_line_date" ]; then
        local raw_hour=$(echo "$target_line" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1)
        local h=$(echo "$raw_hour" | cut -d: -f1)
        local h_num=$((10#$h))

        # 本地日期 = vnstat 行所属日期
        local local_date="$target_line_date"

        # 转北京时间：小时 + BJ_DIFF，跨天同步调整日期
        local total_h=$((h_num + BJ_DIFF))
        local day_shift=0
        while [ "$total_h" -ge 24 ]; do total_h=$((total_h - 24)); day_shift=$((day_shift + 1)); done
        while [ "$total_h" -lt 0 ];  do total_h=$((total_h + 24)); day_shift=$((day_shift - 1)); done
        local bj_date=$(date -d "$local_date $day_shift days" +%Y-%m-%d)
        local bj_hour=$(printf "%02d:00" "$total_h")
        local bj_key="$bj_date $bj_hour"

        local rx=$(echo "$target_line" | grep -oE '[0-9.]+[[:space:]]*[KMG]?i?B' | sed -n '1p')
        local tx=$(echo "$target_line" | grep -oE '[0-9.]+[[:space:]]*[KMG]?i?B' | sed -n '2p')
        [ -z "$rx" ] && rx="0"
        [ -z "$tx" ] && tx="0"

        local rx_mb=$(fix_zero "$(val_to_mb "$rx")")
        local tx_mb=$(fix_zero "$(val_to_mb "$tx")")
        local total_mb=$(fix_zero "$(echo "$rx_mb + $tx_mb" | $BC)")

        # 关键：显式输出 key / date，Worker 端直接用，不要按接收时间猜日期
        hours_json+="{\"key\":\"$bj_key\",\"date\":\"$bj_date\",\"hour\":\"$bj_hour\",\"rx_mb\":$rx_mb,\"tx_mb\":$tx_mb,\"total_mb\":$total_mb}"
    fi
    hours_json+="]"
    echo "$hours_json"
}

HOURLY_DATA=$(collect_hourly)

# ---------- 计算流量 ----------
if [ "$REPORT_TYPE" = "hourly" ]; then
    # 实时上报：周期累计，今日由 Worker 累加
    TODAY_TS=$(date +%s)
    TOTAL_MB=$(calc_period "$TODAY_TS")
    USED_GB=$(fix_zero $(echo "scale=2;$TOTAL_MB/1024" | $BC))
    PCT=$(calc_pct "$USED_GB" "$MAX_GB")

    DISP_RX="-"
    DISP_TX="-"
    TODAY_GB="-"
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
    PCT=$(calc_pct "$USED_GB" "$MAX_GB")
    TITLE="流量日报"
    YEST_GB="$TOTAL_YEST_GB"
    TODAY_GB="-"
fi

# ---------- 发送 Telegram（仅日报）----------
if [ "$REPORT_TYPE" = "daily" ]; then
    BAR_LEN=10
    FILLED=$((PCT * BAR_LEN / 100))
    [ "$FILLED" -gt "$BAR_LEN" ] && FILLED=$BAR_LEN
    EMPTY=$((BAR_LEN - FILLED))
    if [ "$PCT" -ge 90 ]; then
        BLOCK="🟥"
    elif [ "$PCT" -ge 70 ]; then
        BLOCK="🟧"
    elif [ "$PCT" -ge 50 ]; then
        BLOCK="🟨"
    else
        BLOCK="🟩"
    fi
    BAR=""
    for ((i=0; i<FILLED; i++)); do BAR+="$BLOCK"; done
    for ((i=0; i<EMPTY; i++)); do BAR+="⬜"; done

    MSG=$(printf "📊 *流量日报*\n\n💻 主机：*%s*\n🛜 地址：\`%s\`\n\n⬇️ 下载：\`%s\`\n⬆️ 上传：\`%s\`\n📈 模式：\`%s\`\n\n🧮 昨日：\`%s GB\`\n\n📅 周期：\`%s ~ %s\`\n🔄 重置：每月 %s 号\n\n⏳ 累计：\`%s / %s GB\`\n🎯 进度：%s \`%d%%\`\n\n🕙 \`%s\`" \
        "$HOST_ALIAS" "$SERVER_IP" "$DISP_RX" "$DISP_TX" "$MODE_NAME" \
        "$YEST_GB" "$START_DATE" "$END_DATE" "$RESET_DAY" "$USED_GB" "$MAX_GB" "$BAR" "$PCT" "$NOW")

    RESP=$($CL --connect-timeout 10 --retry 3 -s \
        -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=$MSG" \
        -d "parse_mode=Markdown" \
        -d "disable_notification=true")

    if echo "$RESP" | grep -q '"ok":true'; then
        echo "✅ Telegram 日报已发送"
    else
        echo "⚠️  发送失败："
        echo "$RESP"
        echo "[$(date '+%F %T')] TG 发送失败 RESP=$RESP" >> "$LOG"
    fi
fi

# ---------- 发送到 Worker（仅实时，带北京时间）----------
if [ "$REPORT_TYPE" = "hourly" ] && [ -n "$WORKER_URL" ] && [ -n "$UPLOAD_KEY" ]; then
    ESC_HOST=$(json_escape "$HOST_ALIAS")
    ESC_IP=$(json_escape "$SERVER_IP")
    ESC_MODE=$(json_escape "$MODE_NAME")

    JSON=$(printf '{"host":"%s","ip":"%s","type":"%s","mode":"%s","rx":"%s","tx":"%s","yest_gb":"%s","today_gb":"%s","used_gb":"%s","max_gb":"%s","pct":"%s","period_start":"%s","period_end":"%s","reset_day":"%s","time":"%s","iso":"%s","hourly":%s}' \
        "$ESC_HOST" "$ESC_IP" "$REPORT_TYPE" "$ESC_MODE" "$DISP_RX" "$DISP_TX" \
        "$YEST_GB" "$TODAY_GB" "$USED_GB" "$MAX_GB" "$PCT" "$START_DATE" "$END_DATE" "$RESET_DAY" "$BJ_NOW" "$NOW_ISO" "$HOURLY_DATA")

    # 关键：-L 跟随跳转；--post30x 保证跳转后仍是 POST；超时与重试更稳
    RESP=$($CL -L --post301 --post302 --post303 \
        --connect-timeout 10 --max-time 30 \
        --retry 3 --retry-connrefused --retry-delay 2 \
        -s -w "\nHTTP_CODE:%{http_code}" \
        -X POST "$WORKER_URL" \
        -H "Content-Type: application/json" \
        -H "X-Upload-Key: $UPLOAD_KEY" \
        -d "$JSON")

    HTTP_CODE=$(echo "$RESP" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
    HTTP_CODE=${HTTP_CODE:-000}

    # 关键：接受所有 2xx
    case "$HTTP_CODE" in
        2??)
            echo "✅ Worker 已上报 (HTTP $HTTP_CODE)"
            echo "[$(date '+%F %T')] Worker 上报成功 HTTP $HTTP_CODE" >> "$LOG"
            ;;
        *)
            echo "⚠️  Worker 上报失败 (HTTP $HTTP_CODE)"
            echo "[$(date '+%F %T')] Worker 上报失败 HTTP $HTTP_CODE" >> "$LOG"
            echo "[$(date '+%F %T')] JSON=$JSON" >> "$LOG"
            echo "[$(date '+%F %T')] RESP=$RESP" >> "$LOG"
            ;;
    esac
elif [ "$REPORT_TYPE" = "hourly" ]; then
    echo "ℹ️  未配置 Worker，跳过上报"
    echo "[$(date '+%F %T')] 未配置 Worker" >> "$LOG"
fi
echo "[$(date '+%F %T')] 执行完成" >> "$LOG"
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

    read -p "🌐 Worker 上报地址 (完整路径) [${WORKER_URL}]: " input_val
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

    # 每日日报（精确匹配，避免误删其它任务）
    (crontab -l 2>/dev/null | grep -Fv "$BIN_PATH daily"; \
     echo "$M $H * * * /bin/bash $BIN_PATH daily >> /tmp/vnstat_tg.log 2>&1") | crontab -

    # 每小时实时上报
    if [ "$HOURLY_REPORT" = "1" ]; then
        (crontab -l 2>/dev/null | grep -Fv "$BIN_PATH hourly"; \
         echo "10 * * * * /bin/bash $BIN_PATH hourly >> /tmp/vnstat_tg.log 2>&1") | crontab -
        echo "🚀 立即执行一次实时上报..."
        /bin/bash "$BIN_PATH" hourly
    else
        (crontab -l 2>/dev/null | grep -Fv "$BIN_PATH hourly") | crontab -
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

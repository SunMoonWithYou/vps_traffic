#!/bin/bash
# =================================================================
# 名称: 流量统计 & TG 管理工具
# 版本: v4.5
# 功能:
#   - 每日 Telegram 流量日报
#   - 每小时上报到 Cloudflare Worker（按北京时间小时）
#   - 支持多种流量统计模式
#   - 设备唯一编码
#   - 自动日志轮转
#   - 兼容任意服务器时区
# =================================================================
VERSION="v4.5"
CONFIG_FILE="/etc/vnstat_tg.conf"
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"

# ---------- 环境准备 ----------
prepare_env() {
    echo "🔍 正在检查系统环境..."
    local deps=("vnstat" "bc" "curl" "cron")

    # 判断系统类型
    if [ -f /etc/debian_version ]; then
        PACKAGE_MANAGER="apt-get"
    elif [ -f /etc/redhat-release ]; then
        PACKAGE_MANAGER="yum"
    else
        echo "❌ 未知操作系统"
        exit 1
    fi

    # 安装缺失依赖
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

    # 确保 cron 服务存在
    if ! command -v cron &>/dev/null && ! command -v crond &>/dev/null; then
        if [ "$PACKAGE_MANAGER" = "apt-get" ]; then
            sudo apt-get install -y cron
        else
            sudo yum install -y cronie
        fi
    fi

    # 启动相关服务
    sudo systemctl enable cron --now >/dev/null 2>&1 || sudo systemctl enable crond --now >/dev/null 2>&1
    sudo systemctl enable vnstat --now >/dev/null 2>&1
    sudo vnstat -u >/dev/null 2>&1
    echo "✅ 环境就绪"
}

# ---------- 生成设备唯一编码 ----------
# 优先使用 /etc/machine-id，其次网卡 MAC，最后随机
generate_device_id() {
    local id=""
    if [ -f /etc/machine-id ]; then
        id=$(cat /etc/machine-id | tr -d '[:space:]' | head -c 32)
    fi
    if [ -z "$id" ] && [ -n "$INTERFACE" ]; then
        local mac=$(cat /sys/class/net/"$INTERFACE"/address 2>/dev/null | tr -d ':' | head -c 12)
        [ -n "$mac" ] && id="mac_${mac}"
    fi
    if [ -z "$id" ]; then
        id="dev_$(date +%s)_$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    echo "$id"
}

# ---------- 生成实际上报脚本 ----------
generate_report_logic() {
    local BC_P=$(command -v bc)
    local VN_P=$(command -v vnstat)
    local CL_P=$(command -v curl)

    cat > "$BIN_PATH" << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG="/tmp/vnstat_tg.log"

# 简单日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# 日志轮转：超过 5MB 只保留最后 2000 行
if [ -f "$LOG" ] && [ $(stat -c%s "$LOG" 2>/dev/null || echo 0) -gt 5242880 ]; then
    tail -n 2000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    log "日志已轮转"
fi

log "========== 开始执行 $1 =========="

# 加载配置
[ -f "/etc/vnstat_tg.conf" ] && source "/etc/vnstat_tg.conf" || { log "错误：配置文件不存在"; exit 1; }
[ -z "$TRAFFIC_MODE" ] && TRAFFIC_MODE=1
[ -z "$DEVICE_ID" ] && DEVICE_ID="unknown"
REPORT_TYPE="${1:-daily}"

# ---------- 工具函数 ----------

# 补零：.5 -> 0.5
fix_zero() {
    [[ $1 == .* ]] && echo "0$1" || echo "$1"
}

# 流量字符串转 MB（支持 MiB/GiB/KiB/MB/GB/KB）
val_to_mb() {
    local raw=$(echo "$1" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    local num=$(echo "$raw" | grep -oE '[0-9.]+' | head -n1)
    [ -z "$num" ] && num=0
    local result
    case "$raw" in
        *TIB*|*TB*) result=$(echo "scale=2;$num*1048576" | $BC) ;;
        *GIB*|*GB*) result=$(echo "scale=2;$num*1024" | $BC) ;;
        *MIB*|*MB*) result="$num" ;;
        *KIB*|*KB*) result=$(echo "scale=2;$num/1024" | $BC) ;;
        *)          result="$num" ;;
    esac
    fix_zero "$result"
}

# 字节转 MB
bytes_to_mb() {
    local bytes=$1
    [ -z "$bytes" ] || [ "$bytes" = "null" ] && bytes=0
    local mb=$(echo "scale=2;$bytes/1048576" | $BC 2>/dev/null)
    fix_zero "${mb:-0}"
}

# JSON 字符串转义
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# 安全计算百分比
calc_pct() {
    local used=$1 max=$2 pct
    pct=$(echo "scale=0;$used*100/$max" | $BC 2>/dev/null)
    pct=${pct:-0}
    [[ "$pct" =~ ^-?[0-9]+$ ]] || pct=0
    echo $((10#$pct))
}

# 检测 vnstat 是否支持 JSON
USE_JSON=0
if $VN --json 1 >/dev/null 2>&1; then
    USE_JSON=1
fi
log "vnstat JSON 支持: $USE_JSON"

# ---------- 初始化 ----------
$VN -i "$INTERFACE" --update >/dev/null 2>&1
SERVER_IP=$(hostname -I | awk '{print $1}')

# 计算当前计费周期起止日期
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
log "计费周期: $START_DATE ~ $END_DATE"

# 计算周期内累计流量（MB）——只解析一次日数据
calc_period() {
    local until_ts=$1
    local total=0
    declare -A day_map

    if [ "$USE_JSON" = "1" ]; then
        local json=$($VN -d --json 2>/dev/null)
        while IFS= read -r line; do
            if echo "$line" | grep -q '"year"'; then
                local y=$(echo "$line" | grep -oE '"year":[0-9]+' | cut -d: -f2)
                local m=$(echo "$line" | grep -oE '"month":[0-9]+' | cut -d: -f2)
                local d=$(echo "$line" | grep -oE '"day":[0-9]+' | cut -d: -f2)
                local rx=$(echo "$line" | grep -oE '"rx":[0-9]+' | cut -d: -f2)
                local tx=$(echo "$line" | grep -oE '"tx":[0-9]+' | cut -d: -f2)
                [ -z "$rx" ] && rx=0
                [ -z "$tx" ] && tx=0
                [ -n "$y" ] && day_map["$(printf '%04d-%02d-%02d' $y $m $d)"]="${rx}|${tx}|json"
            fi
        done <<< "$json"
    else
        local all_daily=$($VN -d 2>/dev/null)
        while IFS= read -r line; do
            local date_str=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
            [ -z "$date_str" ] && continue
            local rx_s=$(echo "$line" | cut -c13- | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z/]+' | sed -n '1p' | xargs)
            local tx_s=$(echo "$line" | cut -c13- | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z/]+' | sed -n '2p' | xargs)
            day_map["$date_str"]="${rx_s}|${tx_s}|text"
        done <<< "$all_daily"
    fi

    local cur_ts=$(date -d "$START_DATE" +%s)
    while [ "$cur_ts" -le "$until_ts" ]; do
        local d=$(date -d "@$cur_ts" +%Y-%m-%d)
        local data="${day_map[$d]}"
        if [ -n "$data" ]; then
            local rx=$(echo "$data" | cut -d'|' -f1)
            local tx=$(echo "$data" | cut -d'|' -f2)
            local typ=$(echo "$data" | cut -d'|' -f3)
            local rx_mb tx_mb add=0
            if [ "$typ" = "json" ]; then
                rx_mb=$(bytes_to_mb "$rx")
                tx_mb=$(bytes_to_mb "$tx")
            else
                rx_mb=$(val_to_mb "$rx")
                tx_mb=$(val_to_mb "$tx")
            fi
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

# 计算本地时区到北京时间的小时差
LOCAL_OFFSET=$(date +%z)
LOCAL_SIGN="${LOCAL_OFFSET:0:1}"
LOCAL_H=$((10#${LOCAL_OFFSET:1:2}))
[ "$LOCAL_SIGN" = "-" ] && LOCAL_H=$((-LOCAL_H))
BJ_DIFF=$((8 - LOCAL_H))
log "时区差值 BJ_DIFF=$BJ_DIFF 小时"

# 采集当天北京时间已过去的所有完整小时流量（只解析一次）
collect_hourly() {
    local hours_json="["
    local first=1
    declare -A hour_map

    # 一次性解析 vnstat 小时数据
    if [ "$USE_JSON" = "1" ]; then
        local json=$($VN -h --json 2>/dev/null)
        local cur_date=""
        while IFS= read -r line; do
            if echo "$line" | grep -q '"date"'; then
                local y=$(echo "$line" | grep -oE '"year":[0-9]+' | cut -d: -f2)
                local m=$(echo "$line" | grep -oE '"month":[0-9]+' | cut -d: -f2)
                local d=$(echo "$line" | grep -oE '"day":[0-9]+' | cut -d: -f2)
                [ -n "$y" ] && cur_date=$(printf "%04d-%02d-%02d" "$y" "$m" "$d")
            fi
            if echo "$line" | grep -q '"hour"' && [ -n "$cur_date" ]; then
                local h=$(echo "$line" | grep -oE '"hour":[0-9]+' | cut -d: -f2)
                local rx=$(echo "$line" | grep -oE '"rx":[0-9]+' | cut -d: -f2)
                local tx=$(echo "$line" | grep -oE '"tx":[0-9]+' | cut -d: -f2)
                [ -z "$rx" ] && rx=0
                [ -z "$tx" ] && tx=0
                hour_map["${cur_date}_${h}"]="${rx}|${tx}|json"
            fi
        done <<< "$json"
    else
        local hourly_data=$($VN -h 2>/dev/null)
        local cur_date=""
        while IFS= read -r line; do
            if echo "$line" | grep -qE '^[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
                cur_date=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
                continue
            fi
            if echo "$line" | grep -qE '^[[:space:]]*[0-9]{2}:[0-9]{2}' && [ -n "$cur_date" ]; then
                local hh=$(echo "$line" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1 | cut -d: -f1)
                local rx=$(echo "$line" | grep -oE '[0-9.]+[[:space:]]*[KMG]?i?B' | sed -n '1p')
                local tx=$(echo "$line" | grep -oE '[0-9.]+[[:space:]]*[KMG]?i?B' | sed -n '2p')
                [ -z "$rx" ] && rx="0"
                [ -z "$tx" ] && tx="0"
                hour_map["${cur_date}_${hh}"]="${rx}|${tx}|text"
            fi
        done <<< "$hourly_data"
    fi
    log "小时数据解析完成，共 ${#hour_map[@]} 条记录"

    # 从今天北京时间 00:00 到上一个完整小时
    local today_bj=$(TZ=Asia/Shanghai date +%Y-%m-%d)
    local start_ts=$(TZ=Asia/Shanghai date -d "$today_bj 00:00:00" +%s)
    local end_ts=$(TZ=Asia/Shanghai date -d '1 hour ago' +%s)
    end_ts=$(( end_ts - end_ts % 3600 ))

    local ts=$start_ts
    while [ "$ts" -le "$end_ts" ]; do
        local bj_date=$(TZ=Asia/Shanghai date -d "@$ts" +%Y-%m-%d)
        local bj_h=$(TZ=Asia/Shanghai date -d "@$ts" +%H)
        local bj_hour=$(printf "%02d:00" "$bj_h")

        # 换算成服务器本地时间去查表
        local local_ts=$((ts - BJ_DIFF * 3600))
        local local_date=$(date -d "@$local_ts" +%Y-%m-%d)
        local local_hour=$(date -d "@$local_ts" +%H)

        local rx_mb=0 tx_mb=0 total_mb=0
        local key="${local_date}_${local_hour}"
        if [ -n "${hour_map[$key]}" ]; then
            local data="${hour_map[$key]}"
            local rx=$(echo "$data" | cut -d'|' -f1)
            local tx=$(echo "$data" | cut -d'|' -f2)
            local typ=$(echo "$data" | cut -d'|' -f3)
            if [ "$typ" = "json" ]; then
                rx_mb=$(bytes_to_mb "$rx")
                tx_mb=$(bytes_to_mb "$tx")
            else
                rx_mb=$(fix_zero "$(val_to_mb "$rx")")
                tx_mb=$(fix_zero "$(val_to_mb "$tx")")
            fi
            total_mb=$(fix_zero "$(echo "$rx_mb + $tx_mb" | $BC)")
        fi

        [ "$first" = "0" ] && hours_json+=","
        hours_json+="{\"key\":\"$bj_date $bj_hour\",\"date\":\"$bj_date\",\"hour\":\"$bj_hour\",\"rx_mb\":$rx_mb,\"tx_mb\":$tx_mb,\"total_mb\":$total_mb}"
        first=0
        ts=$((ts + 3600))
    done
    hours_json+="]"
    echo "$hours_json"
}

HOURLY_DATA=$(collect_hourly)
log "小时流量数据生成完成"

# ---------- 计算流量 ----------
if [ "$REPORT_TYPE" = "hourly" ]; then
    TODAY_TS=$(date +%s)
    TOTAL_MB=$(calc_period "$TODAY_TS")
    USED_GB=$(fix_zero $(echo "scale=2;$TOTAL_MB/1024" | $BC))
    PCT=$(calc_pct "$USED_GB" "$MAX_GB")
    DISP_RX="-"
    DISP_TX="-"
    TODAY_GB="-"
    YEST_GB="-"
    log "实时上报 - 周期累计: ${USED_GB}GB (${PCT}%)"
else
    YEST_TS=$(date -d "yesterday" +%s)
    TOTAL_PERIOD_MB=$(calc_period "$YEST_TS")
    USED_GB=$(fix_zero $(echo "scale=2;$TOTAL_PERIOD_MB/1024" | $BC))
    PCT=$(calc_pct "$USED_GB" "$MAX_GB")
    YEST_GB="0.00"
    TODAY_GB="-"
    DISP_RX="0.00 GB"
    DISP_TX="0.00 GB"
    log "日报 - 周期累计: ${USED_GB}GB (${PCT}%)"
fi

# ---------- 发送 Telegram 日报 ----------
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

    MSG=$(printf "📊 *流量日报*\n\n🆔 设备：\`%s\`\n💻 主机：*%s*\n🛜 地址：\`%s\`\n\n⬇️ 下载：\`%s\`\n⬆️ 上传：\`%s\`\n📈 模式：\`%s\`\n\n🧮 昨日：\`%s GB\`\n\n📅 周期：\`%s ~ %s\`\n🔄 重置：每月 %s 号\n\n⏳ 累计：\`%s / %s GB\`\n🎯 进度：%s \`%d%%\`\n\n🕙 \`%s\`" \
        "$DEVICE_ID" "$HOST_ALIAS" "$SERVER_IP" "$DISP_RX" "$DISP_TX" "$MODE_NAME" \
        "$YEST_GB" "$START_DATE" "$END_DATE" "$RESET_DAY" "$USED_GB" "$MAX_GB" "$BAR" "$PCT" "$NOW")

    RESP=$($CL --connect-timeout 10 --retry 3 -s \
        -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=$MSG" \
        -d "parse_mode=Markdown" \
        -d "disable_notification=true")

    if echo "$RESP" | grep -q '"ok":true'; then
        log "Telegram 日报发送成功"
        echo "✅ Telegram 日报已发送"
    else
        log "Telegram 发送失败: $RESP"
        echo "⚠️ Telegram 发送失败"
    fi
fi

# ---------- 发送到 Cloudflare Worker ----------
if [ "$REPORT_TYPE" = "hourly" ] && [ -n "$WORKER_URL" ] && [ -n "$UPLOAD_KEY" ]; then
    ESC_HOST=$(json_escape "$HOST_ALIAS")
    ESC_IP=$(json_escape "$SERVER_IP")
    ESC_MODE=$(json_escape "$MODE_NAME")
    ESC_DEVICE=$(json_escape "$DEVICE_ID")

    JSON=$(printf '{"device_id":"%s","host":"%s","ip":"%s","type":"%s","mode":"%s","rx":"%s","tx":"%s","yest_gb":"%s","today_gb":"%s","used_gb":"%s","max_gb":"%s","pct":"%s","period_start":"%s","period_end":"%s","reset_day":"%s","time":"%s","iso":"%s","hourly":%s}' \
        "$ESC_DEVICE" "$ESC_HOST" "$ESC_IP" "$REPORT_TYPE" "$ESC_MODE" "$DISP_RX" "$DISP_TX" \
        "$YEST_GB" "$TODAY_GB" "$USED_GB" "$MAX_GB" "$PCT" "$START_DATE" "$END_DATE" "$RESET_DAY" "$BJ_NOW" "$NOW_ISO" "$HOURLY_DATA")

    log "准备上报 Worker (JSON 长度: ${#JSON})"

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

    case "$HTTP_CODE" in
        2??)
            log "Worker 上报成功 (HTTP $HTTP_CODE)"
            echo "✅ Worker 已上报 (HTTP $HTTP_CODE)"
            ;;
        *)
            log "Worker 上报失败 (HTTP $HTTP_CODE)"
            log "响应内容: $RESP"
            echo "⚠️ Worker 上报失败 (HTTP $HTTP_CODE)"
            ;;
    esac
elif [ "$REPORT_TYPE" = "hourly" ]; then
    log "未配置 Worker，跳过上报"
    echo "ℹ️ 未配置 Worker"
fi

log "========== 执行完成 =========="
EOF

    # 注入实际路径
    {
        echo "#!/bin/bash"
        echo "BC=\"$BC_P\""
        echo "VN=\"$VN_P\""
        echo "CL=\"$CL_P\""
        tail -n +2 "$BIN_PATH"
    } > "${BIN_PATH}.tmp" && mv "${BIN_PATH}.tmp" "$BIN_PATH"

    chmod +x "$BIN_PATH"
    [ -f "$CONFIG_FILE" ] && chmod 600 "$CONFIG_FILE"
}

# ---------- 配置录入 ----------
collect_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    # 生成或保留设备唯一编码
    if [ -z "$DEVICE_ID" ]; then
        DEVICE_ID=$(generate_device_id)
        echo "🆔 已生成设备唯一编码: $DEVICE_ID"
    else
        echo "🆔 当前设备唯一编码: $DEVICE_ID"
    fi

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
    read -p "🌐 Worker 上报地址 [${WORKER_URL}]: " input_val
    WORKER_URL=${input_val:-$WORKER_URL}
    read -p "🔑 上传密钥 [${UPLOAD_KEY}]: " input_val
    UPLOAD_KEY=${input_val:-$UPLOAD_KEY}
    IF_DEF=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
    read -p "🌐 网卡 [${INTERFACE:-$IF_DEF}]: " input_val
    INTERFACE=${input_val:-${INTERFACE:-$IF_DEF}}
    read -p "⏰ 每日报表时间 (HH:MM) [${RUN_TIME:-01:30}]: " input_val
    RUN_TIME=${input_val:-${RUN_TIME:-01:30}}

    # 写入配置文件
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
DEVICE_ID="$DEVICE_ID"
EOF
    chmod 600 "$CONFIG_FILE"
    generate_report_logic

    # 设置 cron
    H=$(echo "$RUN_TIME" | cut -d: -f1 | sed 's/^0//')
    M=$(echo "$RUN_TIME" | cut -d: -f2 | sed 's/^0//')
    [ -z "$H" ] && H=0
    [ -z "$M" ] && M=0

    (crontab -l 2>/dev/null | grep -Fv "$BIN_PATH daily"; \
     echo "$M $H * * * /bin/bash $BIN_PATH daily >> /tmp/vnstat_tg.log 2>&1") | crontab -

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
            echo "正在发送实时上报..."
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

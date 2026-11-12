#!/bin/bash
# =================================================================
# 名称: 流量统计 & TG 管理工具
# 版本: v4.7
# 功能:
#   - 每日 Telegram 流量日报（含昨日真实下载/上传）
#   - 每小时上报到 Cloudflare Worker（北京时间上一个完整小时）
#   - 支持多种流量统计模式
#   - 设备唯一编码
#   - 自动日志轮转
#   - 兼容任意服务器时区
# =================================================================
VERSION="v4.7"
CONFIG_FILE="/etc/vnstat_tg.conf"
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"

# ---------- 环境准备 ----------
prepare_env() {
    echo "🔍 正在检查系统环境..."
    if [ -f /etc/debian_version ]; then
        PACKAGE_MANAGER="apt-get"
    elif [ -f /etc/redhat-release ]; then
        PACKAGE_MANAGER="yum"
    else
        echo "❌ 未知操作系统"
        exit 1
    fi

    local missing=()
    local dep
    for dep in vnstat bc curl; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        if [ "$PACKAGE_MANAGER" = "apt-get" ]; then
            sudo apt-get update -qq >/dev/null 2>&1
            sudo apt-get install -y "${missing[@]}"
        else
            sudo yum install -y "${missing[@]}"
        fi
    fi

    # 确保 cron 服务存在
    if ! command -v cron &>/dev/null && ! command -v crond &>/dev/null; then
        if [ "$PACKAGE_MANAGER" = "apt-get" ]; then
            sudo apt-get install -y cron
        else
            sudo yum install -y cronie
        fi
    fi

    # 启动相关服务（vnStat 2.x 依赖 vnstatd 守护进程采集数据）
    sudo systemctl enable cron --now >/dev/null 2>&1 || sudo systemctl enable crond --now >/dev/null 2>&1
    sudo systemctl enable vnstat --now >/dev/null 2>&1
    echo "✅ 环境就绪"
}

# ---------- 生成设备唯一编码 ----------
# 优先使用 /etc/machine-id，其次网卡 MAC，最后随机
generate_device_id() {
    local id=""
    if [ -r /etc/machine-id ]; then
        id=$(tr -d '[:space:]' < /etc/machine-id | head -c 32)
    fi
    if [ -z "$id" ] && [ -n "$INTERFACE" ]; then
        local mac
        mac=$(tr -d ':' < "/sys/class/net/$INTERFACE/address" 2>/dev/null | head -c 12)
        [ -n "$mac" ] && id="mac_${mac}"
    fi
    if [ -z "$id" ]; then
        id="dev_$(date +%s)_$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    echo "$id"
}

# ---------- 生成实际上报脚本 ----------
generate_report_logic() {
    local BC_P VN_P CL_P
    BC_P=$(command -v bc)
    VN_P=$(command -v vnstat)
    CL_P=$(command -v curl)

    cat > "$BIN_PATH" << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG="/tmp/vnstat_tg.log"

# 简单日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# 日志轮转：超过 5MB 只保留最后 2000 行
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
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

# 流量字符串转 MB（支持 TiB/TB/GiB/GB/MiB/MB/KiB/KB），纯 bash 提取数值
val_to_mb() {
    local raw=${1//[[:space:]]/}
    raw=${raw^^}
    local num=0 result
    [[ $raw =~ ([0-9.]+) ]] && num=${BASH_REMATCH[1]}
    case "$raw" in
        *TIB*|*TB*) result=$(echo "scale=2;$num*1048576" | $BC) ;;
        *GIB*|*GB*) result=$(echo "scale=2;$num*1024" | $BC) ;;
        *MIB*|*MB*) result="$num" ;;
        *KIB*|*KB*) result=$(echo "scale=2;$num/1024" | $BC) ;;
        *)          result="$num" ;;
    esac
    fix_zero "$result"
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

# 安全计算百分比（max 为 0 或非法时返回 0，避免除零）
calc_pct() {
    local used=$1 max=$2 pct=0
    if [ -n "$max" ] && [ "$max" != "0" ]; then
        pct=$(echo "scale=0;$used*100/$max" | $BC 2>/dev/null)
    fi
    pct=${pct:-0}
    [[ "$pct" =~ ^-?[0-9]+$ ]] || pct=0
    echo $((10#$pct))
}

# ---------- 初始化 ----------
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

# 解析 vnstat 日数据到全局 DAY_MAP（日期 -> "rx串|tx串"，只解析一次）
# 注意：必须声明为关联数组，否则日期下标会被当作算术表达式求值
declare -A DAY_MAP
load_daily() {
    local line rest vals
    while IFS= read -r line; do
        [[ $line =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]] || continue
        rest=${line#*"${BASH_REMATCH[1]}"}
        mapfile -t vals < <(grep -oE '[0-9.]+[[:space:]]*[a-zA-Z/]+' <<< "$rest")
        DAY_MAP["${BASH_REMATCH[1]}"]="${vals[0]:-0}|${vals[1]:-0}"
    done < <($VN -d 2>/dev/null)
    log "日数据解析完成，共 ${#DAY_MAP[@]} 条记录"
}

# 计算周期内累计流量（MB），按 TRAFFIC_MODE 聚合
calc_period() {
    local until_ts=$1 total=0 cur_ts d data rx tx rx_mb tx_mb add
    cur_ts=$(date -d "$START_DATE" +%s)
    while [ "$cur_ts" -le "$until_ts" ]; do
        d=$(date -d "@$cur_ts" +%Y-%m-%d)
        data="${DAY_MAP[$d]}"
        if [ -n "$data" ]; then
            IFS='|' read -r rx tx _ <<< "$data"
            rx_mb=$(val_to_mb "$rx")
            tx_mb=$(val_to_mb "$tx")
            case "$TRAFFIC_MODE" in
                2) add=$rx_mb ;;
                3) add=$tx_mb ;;
                4) (( $(echo "$rx_mb > $tx_mb" | $BC -l) )) && add=$rx_mb || add=$tx_mb ;;
                *) add=$(echo "$rx_mb + $tx_mb" | $BC) ;;
            esac
            total=$(echo "$total + $add" | $BC)
        fi
        cur_ts=$(date -d "$d +1 day" +%s)
    done
    echo "$total"
}

# 按某日的 rx/tx 数据计算单日流量（MB），返回到 MODE_ADD / MODE_RX_MB / MODE_TX_MB
calc_day_mb() {
    local data=$1
    IFS='|' read -r MODE_RX_RAW MODE_TX_RAW _ <<< "$data"
    MODE_RX_MB=$(val_to_mb "$MODE_RX_RAW")
    MODE_TX_MB=$(val_to_mb "$MODE_TX_RAW")
    case "$TRAFFIC_MODE" in
        2) MODE_ADD=$MODE_RX_MB ;;
        3) MODE_ADD=$MODE_TX_MB ;;
        4) (( $(echo "$MODE_RX_MB > $MODE_TX_MB" | $BC -l) )) && MODE_ADD=$MODE_RX_MB || MODE_ADD=$MODE_TX_MB ;;
        *) MODE_ADD=$(echo "$MODE_RX_MB + $MODE_TX_MB" | $BC) ;;
    esac
}

# 采集上一个完整小时的流量（按北京时间输出），仅 hourly 模式调用
collect_hourly() {
    declare -A hour_map
    local line cur_date="" vals hh rx tx

    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
            cur_date=${BASH_REMATCH[1]}
        elif [[ $line =~ ^[[:space:]]*([0-9]{2}:[0-9]{2}) ]] && [ -n "$cur_date" ]; then
            hh=${BASH_REMATCH[1]%%:*}
            mapfile -t vals < <(grep -oE '[0-9.]+[[:space:]]*[KMG]?i?B' <<< "$line")
            rx=${vals[0]:-0}
            tx=${vals[1]:-0}
            hour_map["${cur_date}_${hh}"]="$rx|$tx"
        fi
    done < <($VN -h 2>/dev/null)
    log "小时数据解析完成，共 ${#hour_map[@]} 条记录"

    # 北京时间上一个完整小时
    local bj_ts=$(TZ=Asia/Shanghai date -d '1 hour ago' +%s)
    bj_ts=$(( bj_ts - bj_ts % 3600 ))
    local bj_date=$(TZ=Asia/Shanghai date -d "@$bj_ts" +%Y-%m-%d)
    # date +%H 本身已是两位零填充，直接拼接，避免 printf %d 把 08/09 当八进制
    local bj_hour="$(TZ=Asia/Shanghai date -d "@$bj_ts" +%H):00"

    # 换算成服务器本地时间去查表
    local local_ts=$((bj_ts - BJ_DIFF * 3600))
    local key="$(date -d "@$local_ts" +%Y-%m-%d)_$(date -d "@$local_ts" +%H)"

    local rx_mb=0 tx_mb=0 total_mb=0
    if [ -n "${hour_map[$key]}" ]; then
        IFS='|' read -r rx tx <<< "${hour_map[$key]}"
        rx_mb=$(val_to_mb "$rx")
        tx_mb=$(val_to_mb "$tx")
        total_mb=$(fix_zero "$(echo "$rx_mb + $tx_mb" | $BC)")
    else
        log "未找到 $key 的小时数据，按 0 处理"
    fi

    log "上个小时: 北京时间 $bj_date $bj_hour (本地 $key) rx=${rx_mb}MB tx=${tx_mb}MB"
    echo "[{\"key\":\"$bj_date $bj_hour\",\"date\":\"$bj_date\",\"hour\":\"$bj_hour\",\"rx_mb\":$rx_mb,\"tx_mb\":$tx_mb,\"total_mb\":$total_mb}]"
}

# 流量模式名称
case "$TRAFFIC_MODE" in
    2) MODE_NAME="仅入站" ;;
    3) MODE_NAME="仅出站" ;;
    4) MODE_NAME="入/出取大" ;;
    *) MODE_NAME="入+出" ;;
esac

# 计算本地时区到北京时间的小时差
LOCAL_OFFSET=$(date +%z)
LOCAL_SIGN="${LOCAL_OFFSET:0:1}"
LOCAL_H=$((10#${LOCAL_OFFSET:1:2}))
[ "$LOCAL_SIGN" = "-" ] && LOCAL_H=$((-LOCAL_H))
BJ_DIFF=$((8 - LOCAL_H))
log "时区差值 BJ_DIFF=$BJ_DIFF 小时"

NOW=$(date "+%Y-%m-%d %H:%M")
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BJ_NOW=$(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M")

load_daily

# ---------- 计算流量 ----------
if [ "$REPORT_TYPE" = "hourly" ]; then
    HOURLY_DATA=$(collect_hourly)
    log "小时流量数据生成完成"

    TOTAL_MB=$(calc_period "$(date +%s)")
    USED_GB=$(fix_zero "$(echo "scale=2;$TOTAL_MB/1024" | $BC)")
    PCT=$(calc_pct "$USED_GB" "$MAX_GB")
    DISP_RX="-"
    DISP_TX="-"
    TODAY_GB="-"
    YEST_GB="-"
    log "实时上报 - 周期累计: ${USED_GB}GB (${PCT}%)"
else
    YEST_D=$(date -d yesterday +%Y-%m-%d)
    TOTAL_PERIOD_MB=$(calc_period "$(date -d yesterday +%s)")
    USED_GB=$(fix_zero "$(echo "scale=2;$TOTAL_PERIOD_MB/1024" | $BC)")
    PCT=$(calc_pct "$USED_GB" "$MAX_GB")

    # 昨日真实流量
    YEST_GB="0.00"
    DISP_RX="0.00 GB"
    DISP_TX="0.00 GB"
    data="${DAY_MAP[$YEST_D]}"
    if [ -n "$data" ]; then
        calc_day_mb "$data"
        YEST_GB=$(fix_zero "$(echo "scale=2;$MODE_ADD/1024" | $BC)")
        DISP_RX="$(fix_zero "$(echo "scale=2;$MODE_RX_MB/1024" | $BC)") GB"
        DISP_TX="$(fix_zero "$(echo "scale=2;$MODE_TX_MB/1024" | $BC)") GB"
    else
        log "昨日 ($YEST_D) 无数据"
    fi
    log "日报 - 周期累计: ${USED_GB}GB (${PCT}%), 昨日: ${YEST_GB}GB"
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
    read -p "📅 重置日 (1-31) [${RESET_DAY:-1}]: " input_val
    RESET_DAY=${input_val:-${RESET_DAY:-1}}
    [[ "$RESET_DAY" =~ ^[0-9]+$ ]] || RESET_DAY=1
    RESET_DAY=$((10#$RESET_DAY))   # 归一化，避免 08/09 被当作八进制
    (( RESET_DAY < 1 )) && RESET_DAY=1
    (( RESET_DAY > 31 )) && RESET_DAY=31
    read -p "📊 限额 (GB) [${MAX_GB:-2000}]: " input_val
    MAX_GB=${input_val:-${MAX_GB:-2000}}
    [[ "$MAX_GB" =~ ^[0-9.]+$ ]] || MAX_GB=2000
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

    # 设置 cron（10# 去前导零，兼容 08/09 等写法）
    H=${RUN_TIME%%:*}
    M=${RUN_TIME##*:}
    [[ "$H" =~ ^[0-9]+$ ]] || H=1
    [[ "$M" =~ ^[0-9]+$ ]] || M=30
    H=$((10#$H))
    M=$((10#$M))
    (( H > 23 )) && H=23
    (( M > 59 )) && M=59

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
            rm -f "$BIN_PATH" "$CONFIG_FILE" /tmp/vnstat_tg.log
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

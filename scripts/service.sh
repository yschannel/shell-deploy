#!/usr/bin/env bash
# Public functions run in a subshell, keeping caller variables and traps intact.
_service_dispatch() (
    SERVICE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
    SERVICE_PID="$SERVICE_ROOT/run/app.pid"
    SERVICE_LOG="$SERVICE_ROOT/logs/app.log"
    SERVICE_APP="$SERVICE_ROOT/bin/app"
    command -v flock >/dev/null || { echo '缺少 flock，请安装 util-linux。' >&2; exit 1; }
    mkdir -p -- "$SERVICE_ROOT/run" || exit 1
    exec 9>"$SERVICE_ROOT/run/service.lock" || exit 1
    flock -w 15 9 || { echo '其他管理命令正在执行，请稍后重试。' >&2; exit 1; }
    "$@"
)

_service_error() { printf '[失败] %s\n' "$*" >&2; }

# Linux start time and executable identity distinguish reused PIDs, including
# across reboots. Do not rely on kill -0 or an executable name alone.
_service_snapshot() {
    local stat_line rest
    [[ $1 =~ ^[1-9][0-9]*$ ]] || return 1
    IFS= read -r stat_line 2>/dev/null < "/proc/$1/stat" || return 1
    rest=${stat_line##*) }
    local -a fields
    read -r -a fields <<< "$rest"
    [[ ${fields[0]:-} != Z && ${fields[0]:-} != X ]] || return 1
    SNAP_START=${fields[19]:-}
    SNAP_EXE=$(stat -Lc '%d:%i' -- "/proc/$1/exe" 2>/dev/null) || return 1
    [[ $SNAP_START =~ ^[0-9]+$ ]]
}

_service_owned() {
    local boot
    IFS= read -r boot < /proc/sys/kernel/random/boot_id || return 1
    [[ $boot == "$SAVED_BOOT" ]] || return 1
    _service_snapshot "$SAVED_PID" || return 1
    [[ $SNAP_START == "$SAVED_START" && $SNAP_EXE == "$SAVED_EXE" ]]
}

# 0: ours and alive, 1: absent, 2: stale/invalid. Never signal a stale record.
_service_read_pid() {
    local -a record
    [[ -e $SERVICE_PID ]] || return 1
    mapfile -t record < "$SERVICE_PID" || return 2
    [[ ${#record[@]} == 4 ]] || return 2
    SAVED_PID=${record[0]}; SAVED_START=${record[1]}
    SAVED_BOOT=${record[2]}; SAVED_EXE=${record[3]}
    [[ $SAVED_PID =~ ^[1-9][0-9]*$ && $SAVED_START =~ ^[0-9]+$ &&
       $SAVED_EXE =~ ^[0-9]+:[0-9]+$ ]] || return 2
    _service_owned || return 2
}

_service_config() {
    [[ -f $SERVICE_ROOT/config.conf ]] || {
        _service_error '缺少 config.conf，请先执行 bash deploy.sh setup。'; return 1;
    }
    PORT=; DATA_DIR=
    # config.conf is a trusted, local Bash file (same convention as setup).
    source "$SERVICE_ROOT/config.conf" || { _service_error '读取配置失败。'; return 1; }
    [[ $PORT =~ ^[0-9]{1,5}$ ]] || { _service_error 'PORT 必须为 1024..65535 的整数。'; return 1; }
    PORT=$((10#$PORT))
    (( PORT >= 1024 && PORT <= 65535 )) || { _service_error 'PORT 必须为 1024..65535 的整数。'; return 1; }
    [[ -n $DATA_DIR ]] || { _service_error 'DATA_DIR 不能为空。'; return 1; }
    [[ $DATA_DIR == /* ]] || DATA_DIR="$SERVICE_ROOT/$DATA_DIR"
    [[ -d $DATA_DIR && -w $DATA_DIR && -x $DATA_DIR ]] || {
        _service_error "数据目录不存在或不可用：$DATA_DIR"; return 1;
    }
}

_service_stop_owned() {
    _service_owned || return 0
    kill -TERM "$SAVED_PID" || { _service_owned && return 1; }
    local attempt
    for ((attempt=0; attempt<100; attempt++)); do
        _service_owned || return 0
        sleep 0.1
    done
    _service_error '停止超时；保留 PID 记录，未强制杀死进程。'
    return 1
}

_service_cleanup_start() {
    # Only called after recording the exact child identity.
    rm -f -- "$SERVICE_PID.tmp"
    if _service_stop_owned; then
        rm -f -- "$SERVICE_PID"
    else
        _service_error '启动失败后的进程仍存在，请执行 stop 重试。'
    fi
}

_service_start() {
    local state=0 listeners child attempt expected_exe health
    _service_read_pid || state=$?
    if (( state == 0 )); then
        printf '服务已运行（PID %s）。\n' "$SAVED_PID"; return 0
    elif (( state == 2 )); then
        printf '清理过期或无效的 PID 记录；不会停止该 PID 对应的进程。\n'
        rm -f -- "$SERVICE_PID" || return 1
    fi
    _service_config || return 1
    [[ -x $SERVICE_APP && -f $SERVICE_APP ]] || {
        _service_error '缺少可执行的 bin/app，请先执行 bash deploy.sh setup。'; return 1;
    }
    local dependency
    for dependency in curl ss nohup stat; do
        command -v "$dependency" >/dev/null || { _service_error "缺少命令：$dependency"; return 1; }
    done
    listeners=$(ss -H -ltn "sport = :$PORT") || { _service_error '无法检查端口。'; return 1; }
    [[ -z $listeners ]] || { _service_error "端口 $PORT 已被占用。"; return 1; }
    mkdir -p -- "$SERVICE_ROOT/logs" || return 1
    expected_exe=$(stat -Lc '%d:%i' -- "$SERVICE_APP") || return 1
    # Close the management lock in the child so the application cannot hold it.
    nohup "$SERVICE_APP" --port "$PORT" --data-dir "$DATA_DIR" \
        >>"$SERVICE_LOG" 2>&1 </dev/null 9>&- &
    child=$!
    # Wait until nohup has exec'd the compiled application before saving identity.
    for ((attempt=0; attempt<100; attempt++)); do
        if _service_snapshot "$child" && [[ $SNAP_EXE == "$expected_exe" ]]; then
            break
        fi
        kill -0 "$child" 2>/dev/null || break
        sleep 0.01
    done
    if ! _service_snapshot "$child" || [[ $SNAP_EXE != "$expected_exe" ]]; then
        _service_error "应用立即退出或无法确认身份。日志：$SERVICE_LOG"; return 1
    fi
    SAVED_PID=$child; SAVED_START=$SNAP_START; SAVED_EXE=$SNAP_EXE
    IFS= read -r SAVED_BOOT < /proc/sys/kernel/random/boot_id || return 1
    trap '_service_cleanup_start' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if ! (umask 077; printf '%s\n' "$SAVED_PID" "$SAVED_START" "$SAVED_BOOT" "$SAVED_EXE" > "$SERVICE_PID.tmp") ||
       ! mv -f -- "$SERVICE_PID.tmp" "$SERVICE_PID"; then
        _service_error '写入 PID 记录失败。'; return 1
    fi
    printf '正在等待服务就绪……\n'
    local deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
        _service_owned || break
        health=$(curl --noproxy '*' --fail --silent --max-time 1 \
            "http://127.0.0.1:$PORT/health") || health=
        if [[ $health == ok ]] && _service_owned; then
            trap - EXIT INT TERM HUP
            printf '[成功] 服务已就绪（PID %s）。\n访问地址：http://127.0.0.1:%s\n日志：%s\n' "$child" "$PORT" "$SERVICE_LOG"
            return 0
        fi
        sleep 0.1
    done
    _service_error "应用退出或在 10 秒内未就绪。日志：$SERVICE_LOG"
    return 1
}

_service_stop() {
    local state=0
    _service_read_pid || state=$?
    if (( state != 0 )); then
        if (( state == 2 )); then
            rm -f -- "$SERVICE_PID" || return 1
            printf '已清理过期或无效的 PID 记录；未停止任何进程。\n'
        else
            printf '服务已经停止。\n'
        fi
        return 0
    fi
    _service_stop_owned || return 1
    rm -f -- "$SERVICE_PID" || return 1
    printf '服务已停止。\n'
}

_service_status() {
    if _service_read_pid; then
        printf '服务运行中（PID %s）。\n' "$SAVED_PID"
    else
        printf '服务未运行（PID 记录不存在、已过期或无效）。\n'
        return 3
    fi
}

_service_logs() {
    [[ -f $SERVICE_LOG ]] || { _service_error "日志尚不存在：$SERVICE_LOG"; return 1; }
    tail -n 100 -- "$SERVICE_LOG"
}

_service_restart() { _service_stop && _service_start; }

start_service()   { _service_dispatch _service_start; }
stop_service()    { _service_dispatch _service_stop; }
restart_service() { _service_dispatch _service_restart; }
status_service()  { _service_dispatch _service_status; }
show_logs()       { _service_dispatch _service_logs; }

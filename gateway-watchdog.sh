#!/bin/bash
# Gateway watchdog v2
# - Health check based on local listener + HTTP probe (avoids fragile CLI text parsing)
# - Auto-repair known config breakages (e.g. invalid typingMode)
# - Rollback only when backup itself is validated
# - Single-instance lock to avoid overlapping recoveries

set -u

export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

OPENCLAW=$(command -v openclaw 2>/dev/null)
OPENCLAW_DIR="$HOME/.openclaw"
LOG_DIR="$OPENCLAW_DIR/logs"
LOG="$LOG_DIR/watchdog.log"
CONFIG="$OPENCLAW_DIR/openclaw.json"
CONFIG_BACKUP="$OPENCLAW_DIR/openclaw.json.watchdog-backup"
PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
STATE_DIR="$OPENCLAW_DIR/.watchdog"
LOCK_FILE="$STATE_DIR/watchdog.lock"
USER_UID=$(id -u)

mkdir -p "$LOG_DIR" "$STATE_DIR"

if [ -z "${OPENCLAW:-}" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [错误] openclaw 命令未找到，请检查 PATH" >> "$LOG"
  exit 1
fi

if ! command -v lsof >/dev/null 2>&1; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [错误] lsof 命令未找到，无法执行端口健康检测" >> "$LOG"
  exit 1
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

log_event() {
  local problem="$1"
  local action="$2"
  local result="$3"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [问题] $problem | [措施] $action | [结果] $result" >> "$LOG"
}

trim_text() {
  echo "$1" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-320
}

run_cmd_logged() {
  local label="$1"
  shift
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "[命令失败] $label (exit=$rc): $(trim_text "$out")"
  fi
  return "$rc"
}

cleanup_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(awk 'NR==1{print $1}' "$LOCK_FILE" 2>/dev/null || echo "")
    if [ "$lock_pid" = "$$" ]; then
      rm -f "$LOCK_FILE" 2>/dev/null || true
    fi
  fi
}

acquire_lock() {
  # Atomic lock file using noclobber
  if ( set -o noclobber; echo "$$ $(date +%s)" > "$LOCK_FILE" ) 2>/dev/null; then
    trap cleanup_lock EXIT INT TERM
    return 0
  fi

  # Stale lock protection (dead pid or lock older than 10 minutes)
  local now lock_pid lock_ts age
  now=$(date +%s)
  lock_pid=$(awk 'NR==1{print $1}' "$LOCK_FILE" 2>/dev/null || echo "")
  lock_ts=$(awk 'NR==1{print $2}' "$LOCK_FILE" 2>/dev/null || echo 0)
  if ! echo "$lock_ts" | grep -Eq '^[0-9]+$'; then
    lock_ts=0
  fi
  age=$((now - lock_ts))

  if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
    rm -f "$LOCK_FILE" 2>/dev/null || true
    if ( set -o noclobber; echo "$$ $(date +%s)" > "$LOCK_FILE" ) 2>/dev/null; then
      log_event "检测到死锁进程(pid=${lock_pid})" "清理旧锁并继续" "成功"
      trap cleanup_lock EXIT INT TERM
      return 0
    fi
  fi

  if [ "$lock_ts" -gt 0 ] && [ "$age" -gt 600 ]; then
    rm -f "$LOCK_FILE" 2>/dev/null || true
    if ( set -o noclobber; echo "$$ $(date +%s)" > "$LOCK_FILE" ) 2>/dev/null; then
      log_event "检测到过期锁(age=${age}s)" "清理旧锁并继续" "成功"
      trap cleanup_lock EXIT INT TERM
      return 0
    fi
  fi

  log "已有watchdog实例运行(pid=${lock_pid:-unknown})，跳过本轮"
  return 1
}

rotate_if_needed() {
  local file="$1"
  local max_bytes=$((5 * 1024 * 1024))
  local keep_bytes=$((1 * 1024 * 1024))
  local size

  if [ ! -f "$file" ]; then
    return 0
  fi
  if stat -f%z "$file" >/dev/null 2>&1; then
    size=$(stat -f%z "$file" 2>/dev/null || echo 0)
  else
    size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  fi
  if [ "$size" -gt "$max_bytes" ]; then
    tail -c "$keep_bytes" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    log_event "日志文件超过5MB: $file" "截断保留最新1MB" "完成"
  fi
}

get_port() {
  local p
  if has_jq; then
    p=$(jq -r '.gateway.port // 18789' "$CONFIG" 2>/dev/null || echo 18789)
  else
    p=$(python3 -c "import json; d=json.load(open('$CONFIG')); print(d.get('gateway',{}).get('port',18789))" 2>/dev/null || echo 18789)
  fi
  if echo "$p" | grep -Eq '^[0-9]+$'; then
    echo "$p"
  else
    echo 18789
  fi
}

has_jq() {
  command -v jq >/dev/null 2>&1 || return 1
  jq --version >/dev/null 2>&1
}

json_validate_file() {
  local file="$1"
  [ -f "$file" ] || return 1
  if has_jq; then
    jq empty "$file" >/dev/null 2>&1
  else
    python3 - "$file" >/dev/null 2>&1 <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    json.load(f)
PY
  fi
}

json_get_typing_mode() {
  local file="$1"
  if has_jq; then
    jq -r '.agents.defaults.typingMode // empty' "$file" 2>/dev/null || echo ""
  else
    python3 - "$file" 2>/dev/null <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    mode = data.get("agents", {}).get("defaults", {}).get("typingMode", "")
    if mode is None:
        mode = ""
    print(mode)
except Exception:
    pass
PY
  fi
}

json_set_typing_mode_message() {
  local file="$1"
  local tmp="$file.tmp.$$"
  if has_jq; then
    jq '.agents.defaults.typingMode = "message"' "$file" > "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  else
    if ! python3 - "$file" "$tmp" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]

with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict):
    raise SystemExit(1)

agents = data.get("agents")
if not isinstance(agents, dict):
    agents = {}
    data["agents"] = agents

defaults = agents.get("defaults")
if not isinstance(defaults, dict):
    defaults = {}
    agents["defaults"] = defaults

defaults["typingMode"] = "message"

with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
    then
      rm -f "$tmp"
      return 1
    fi
  fi
  mv "$tmp" "$file"
}

is_typing_mode_valid() {
  case "$1" in
    ""|never|instant|thinking|message) return 0 ;;
    *) return 1 ;;
  esac
}

config_quick_validate() {
  local file="$1"
  local mode
  json_validate_file "$file" || return 1
  mode=$(json_get_typing_mode "$file")
  is_typing_mode_valid "$mode"
}

sanitize_known_config_issues() {
  local file="$1"
  local label="$2"
  local mode

  [ -f "$file" ] || return 1
  json_validate_file "$file" || return 1

  mode=$(json_get_typing_mode "$file")
  if ! is_typing_mode_valid "$mode"; then
    if json_set_typing_mode_message "$file"; then
      log_event "${label}配置typingMode非法(${mode})" "自动修正为message" "成功"
      chmod 600 "$file" 2>/dev/null || true
    else
      log_event "${label}配置typingMode非法(${mode})" "自动修正为message" "失败"
      return 1
    fi
  fi
  return 0
}

listener_pid() {
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | head -1
}

listener_command() {
  local pid="$1"
  ps -p "$pid" -o command= 2>/dev/null
}

is_openclaw_listener_cmd() {
  echo "$1" | grep -Eq 'openclaw-gateway|openclaw/dist/index\.js.* gateway|openclaw\.mjs.*gateway|[ /]openclaw gateway'
}

is_port_listening() {
  [ -n "$(listener_pid)" ]
}

http_probe_once() {
  local code
  code=$(curl -sS -m 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)
  [ "$code" != "000" ]
}

probe_gateway_ready() {
  local i
  for i in 1 2 3 4 5; do
    if is_port_listening && http_probe_once; then
      return 0
    fi
    sleep 2
  done
  return 1
}

service_loaded() {
  launchctl print "gui/${USER_UID}/ai.openclaw.gateway" >/dev/null 2>&1
}

openclaw_gateway_pids() {
  ps -axo pid=,command= | awk '
    $0 ~ /openclaw-gateway/ || $0 ~ /openclaw\/dist\/index\.js .*gateway/ {
      print $1
    }
  '
}

refresh_backup_if_safe() {
  if config_quick_validate "$CONFIG"; then
    cp "$CONFIG" "$CONFIG_BACKUP" 2>/dev/null || return 1
    chmod 600 "$CONFIG" "$CONFIG_BACKUP" 2>/dev/null || true
    return 0
  fi
  return 1
}

recover_config() {
  sanitize_known_config_issues "$CONFIG" "当前" || true
  if config_quick_validate "$CONFIG"; then
    return 0
  fi

  run_cmd_logged "openclaw doctor --fix" "$OPENCLAW" doctor --fix || true
  sanitize_known_config_issues "$CONFIG" "当前" || true
  if config_quick_validate "$CONFIG"; then
    log_event "检测到当前配置无效" "doctor --fix/自动修正" "成功"
    return 0
  fi

  if [ -f "$CONFIG_BACKUP" ]; then
    sanitize_known_config_issues "$CONFIG_BACKUP" "备份" || true
    if config_quick_validate "$CONFIG_BACKUP"; then
      cp "$CONFIG_BACKUP" "$CONFIG" 2>/dev/null
      chmod 600 "$CONFIG" 2>/dev/null || true
      log_event "检测到当前配置无效" "回滚到已校验备份" "成功"
      return 0
    fi
    log_event "检测到当前配置无效" "备份校验失败，拒绝回滚" "失败"
  else
    log_event "检测到当前配置无效" "无备份可回滚" "失败"
  fi

  return 1
}

start_gateway() {
  run_cmd_logged "openclaw gateway start" "$OPENCLAW" gateway start || true
  probe_gateway_ready && return 0

  if [ -f "$PLIST" ]; then
    run_cmd_logged "launchctl kickstart" launchctl kickstart -k "gui/${USER_UID}/ai.openclaw.gateway" || true
    probe_gateway_ready && return 0

    if ! service_loaded; then
      run_cmd_logged "launchctl bootstrap" launchctl bootstrap "gui/${USER_UID}" "$PLIST" || true
      run_cmd_logged "launchctl kickstart(bootstrap后)" launchctl kickstart -k "gui/${USER_UID}/ai.openclaw.gateway" || true
      probe_gateway_ready && return 0
    fi
  fi

  run_cmd_logged "openclaw gateway start --force" "$OPENCLAW" gateway start --force || true
  probe_gateway_ready
}

restart_gateway() {
  run_cmd_logged "openclaw gateway restart --force" "$OPENCLAW" gateway restart --force || true
  probe_gateway_ready && return 0

  # fallback: if openclaw listener process exists but is unhealthy, terminate it then start fresh
  local pid cmd
  pid=$(listener_pid)
  if [ -n "$pid" ]; then
    cmd=$(listener_command "$pid")
    if is_openclaw_listener_cmd "$cmd"; then
      kill -15 "$pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
      fi
    fi
  fi

  start_gateway
}

kill_conflict_listener() {
  local pid="$1"
  kill -15 "$pid" 2>/dev/null || true
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
  fi
  ! kill -0 "$pid" 2>/dev/null
}

kill_stale_gateway_processes() {
  local pids pid
  pids=$(openclaw_gateway_pids)
  [ -n "${pids}" ] || return 0
  for pid in $pids; do
    kill -15 "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  sleep 1
  return 0
}

acquire_lock || exit 0

rotate_if_needed "$LOG_DIR/gateway.log"
rotate_if_needed "$LOG_DIR/gateway.err.log"
rotate_if_needed "$LOG"

if [ ! -f "$CONFIG" ]; then
  log_event "配置文件不存在: $CONFIG" "跳过本轮" "失败，需人工介入"
  exit 1
fi

sanitize_known_config_issues "$CONFIG" "当前" || true
PORT=$(get_port)

# Healthy path: local listener + HTTP response + listener is openclaw process.
if is_port_listening; then
  PID=$(listener_pid)
  CMD=$(listener_command "$PID")
  if is_openclaw_listener_cmd "$CMD" && probe_gateway_ready; then
    refresh_backup_if_safe || true
    exit 0
  fi
fi

if is_port_listening; then
  PID=$(listener_pid)
  CMD=$(listener_command "$PID")

  if ! is_openclaw_listener_cmd "$CMD"; then
    if kill_conflict_listener "$PID"; then
      recover_config || true
      if start_gateway; then
        refresh_backup_if_safe || true
        log_event "端口${PORT}被非网关进程占用(PID ${PID})" "清理占用并启动网关" "成功"
      else
        log_event "端口${PORT}被非网关进程占用(PID ${PID})" "清理占用并启动网关" "失败，需人工介入"
      fi
    else
      log_event "端口${PORT}被非网关进程占用(PID ${PID})" "终止占用进程" "失败，需人工介入"
    fi
    exit 0
  fi

  recover_config || true
  if restart_gateway; then
    refresh_backup_if_safe || true
    log_event "网关进程存在但服务不可用(PID ${PID})" "重启网关并自检" "成功"
  else
    log_event "网关进程存在但服务不可用(PID ${PID})" "重启网关并自检" "失败，需人工介入"
  fi
  exit 0
fi

# No listener on port
recover_config || true
kill_stale_gateway_processes
if start_gateway; then
  refresh_backup_if_safe || true
  log_event "网关端口${PORT}未监听" "启动网关并自检" "成功"
else
  log_event "网关端口${PORT}未监听" "启动网关并自检" "失败，需人工介入"
fi

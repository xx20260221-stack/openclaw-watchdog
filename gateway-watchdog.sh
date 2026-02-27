#!/bin/bash
# Gateway watchdog — restart if process is dead or RPC probe fails
# Also handles port conflicts, log rotation, config backup/rollback

# Auto-detect paths
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:$HOME/.local/bin:/usr/bin:/bin:$PATH"

OPENCLAW=$(command -v openclaw 2>/dev/null)
if [ -z "$OPENCLAW" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [错误] openclaw 命令未找到，请检查 PATH" >> "$HOME/.openclaw/logs/watchdog.log"
  exit 1
fi

OPENCLAW_DIR="$HOME/.openclaw"
LOG="$OPENCLAW_DIR/logs/watchdog.log"
LOG_DIR="$OPENCLAW_DIR/logs"
CONFIG="$OPENCLAW_DIR/openclaw.json"
CONFIG_BACKUP="$OPENCLAW_DIR/openclaw.json.watchdog-backup"
PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"

# Auto-detect port from config (use jq if available, fallback to python3, then default)
if command -v jq &>/dev/null; then
  PORT=$(jq -r '.gateway.port // 18789' "$CONFIG" 2>/dev/null || echo 18789)
else
  PORT=$(python3 -c "import json; d=json.load(open('$CONFIG')); print(d.get('gateway',{}).get('port',18789))" 2>/dev/null || echo 18789)
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

log_event() {
  local problem=$1
  local action=$2
  local result=$3
  echo "$(date '+%Y-%m-%d %H:%M:%S') [问题] $problem | [措施] $action | [结果] $result" >> "$LOG"
}

# Log rotation: if log > 5MB, truncate oldest content
rotate_if_needed() {
  local file=$1
  local max_bytes=$((5 * 1024 * 1024))
  local size
  # macOS: stat -f%z, Linux: stat -c%s
  if stat -f%z "$file" &>/dev/null; then
    size=$(stat -f%z "$file" 2>/dev/null || echo 0)
  else
    size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  fi
  if [ -f "$file" ] && [ "$size" -gt "$max_bytes" ]; then
    tail -c $((1 * 1024 * 1024)) "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    log_event "日志文件超过5MB: $file" "截断保留最新1MB" "完成"
  fi
}

rotate_if_needed "$LOG_DIR/gateway.log"
rotate_if_needed "$LOG_DIR/gateway.err.log"

STATUS=$($OPENCLAW gateway status 2>&1)

# Process alive and RPC ok — check model validity then backup
if echo "$STATUS" | grep -q "Runtime: running"; then
  if echo "$STATUS" | grep -q "RPC probe: ok"; then
    # Validate default model is in allowed list
    MODEL_CHECK=$($OPENCLAW models status --json 2>/dev/null | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  default=d.get('defaultModel','')
  allowed=d.get('allowed',[])
  print('ok' if default in allowed else 'invalid:'+default)
except: print('ok')
" 2>/dev/null)
    if echo "$MODEL_CHECK" | grep -q "^invalid:"; then
      BAD_MODEL=$(echo "$MODEL_CHECK" | sed 's/^invalid://')
      # Rollback config to last known-good
      if [ -f "$CONFIG_BACKUP" ]; then
        cp "$CONFIG_BACKUP" "$CONFIG"
        $OPENCLAW gateway restart >> "$LOG" 2>&1
        sleep 4
        log_event "默认模型不存在: $BAD_MODEL" "回滚配置并重启网关" "成功"
      else
        log_event "默认模型不存在: $BAD_MODEL" "无备份可回滚" "失败，需人工介入"
      fi
    else
      # All good — save known-good config backup
      cp "$CONFIG" "$CONFIG_BACKUP" 2>/dev/null
    fi
    exit 0
  fi

  # RPC failed — restart first, only run doctor --fix if restart doesn't help
  $OPENCLAW gateway restart >> "$LOG" 2>&1
  sleep 5
  CHECK=$($OPENCLAW gateway status 2>&1)
  if echo "$CHECK" | grep -q "RPC probe: ok"; then
    log_event "进程运行但RPC无响应" "重启网关" "成功"
  else
    # Restart alone didn't fix it — try doctor --fix then restart again
    $OPENCLAW doctor --fix >> "$LOG" 2>&1
    $OPENCLAW gateway restart >> "$LOG" 2>&1
    sleep 5
    CHECK=$($OPENCLAW gateway status 2>&1)
    if echo "$CHECK" | grep -q "RPC probe: ok"; then
      log_event "进程运行但RPC无响应" "doctor --fix后重启网关" "成功"
    else
      log_event "进程运行但RPC无响应" "doctor --fix后重启网关" "失败，RPC仍不通"
    fi
  fi

else
  # Process not running
  PORT_PID=$(lsof -ti :$PORT 2>/dev/null | head -1)
  if [ -n "$PORT_PID" ]; then
    # Graceful kill first, then force kill if needed
    kill -15 "$PORT_PID" 2>/dev/null
    sleep 2
    if kill -0 "$PORT_PID" 2>/dev/null; then
      kill -9 "$PORT_PID" 2>/dev/null
      sleep 1
    fi
    $OPENCLAW gateway start >> "$LOG" 2>&1
    sleep 3
    CHECK=$($OPENCLAW gateway status 2>&1)
    if echo "$CHECK" | grep -q "Runtime: running"; then
      log_event "进程未运行，端口$PORT被PID $PORT_PID占用" "强杀占用进程并启动网关" "成功"
    else
      log_event "进程未运行，端口$PORT被PID $PORT_PID占用" "强杀占用进程并启动网关" "失败，进程仍未启动"
    fi
  else
    # Check if launchd service is loaded
    if echo "$STATUS" | grep -q "service not loaded\|Service not installed\|not loaded"; then
      launchctl bootstrap gui/$UID "$PLIST" >> "$LOG" 2>&1
      sleep 2
    fi
    $OPENCLAW gateway start >> "$LOG" 2>&1
    sleep 3
    CHECK=$($OPENCLAW gateway status 2>&1)
    if echo "$CHECK" | grep -q "Runtime: running"; then
      log_event "进程未运行" "重新加载LaunchAgent并启动网关" "成功"
    else
      # Try doctor --fix first
      $OPENCLAW doctor --fix >> "$LOG" 2>&1
      $OPENCLAW gateway restart >> "$LOG" 2>&1
      sleep 5
      CHECK2=$($OPENCLAW gateway status 2>&1)
      if echo "$CHECK2" | grep -q "Runtime: running"; then
        log_event "进程未运行，配置异常" "doctor --fix后重启网关" "成功"
      else
        # Rollback to last known-good config
        if [ -f "$CONFIG_BACKUP" ]; then
          cp "$CONFIG_BACKUP" "$CONFIG"
          $OPENCLAW gateway restart >> "$LOG" 2>&1
          sleep 5
          CHECK3=$($OPENCLAW gateway status 2>&1)
          if echo "$CHECK3" | grep -q "Runtime: running"; then
            log_event "进程未运行，配置异常" "回滚配置并重启网关" "成功"
          else
            log_event "进程未运行，配置异常" "回滚配置并重启网关" "失败，需人工介入"
          fi
        else
          log_event "进程未运行，配置异常" "doctor --fix后重启网关" "失败，无备份可回滚，需人工介入"
        fi
      fi
    fi
  fi
fi

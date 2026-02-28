#!/bin/bash
set -euo pipefail

SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gateway-watchdog.sh"

TEST_TMP_ROOT=""
PASS_COUNT=0
FAIL_COUNT=0

fail() {
  local msg="$1"
  echo "[FAIL] $msg"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  local msg="$1"
  echo "[PASS] $msg"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$msg (expected=$expected actual=$actual)"
    return 1
  fi
}

assert_file_contains() {
  local file="$1"
  local text="$2"
  local msg="$3"
  if ! grep -Fq "$text" "$file" 2>/dev/null; then
    fail "$msg (missing: $text)"
    return 1
  fi
}

assert_file_not_contains() {
  local file="$1"
  local text="$2"
  local msg="$3"
  if grep -Fq "$text" "$file" 2>/dev/null; then
    fail "$msg (unexpected: $text)"
    return 1
  fi
}

count_file_value() {
  local file="$1"
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo 0
  fi
}

set_listener_state() {
  local listening="$1"
  local pid="$2"
  local cmd="$3"
  local http="$4"
  cat > "$MOCK_STATE/listener.state" <<EOL
listening=$listening
pid=$pid
cmd=$cmd
http=$http
EOL
}

write_valid_config() {
  local port="${1:-18789}"
  cat > "$HOME/.openclaw/openclaw.json" <<EOL
{
  "gateway": {"port": $port},
  "agents": {"defaults": {"typingMode": "message"}}
}
EOL
}

install_mocks() {
  mkdir -p "$HOME/.local/bin" "$MOCK_STATE"

  cat > "$HOME/.local/bin/openclaw" <<'EOL'
#!/bin/bash
set -euo pipefail
mkdir -p "$MOCK_STATE"
echo "openclaw $*" >> "$MOCK_STATE/events.log"

bump() {
  local file="$1"
  local n=0
  if [ -f "$file" ]; then
    n=$(cat "$file")
  fi
  echo $((n + 1)) > "$file"
}

write_default_listener() {
  cat > "$MOCK_STATE/listener.state" <<EOF_STATE
listening=1
pid=42424
cmd=openclaw-gateway
http=1
EOF_STATE
}

cmd1="${1:-}"
cmd2="${2:-}"
cmd3="${3:-}"

if [ "$cmd1" = "doctor" ] && [ "$cmd2" = "--fix" ]; then
  bump "$MOCK_STATE/doctor_count"
  if [ -f "$MOCK_STATE/doctor_fix_config" ]; then
    cat "$MOCK_STATE/doctor_fix_config" > "$HOME/.openclaw/openclaw.json"
  fi
  if [ -f "$MOCK_STATE/doctor_exit_code" ]; then
    exit "$(cat "$MOCK_STATE/doctor_exit_code")"
  fi
  exit 0
fi

if [ "$cmd1" = "gateway" ] && [ "$cmd2" = "start" ]; then
  bump "$MOCK_STATE/start_count"
  if [ -f "$MOCK_STATE/start_delay_sec" ]; then
    /bin/sleep "$(cat "$MOCK_STATE/start_delay_sec")"
  fi
  if [ -f "$MOCK_STATE/start_exit_code" ]; then
    ec="$(cat "$MOCK_STATE/start_exit_code")"
  else
    ec=0
  fi
  if [ "$ec" -eq 0 ]; then
    if [ -f "$MOCK_STATE/start_listener.state" ]; then
      cat "$MOCK_STATE/start_listener.state" > "$MOCK_STATE/listener.state"
    else
      write_default_listener
    fi
  fi
  exit "$ec"
fi

if [ "$cmd1" = "gateway" ] && [ "$cmd2" = "restart" ]; then
  bump "$MOCK_STATE/restart_count"
  if [ -f "$MOCK_STATE/restart_exit_code" ]; then
    ec="$(cat "$MOCK_STATE/restart_exit_code")"
  else
    ec=0
  fi
  if [ "$ec" -eq 0 ]; then
    if [ -f "$MOCK_STATE/restart_listener.state" ]; then
      cat "$MOCK_STATE/restart_listener.state" > "$MOCK_STATE/listener.state"
    else
      write_default_listener
    fi
  fi
  exit "$ec"
fi

exit 0
EOL

  cat > "$HOME/.local/bin/lsof" <<'EOL'
#!/bin/bash
set -euo pipefail
state="$MOCK_STATE/listener.state"
if [ -f "$state" ]; then
  . "$state"
  if [ "${listening:-0}" = "1" ]; then
    echo "p${pid:-0}"
  fi
fi
EOL

  cat > "$HOME/.local/bin/ps" <<'EOL'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "-p" ] && [ "${3:-}" = "-o" ]; then
  req_pid="${2:-}"
  state="$MOCK_STATE/listener.state"
  if [ -f "$state" ]; then
    . "$state"
    if [ "${pid:-}" = "$req_pid" ]; then
      echo "${cmd:-}"
    fi
  fi
  exit 0
fi

if [ "${1:-}" = "-axo" ]; then
  if [ -f "$MOCK_STATE/ps_axo.out" ]; then
    cat "$MOCK_STATE/ps_axo.out"
  fi
  exit 0
fi

/bin/ps "$@"
EOL

  cat > "$HOME/.local/bin/curl" <<'EOL'
#!/bin/bash
set -euo pipefail
state="$MOCK_STATE/listener.state"
if [ -f "$state" ]; then
  . "$state"
  if [ "${listening:-0}" = "1" ] && [ "${http:-0}" = "1" ]; then
    printf '200'
    exit 0
  fi
fi
printf '000'
exit 0
EOL

  cat > "$HOME/.local/bin/launchctl" <<'EOL'
#!/bin/bash
set -euo pipefail
echo "launchctl $*" >> "$MOCK_STATE/events.log"
cmd="${1:-}"
if [ "$cmd" = "print" ]; then
  if [ -f "$MOCK_STATE/service_loaded" ]; then
    exit 0
  fi
  exit 1
fi
if [ "$cmd" = "bootstrap" ]; then
  : > "$MOCK_STATE/service_loaded"
  if [ -f "$MOCK_STATE/bootstrap_exit_code" ]; then
    exit "$(cat "$MOCK_STATE/bootstrap_exit_code")"
  fi
  exit 0
fi
if [ "$cmd" = "kickstart" ]; then
  if [ -f "$MOCK_STATE/kickstart_exit_code" ]; then
    exit "$(cat "$MOCK_STATE/kickstart_exit_code")"
  fi
  exit 0
fi
exit 0
EOL

  cat > "$HOME/.local/bin/sleep" <<'EOL'
#!/bin/bash
# Speed up tests; watchdog retry loops become near-instant.
exit 0
EOL

  chmod +x "$HOME/.local/bin/openclaw" \
    "$HOME/.local/bin/lsof" \
    "$HOME/.local/bin/ps" \
    "$HOME/.local/bin/curl" \
    "$HOME/.local/bin/launchctl" \
    "$HOME/.local/bin/sleep"
}

setup_case() {
  TEST_TMP_ROOT="$(mktemp -d)"
  export HOME="$TEST_TMP_ROOT/home"
  export MOCK_STATE="$TEST_TMP_ROOT/mock"
  mkdir -p "$HOME/.openclaw/logs" "$HOME/.openclaw/.watchdog" "$MOCK_STATE"
  install_mocks
  write_valid_config
}

teardown_case() {
  if [ -n "${TEST_TMP_ROOT:-}" ] && [ -d "$TEST_TMP_ROOT" ]; then
    rm -rf "$TEST_TMP_ROOT"
  fi
}

run_watchdog() {
  HOME="$HOME" MOCK_STATE="$MOCK_STATE" bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1
}

run_test() {
  local name="$1"
  local fn="$2"
  setup_case
  if "$fn"; then
    pass "$name"
  else
    fail "$name"
  fi
  teardown_case
}

test_healthy_path() {
  set_listener_state 1 11111 openclaw-gateway 1
  run_watchdog

  local starts
  starts=$(count_file_value "$MOCK_STATE/start_count")
  assert_eq 0 "$starts" "healthy path should not trigger start"

  [ -f "$HOME/.openclaw/openclaw.json.watchdog-backup" ] || {
    fail "healthy path should refresh backup"
    return 1
  }

  local log_file="$HOME/.openclaw/logs/watchdog.log"
  assert_file_not_contains "$log_file" "[问题]" "healthy path should stay silent"
}

test_no_listener_then_start() {
  set_listener_state 0 0 none 0
  run_watchdog

  local starts
  starts=$(count_file_value "$MOCK_STATE/start_count")
  assert_eq 1 "$starts" "no listener should trigger one start"

  local log_file="$HOME/.openclaw/logs/watchdog.log"
  assert_file_contains "$log_file" "网关端口18789未监听" "should log missing listener recovery"
  assert_file_contains "$log_file" "成功" "recovery should succeed"
}

test_conflict_listener_killed_and_restarted() {
  set_listener_state 1 999999 python-http-server 1
  run_watchdog

  local starts
  starts=$(count_file_value "$MOCK_STATE/start_count")
  assert_eq 1 "$starts" "conflict listener should trigger start"

  local log_file="$HOME/.openclaw/logs/watchdog.log"
  assert_file_contains "$log_file" "被非网关进程占用" "should log port conflict"
  assert_file_contains "$log_file" "清理占用并启动网关" "should log conflict action"
}

test_invalid_config_doctor_fix() {
  cat > "$HOME/.openclaw/openclaw.json" <<'EOL'
{ invalid json }
EOL

  cat > "$MOCK_STATE/doctor_fix_config" <<'EOL'
{
  "gateway": {"port": 18789},
  "agents": {"defaults": {"typingMode": "message"}}
}
EOL

  set_listener_state 0 0 none 0
  run_watchdog

  local doctors
  doctors=$(count_file_value "$MOCK_STATE/doctor_count")
  assert_eq 1 "$doctors" "invalid config should invoke doctor"

  local log_file="$HOME/.openclaw/logs/watchdog.log"
  assert_file_contains "$log_file" "doctor --fix/自动修正" "doctor fix should be logged"
}

test_invalid_config_rollback_backup() {
  cat > "$HOME/.openclaw/openclaw.json" <<'EOL'
{ invalid json }
EOL

  cat > "$HOME/.openclaw/openclaw.json.watchdog-backup" <<'EOL'
{
  "gateway": {"port": 18888},
  "agents": {"defaults": {"typingMode": "message"}}
}
EOL

  echo 1 > "$MOCK_STATE/doctor_exit_code"
  set_listener_state 0 0 none 0
  run_watchdog

  local cfg_port
  cfg_port=$(jq -r '.gateway.port' "$HOME/.openclaw/openclaw.json")
  assert_eq 18888 "$cfg_port" "should rollback to valid backup"

  local log_file="$HOME/.openclaw/logs/watchdog.log"
  assert_file_contains "$log_file" "回滚到已校验备份" "rollback should be logged"
}

test_stale_lock_recovery() {
  local lock="$HOME/.openclaw/.watchdog/watchdog.lock"
  echo "999999 $(date +%s)" > "$lock"

  set_listener_state 0 0 none 0
  run_watchdog

  local log_file="$HOME/.openclaw/logs/watchdog.log"
  assert_file_contains "$log_file" "检测到死锁进程" "dead lock should be cleaned"
}

test_without_jq_fallback() {
  cat > "$HOME/.local/bin/jq" <<'EOL'
#!/bin/bash
exit 127
EOL
  chmod +x "$HOME/.local/bin/jq"

  set_listener_state 0 0 none 0
  run_watchdog

  local starts
  starts=$(count_file_value "$MOCK_STATE/start_count")
  assert_eq 1 "$starts" "without jq should still recover and start gateway"

  local log_file="$HOME/.openclaw/logs/watchdog.log"
  assert_file_not_contains "$log_file" "检测到当前配置无效" "without jq valid config should not be misdetected"
}

test_concurrency_pressure() {
  set_listener_state 0 0 none 0
  echo "0.2" > "$MOCK_STATE/start_delay_sec"

  local pids=()
  local i
  for i in $(seq 1 60); do
    HOME="$HOME" MOCK_STATE="$MOCK_STATE" bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1 &
    pids+=("$!")
  done

  local failures=0
  for i in "${pids[@]}"; do
    if ! wait "$i"; then
      failures=$((failures + 1))
    fi
  done

  assert_eq 0 "$failures" "all concurrent runs should exit successfully"

  local starts
  starts=$(count_file_value "$MOCK_STATE/start_count")
  if [ "$starts" -gt 2 ]; then
    fail "lock should limit starts under pressure (actual starts=$starts)"
    return 1
  fi
}

main() {
  run_test "healthy_path" test_healthy_path
  run_test "no_listener_then_start" test_no_listener_then_start
  run_test "conflict_listener_restart" test_conflict_listener_killed_and_restarted
  run_test "invalid_config_doctor_fix" test_invalid_config_doctor_fix
  run_test "invalid_config_rollback_backup" test_invalid_config_rollback_backup
  run_test "stale_lock_recovery" test_stale_lock_recovery
  run_test "without_jq_fallback" test_without_jq_fallback
  run_test "concurrency_pressure" test_concurrency_pressure

  echo "----"
  echo "Pass: $PASS_COUNT"
  echo "Fail: $FAIL_COUNT"

  if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
  fi
}

main "$@"

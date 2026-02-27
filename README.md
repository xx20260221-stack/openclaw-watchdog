# openclaw-watchdog

A cron-based watchdog script for [OpenClaw](https://openclaw.ai) gateway. Runs independently of the OpenClaw process to detect and recover from failures automatically.

## Features

- Restarts gateway if process is dead or RPC probe fails
- Re-bootstraps LaunchAgent if launchd service is unloaded
- Kills port conflicts before starting
- Runs `openclaw doctor --fix` to auto-repair invalid config keys
- Rolls back to last known-good config if startup keeps failing
- Detects invalid default model and rolls back config
- Rotates gateway logs when they exceed 5MB
- Logs all detected problems, actions taken, and results

## Requirements

- macOS (uses launchd/launchctl)
- OpenClaw installed and configured
- Python 3 (pre-installed on macOS)

## Installation

```bash
# 1. Copy script to your preferred location
cp gateway-watchdog.sh ~/.openclaw/workspace/scripts/

# 2. Make it executable
chmod +x ~/.openclaw/workspace/scripts/gateway-watchdog.sh

# 3. Add to crontab (runs every minute)
(crontab -l 2>/dev/null; echo "* * * * * /bin/bash ~/.openclaw/workspace/scripts/gateway-watchdog.sh") | crontab -
```

## Log

All watchdog events are written to `~/.openclaw/logs/watchdog.log`:

```
2026-02-27 11:36:32 [问题] 进程运行但RPC无响应 | [措施] 重启网关 | [结果] 成功
2026-02-27 12:08:46 [问题] 进程未运行，配置异常 | [措施] doctor --fix后重启网关 | [结果] 成功
2026-02-27 12:16:31 [问题] 默认模型不存在: xxx | [措施] 回滚配置并重启网关 | [结果] 成功
```

Only failures and recoveries are logged. Normal operation is silent.

## Recovery Flow

```
Gateway down?
├── Port conflict → kill occupying process → start
├── LaunchAgent not loaded → bootstrap → start
├── Start failed → doctor --fix → restart
└── Still failed → rollback to last known-good config → restart

Gateway up but RPC failed?
└── restart

Gateway up and RPC ok?
├── Default model not in allowed list → rollback config → restart
└── All good → save known-good config backup
```

## Notes

- Does **not** run as an OpenClaw skill — intentionally decoupled so it works even when the OpenClaw process is completely dead
- Config backup is saved to `~/.openclaw/openclaw.json.watchdog-backup` on every healthy check
- All paths are auto-detected from `$HOME` and `$PATH`, no hardcoded user paths

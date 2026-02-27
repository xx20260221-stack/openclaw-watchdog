# openclaw-watchdog

[OpenClaw](https://openclaw.ai) 网关保活脚本。通过 cron 独立于 OpenClaw 进程运行，自动检测并恢复各类故障。

## 功能

- 进程崩溃后自动重启网关
- launchd 服务未加载时自动重新注册并启动
- 端口被其他进程占用时强杀后重启
- 配置存在无效字段时自动运行 `openclaw doctor --fix` 修复
- 修复失败时自动回滚到上次正常运行的配置备份
- 检测默认模型是否有效，无效时自动回滚配置
- 网关日志超过 5MB 时自动截断
- 所有检测到的问题、采取的措施、处理结果均记录到日志

## 环境要求

- macOS（依赖 launchd/launchctl）
- 已安装并配置好 OpenClaw
- Python 3（macOS 自带）

## 安装

```bash
# 1. 将脚本放到合适的位置
cp gateway-watchdog.sh ~/.openclaw/workspace/scripts/

# 2. 添加执行权限
chmod +x ~/.openclaw/workspace/scripts/gateway-watchdog.sh

# 3. 加入 crontab（每分钟执行一次）
(crontab -l 2>/dev/null; echo "* * * * * /bin/bash ~/.openclaw/workspace/scripts/gateway-watchdog.sh") | crontab -
```

## 日志

所有 watchdog 事件写入 `~/.openclaw/logs/watchdog.log`：

```
2026-02-27 11:36:32 [问题] 进程运行但RPC无响应 | [措施] 重启网关 | [结果] 成功
2026-02-27 12:08:46 [问题] 进程未运行，配置异常 | [措施] doctor --fix后重启网关 | [结果] 成功
2026-02-27 12:16:31 [问题] 默认模型不存在: xxx | [措施] 回滚配置并重启网关 | [结果] 成功
```

正常运行时静默不写日志，只有检测到异常才记录。

## 恢复流程

```
网关挂了？
├── 端口被占用 → 强杀占用进程 → 启动
├── LaunchAgent 未加载 → bootstrap → 启动
├── 启动失败 → doctor --fix → 重启
└── 仍然失败 → 回滚到上次正常配置 → 重启

网关运行但 RPC 无响应？
└── 重启网关

网关运行且 RPC 正常？
├── 默认模型不在可用列表 → 回滚配置 → 重启
└── 一切正常 → 保存当前配置为备份
```

## 备注

- 脚本**不作为 OpenClaw skill 运行**，刻意与 OpenClaw 进程解耦，确保进程完全挂掉时 watchdog 仍然有效
- 每次健康检测通过时，自动将当前配置备份到 `~/.openclaw/openclaw.json.watchdog-backup`
- 所有路径基于 `$HOME` 和 `$PATH` 自动推导，无硬编码用户路径，可直接给其他人使用

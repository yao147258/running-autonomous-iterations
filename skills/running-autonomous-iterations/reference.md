# autopilot.sh 行为参考

## 目录结构（项目内）

```
.autopilot/                 # 已写入 .git/info/exclude，不进入提交，git reset/clean 不影响
  autopilot.sh              # 调度脚本（只读）
  iteration-prompt.md       # 每轮协议（只读）
  config.sh                 # 运行参数（只读）
  secrets.sh                # BARK_URL（只读，AI 禁止读取）
  GOALS.md                  # 目标与验收标准（只读）
  verify.sh                 # 验收脚本（只读）
  TASKS.md                  # 里程碑与任务（AI 维护）
  PROGRESS.md               # 工作日志，只追加（AI 与脚本共同写）
  NEEDS_HUMAN.md            # 待人工处理（AI 追加，人处理）
  state.json / history.tsv  # 机器状态 / 每轮记录
  last-verify.txt           # 最近一次 verify 输出
  logs/                     # autopilot.log、notify.log、每轮的 prompt / jsonl / stderr
  REPORT.md                 # 结束时生成
  DONE / STUCK / STOP       # 结束标记
```

"只读"由两层保证：claude 的 `--disallowedTools` 规则，以及每轮结束后的哈希校验（被改则从备份恢复；第二次被改直接停机）。

## 主循环

```
启动：登记受保护文件哈希 → 跑一次 verify 作为基线 → 通知 start
循环：
  STOP → 结束 | 超出轮数/运行时长上限 → STUCK
  不在窗口内，或剩余时间 < END_GRACE_MIN → 发时段小结 → 休眠到下个窗口（休眠中可被 STOP 打断）
  处于出错退避期 → 休眠
  单轮：截止时间 = min(单轮超时, 窗口剩余时间)
        claude -p（全新上下文）→ 超时则终止整个进程树
        清理现场 → 防篡改校验 → 脚本运行 verify → 记录 history
        → 进展判定 → 里程碑/任务/待人工通知 → 生成下一轮特别提示
        → verify 全过则 DONE；无进展超过阈值则 STUCK
```

## 每轮结束后的现场处理

| 情况 | 处理 |
|---|---|
| 已提交的内容（包括轮内小步提交） | 全部保留 |
| 未提交的改动（超时、出错或忘记提交） | 保存到 `refs/autopilot/wip/iter-N`，然后 `reset --hard HEAD` 加 `clean -fd`，工作区回到干净状态 |
| 切换了分支 | 切回 `AUTOPILOT_BRANCH` |
| 残留的 `index.lock` | 删除 |
| 被 .gitignore 忽略的文件 | 不会被保存，也不会被删除（协议要求不要把重要产物放在这类路径） |

下一轮的提示会写明 WIP 引用和改动统计，由 AI 决定 cherry-pick 继续还是放弃。连续 2 轮超时，会强制要求先拆分任务。

## 进展与卡住判定

- **进展**：verify 通过数创新高，则两个计数器都清零。
- **无进展（no_progress）**：分数没有创新高，并且没有新提交（超时也算无进展）。
  - 达到 `STRATEGY_SWITCH_AFTER`：要求换策略
  - 达到 `STUCK_AFTER`：停机
- **平台期（plateau）**：分数没有创新高的连续轮数（有提交也算）。
  - 达到 `PLATEAU_SWITCH_AFTER`：要求换策略
  - 达到 `PLATEAU_STUCK_AFTER`：停机
- **出错**（claude 非 0 退出或 `is_error`，常见原因是额度用尽或限流）：不计入无进展，按 5、10、20、40、60 分钟退避重试。连续达到 `MAX_CONSECUTIVE_ERRORS` 次则停机。
- **回退**：本轮 verify 分数低于上一轮，下一轮的提示会要求优先修复。

## 里程碑判定

- TASKS.md 中的标题格式为 `## M1 名称 [todo|doing|done]`。
- **开始**：标题状态从 `[todo]` 变为 `[doing]`。
- **完成**：verify 中带该 ID 的检查全部 PASS。只有当这个里程碑没有任何检查时，才以 TASKS.md 标为 `[done]` 为准。
- **回退**：已完成的里程碑又出现 FAIL。
- **不一致**：TASKS.md 标了 `[done]`，但 verify 没有全部通过。下一轮会被要求改回 `[doing]`。

## 通知事件（Bark）

| 事件 | 时机 | 级别 | 默认开启 |
|---|---|---|---|
| start | 脚本启动 | active | ✓ |
| window_start | 进入可运行时段 | passive | |
| window_end | 时段结束时的小结（轮数、分数变化、里程碑、超时、待人工） | active | ✓ |
| progress | verify 分数创新高 | passive | |
| milestone_start / milestone_done | 里程碑开始 / 完成 | active | ✓ |
| milestone_regress | 已完成的里程碑出现回退 | timeSensitive | ✓ |
| task_done | 单个任务被勾选 | passive | |
| timeout | 单轮超时 | active | ✓ |
| strategy | 要求换策略 | active | |
| need_human | NEEDS_HUMAN.md 新增未处理项 | timeSensitive | ✓ |
| error | claude 连续出错，每满 3 次通知一次 | active | ✓ |
| done / stuck / stop | 结束 | timeSensitive / timeSensitive / active | ✓ |
| crash | 调度脚本异常退出 | timeSensitive | ✓ |

- 请求方式：`POST $BARK_URL`，JSON 字段为 `title`、`body`、`group`、`level`。payload 通过文件传给 curl，避免 Windows 下中文参数乱码。
- 同一事件加同一标题，10 分钟内只发一次。发送失败只记录到 `logs/notify.log`，不影响主流程。

## claude 调用方式

```
claude -p --output-format stream-json --verbose --permission-mode dontAsk
  --append-system-prompt "无人值守……使用 Bash 工具"
  --allowedTools Read Edit Write Glob Grep Bash TodoWrite NotebookEdit WebSearch WebFetch Agent
  --disallowedTools <禁用规则> [--model $CLAUDE_MODEL] < 本轮提示
```

- `dontAsk` 模式下，没有预先允许的操作一律拒绝，不会卡在权限确认上。
- 禁用规则包括：push、reset、rebase、clean、checkout、switch、stash、`branch -D`、`update-ref`、`config`、`rm -r*`、各类 publish、curl、wget、taskkill、PowerShell，以及对受保护文件和 `PROTECTED_PATHS` 的 Edit/Write。可以用 `EXTRA_DISALLOWED_TOOLS` 追加。
- 已实测（Bash 工具可用的前提下）：`git push`、`cd . && git push`、`rm -rf`、`git checkout` 都会被拦截。PowerShell 被整体禁用，迫使 AI 使用 Bash 工具，这样禁用规则才能生效。
- Windows 上 headless claude 只有在设置了 `CLAUDE_CODE_GIT_BASH_PATH` 时才提供 Bash 工具，脚本会自动设置。每轮还会检查 init 消息里的工具列表，缺少 Bash 就按出错处理并说明原因，避免 AI 绕道子代理执行命令。
- 禁用规则是第一道防线，git 检查点和哈希校验是兜底。真正不可逆的风险（生产数据库、密钥）不要放在 AI 能接触到的环境里。

## Windows / Git Bash 注意事项

- **时区**：Git Bash 的 TZ 常常是 MSYS 不认识的值，会悄悄回退成 UTC。脚本会通过 PowerShell 读取系统的 UTC 偏移，换算成 `UTC-8:00` 这样的形式。也可以在 config 中写死 `WINDOW_TZ`。
- **进程树**：用 `set -m` 让 claude 拥有独立的进程组，超时时同时执行 `taskkill //T //F` 和 `kill -- -PGID`。
- **睡眠**：需要插电不睡眠（`powercfg /change standby-timeout-ac 0`），否则脚本会整晚停住。
- **别名**：交互式 shell 里的别名（如 `cp`）可能被改写过。部署文件时用 `command cp`。脚本本身不受别名影响。
- **后台运行**：`start` 通过 `nohup … & disown` 启动，关闭终端或 Claude Code 会话都不影响。
- **停止方式**：只用 `autopilot.sh stop`。强制杀掉调度脚本（SIGKILL 或任务管理器）会跳过清理逻辑，正在运行的 claude 会变成孤儿进程。运行期间不要删除 `state.json` 等状态文件。

## 测试

`tests/e2e.sh` 用 `tests/fake-claude.sh` 模拟每一轮，把时间单位压缩成秒，覆盖以下场景：check、完整流程（进展、超时、遗留改动、里程碑、完成）、防篡改、受保护路径、卡住检测、出错退避、缺少 Bash 工具、窗口外休眠、窗口结束硬截止。

```bash
bash tests/e2e.sh            # 全部用例
bash tests/e2e.sh window     # 单个用例
```

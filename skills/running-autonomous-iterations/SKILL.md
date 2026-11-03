---
name: running-autonomous-iterations
description: Use when the user gives one or more goals and wants the AI to keep working unattended for many hours or several days (overnight runs, 自主迭代, 长时任务, 无人值守, 挂机跑, 跑一整晚, 自己迭代直到完成), optionally restricted to time windows such as 22:00-08:00, with progress/milestone notifications (Bark) — mainly for coding goals in a git repository.
---

# 长时自主迭代（Autonomous Iterations）

## 概述

用外部脚本循环调用 `claude -p`，**每一轮都是全新上下文、只做一个小任务**，轮与轮之间完全靠磁盘状态衔接；完成与否只由客观的 `verify.sh` 判定。

本 skill 自带经过端到端测试的调度脚本 `scripts/autopilot.sh`。**必须使用它，不要现场手写循环脚本**——手写版本在测试中反复踩坑：Git Bash 时区偏移导致时间窗口错 8 小时、超时后直接 reset 丢失半成品、杀不干净进程树、窗口结束就退出无法跨夜续跑。

你（交互式会话）的职责是**阶段一：和用户一起把目标固化成可验证的形式，然后启动**。之后的无人值守循环由脚本负责。

## 何时使用

- 用户希望 AI 连续数小时 / 数天自主推进一个或多个目标，不想盯着
- 需要只在某些时段运行（如夜间）、需要手机通知进度
- 目标可以被测试 / 构建 / 脚本客观验证（主要是写代码）

**不适用**：几分钟能做完的任务；无法客观验收的纯主观任务（先和用户把它转成可检查的标准，转不了就别用）；不是 git 仓库且用户不愿初始化。

## 阶段一：启动准备（逐项完成，每项都要用户确认）

用 TodoWrite 为下面每一步建一个待办。

1. **理解目标**：读代码库，把用户目标拆成 3–10 条验收标准，按模块分成里程碑 M1、M2…
2. **安全基线**：工作区必须干净；创建并切到独立分支（如 `autopilot/20260103`），之后的提交都在这个分支上
3. **写验收测试**（最关键的一步，不要为了赶时间压缩）：
   - 把每条标准落成可执行检查；尽量细粒度，让分数能随进展逐步上升（分数长期不涨会被判定卡住）
   - 人工确认过的验收测试放进独立目录（如 `tests/acceptance/`），提交，并列入 `PROTECTED_PATHS`
   - 加上防削弱检查：全量测试通过、构建通过、`check_absent` 禁止 skip/only 等
4. **部署文件**：在项目根目录执行（用 `command cp` 避开用户 shell 里的 cp 别名）：
   ```bash
   mkdir -p .autopilot
   command cp "${CLAUDE_SKILL_DIR}"/scripts/{autopilot.sh,iteration-prompt.md} .autopilot/
   command cp "${CLAUDE_SKILL_DIR}"/templates/{config.sh,GOALS.md,TASKS.md,verify.sh,PROGRESS.md,NEEDS_HUMAN.md} .autopilot/
   ```
5. **填写**：
   - `GOALS.md`：目标、约束、无人值守时的默认决策、验收标准表、受保护路径
   - `TASKS.md`：里程碑标题必须是 `## M1 名称 [todo]` 格式，任务用 `- [ ]`
   - `verify.sh`：每行输出 `PASS|FAIL <里程碑ID|-> <检查名>`，里程碑 ID 必须与 TASKS.md 对应
6. **配置 `config.sh`**，逐项和用户确认：`AUTOPILOT_BRANCH`、时间窗口 `TIME_WINDOWS`、单轮超时、预算上限、`PROTECTED_PATHS`、模型
7. **通知（可选）**：询问是否开启 Bark。开启时把 URL 写进 `.autopilot/secrets.sh`（`BARK_URL="https://api.day.app/<key>"`），设 `NOTIFY_ENABLED=true`，运行 `bash .autopilot/autopilot.sh notify-test`，**等用户确认手机收到**
8. **检查**：`bash .autopilot/autopilot.sh check` 必须显示"检查通过"，并请用户核对其中显示的"当前时间"是否为本地时间。verify 一开始就全部通过，说明标准太松，回到第 3 步
9. **启动**：`bash .autopilot/autopilot.sh start`，然后把下面的"查看与控制"命令告诉用户

## 查看与控制

| 操作 | 命令 |
|---|---|
| 状态总览 | `bash .autopilot/autopilot.sh status` |
| 工作日志 | `tail -n 40 .autopilot/PROGRESS.md` |
| 优雅停止 | `bash .autopilot/autopilot.sh stop` |
| 停止后续跑 | `bash .autopilot/autopilot.sh start` |
| 刷新报告 | `bash .autopilot/autopilot.sh report` → `.autopilot/REPORT.md` |
| 修改目标 | 先 stop → 修改 GOALS / verify / config → `check` → `start` |

结束标记：`.autopilot/DONE`（verify 全部通过）、`.autopilot/STUCK`（原因写在文件里）。用户回来后，引导他看 `REPORT.md`、亲自跑一次 `verify.sh`、审阅 `git diff`，**由用户自己合并分支**。处理完 STUCK 原因后，删除该文件即可重新 `start`。

脚本行为（超时保存 WIP、卡住检测、防篡改、通知事件等）的完整说明见 `reference.md`。

## 常见错误

| 错误 | 后果 | 正确做法 |
|---|---|---|
| 现场手写循环脚本 | 时区、进程树、WIP、跨夜续跑全部要重新踩坑 | 复制使用 `scripts/autopilot.sh` |
| 验收测试由 AI 在运行中自己写 | AI 写出能过的弱测试，"完成"失去意义 | 阶段一写好、用户确认、列入 PROTECTED_PATHS |
| 只有一条粗粒度检查（如"全部测试通过"） | 分数长期 0/1，被误判卡住 | 每个里程碑拆成多条检查 |
| 用 `date +%H` 自己判断时间窗口 | Git Bash 下 TZ 常为 UTC，窗口错位 | 用脚本的 `TIME_WINDOWS`，并在 check 中核对时间 |
| 在 main 上运行 | 无法整体回滚和审阅 | 独立分支 + 用户自己合并 |
| Bark key 写进 config.sh 或仓库 | 密钥泄露 | 写入 `.autopilot/secrets.sh`（已被本地忽略）或环境变量 |
| 跳过 notify-test | 整晚收不到通知才发现配错 | 启动前必须测试，等用户确认 |
| 电脑夜间睡眠 | 脚本整晚停住 | 提醒用户设置插电不睡眠 |

## 不要这样合理化

| 想法 | 现实 |
|---|---|
| "用户赶时间，验收标准简单写写就行" | 标准写得弱，后面几个晚上就白跑了；阶段一多花的 30 分钟最值 |
| "我写个简单的 while 循环更快" | 本 skill 的脚本已覆盖手写版本必踩的坑，复制只要几秒 |
| "verify 已经全过了，直接启动吧" | 说明标准没有描述新目标，回到第 3 步 |
| "AI 每轮自己判断是否完成就行" | 只有脚本跑出的 verify 结果算数，这是防止谎称完成的唯一手段 |

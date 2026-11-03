# running-autonomous-iterations

一个 Claude Code skill：给定目标后，让 AI **无人值守地连续运行数小时到数天**，自行迭代直到目标达成。

- **全新上下文逐轮推进**：外部脚本循环调用 `claude -p`，每轮只做一个小任务，靠磁盘状态衔接，不会撑爆上下文
- **客观验收**：完成与否只看 `verify.sh`，AI 自己说完成了不算；验收测试可加锁防篡改
- **时间窗口**：例如只在每晚 22:00–08:00 运行，窗口外自动休眠，第二晚自动续跑
- **工作不丢**：每轮都有 git 提交作为检查点；超时被终止时，半成品保存到 `refs/autopilot/wip/iter-N`
- **卡住检测**：长期无进展时先要求换策略，仍然无效则停机并说明原因
- **安全护栏**：独立分支；禁止 push、改写历史、删目录和发布；受保护文件被改后自动恢复
- **Bark 通知（可选）**：启动、里程碑开始/完成/回退、超时、需要人工处理、时段小结、完成/停机、崩溃

## 安装

### 方式一：插件市场（推荐）

在 Claude Code 中执行：

```
/plugin marketplace add yao147258/running-autonomous-iterations
/plugin install running-autonomous-iterations@running-autonomous-iterations
```

也可以在命令行执行：

```bash
claude plugin marketplace add yao147258/running-autonomous-iterations
claude plugin install running-autonomous-iterations@running-autonomous-iterations
```

安装后重启 Claude Code。更新：

```bash
claude plugin marketplace update running-autonomous-iterations
claude plugin update running-autonomous-iterations@running-autonomous-iterations
```

### 方式二：手动复制

```bash
git clone https://github.com/yao147258/running-autonomous-iterations
cp -r running-autonomous-iterations/skills/running-autonomous-iterations ~/.claude/skills/
```

**依赖**：git、bash（Windows 用 Git Bash）、jq、curl、GNU coreutils（macOS 需要 `brew install coreutils`）、Claude Code CLI。

## 使用

在项目目录里对 Claude Code 说：

> 用自主迭代帮我完成 XXX，只在每晚 22 点到早上 8 点跑，用 Bark 通知我。

skill 会引导完成启动准备：

1. 把目标拆成里程碑和**可执行的验收检查**（`verify.sh`），并请你确认
2. 在项目中生成 `.autopilot/` 目录（该目录只在本地忽略，不会进入提交）
3. 配置时间窗口、超时、预算；开启通知时发送一条测试推送
4. 创建独立分支，运行 `check`，然后在后台 `start`

之后可以用这些命令查看和控制：

```bash
bash .autopilot/autopilot.sh status    # 状态总览
tail -n 40 .autopilot/PROGRESS.md      # 工作日志
bash .autopilot/autopilot.sh stop      # 优雅停止（当前轮结束后）
bash .autopilot/autopilot.sh start     # 继续
bash .autopilot/autopilot.sh report    # 生成 .autopilot/REPORT.md
```

运行结束后会出现 `.autopilot/DONE` 或 `.autopilot/STUCK`。阅读 `REPORT.md`、亲自跑一遍 `verify.sh`、审阅 diff 之后，**由你自己合并分支**。

## 工作原理

```
autopilot.sh（外层调度）
  ├─ 时间窗口判断 → 窗口外休眠，发时段小结
  ├─ 单轮：claude -p（全新上下文）读取 GOALS/TASKS/PROGRESS → 做一个小任务 → 提交 → 写日志
  ├─ 超时：终止进程树 → 未提交改动存入 WIP 引用 → 工作区复原
  ├─ 脚本自己运行 verify.sh → 进展、卡住、里程碑判定 → 通知
  └─ 生成下一轮的特别提示（超时、回退、换策略、状态不一致……）
```

完整行为说明见 [reference.md](skills/running-autonomous-iterations/reference.md)，每轮的执行协议见 [iteration-prompt.md](skills/running-autonomous-iterations/scripts/iteration-prompt.md)。

## 文件

```
.claude-plugin/
  plugin.json                       # 插件清单
  marketplace.json                  # 插件市场清单（本仓库同时是市场和插件）
skills/running-autonomous-iterations/
  SKILL.md                          # skill 入口：启动准备流程
  reference.md                      # 调度脚本行为参考
  scripts/autopilot.sh              # 外层调度脚本
  scripts/iteration-prompt.md       # 每轮协议
  templates/                        # config.sh、GOALS.md、TASKS.md、verify.sh 等模板
tests/e2e.sh                        # 端到端测试（用 fake-claude 模拟，不消耗额度）
```

## 发布新版本

插件更新以版本号为准：内容改了但版本号不变，用户执行 update 时会被认为已是最新版。每次发布：

1. 同时提升 `.claude-plugin/plugin.json` 和 `.claude-plugin/marketplace.json` 中的 `version`
2. 运行 `claude plugin validate --strict .claude-plugin/plugin.json` 和 `bash tests/e2e.sh`
3. 提交并推送

## 测试

```bash
bash tests/e2e.sh
```

测试覆盖：check、完整流程（进展、超时、遗留改动、里程碑、完成）、防篡改、受保护路径、卡住检测、出错退避、缺少 Bash 工具、窗口外休眠、窗口结束硬截止。

## 注意事项

- **Windows**：
  - 脚本会自动设置 `CLAUDE_CODE_GIT_BASH_PATH`，否则 headless claude 只有 PowerShell 工具
  - 脚本会从系统读取时区，修正 Git Bash 的 TZ 偏移
  - 需要设置插电时不睡眠
- **费用**：每轮都是一次完整的 claude 会话。请用 `MAX_ITERATIONS`、`MAX_ACTIVE_HOURS` 控制预算，`REPORT.md` 中会汇总 claude 报告的费用。
- **安全**：禁用规则加上 git 检查点能防住大多数误操作，但不能代替环境隔离。不要让 AI 接触生产数据库或真实密钥。

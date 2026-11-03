# =============================================================================
# 自主迭代运行配置（autopilot.sh 启动时读取；运行期间只读，修改需先停止）
# =============================================================================

# 工作分支：必须是独立分支，不能是 main/master/develop
AUTOPILOT_BRANCH="autopilot/YYYYMMDD"

# ---- 时间窗口 ----
# 只在这些时段内运行；跨午夜直接写 "22:00-08:00"；多段用逗号分隔；留空 = 全天运行
TIME_WINDOWS="22:00-08:00"
# 时区：留空自动识别（Windows 下读取系统时区）；也可写 POSIX 格式，例如东八区写 "UTC-8"
WINDOW_TZ=""
ITER_TIMEOUT_MIN=45          # 单轮最长分钟数（超时强制终止，半成品存入 WIP）
END_GRACE_MIN=30             # 距窗口结束不足该分钟数时不再开新轮
VERIFY_TIMEOUT_MIN=15        # verify.sh 最长分钟数

# ---- 预算上限 ----
MAX_ITERATIONS=200           # 总轮数上限
MAX_ACTIVE_HOURS=60          # 累计实际运行小时数上限（休眠时间不计）
MAX_CONSECUTIVE_ERRORS=10    # claude 连续出错（如额度用尽）次数上限

# ---- 卡住检测 ----
STRATEGY_SWITCH_AFTER=3      # 连续 N 轮无进展（无新提交且 verify 未提升）→ 要求换策略
STUCK_AFTER=6                # 连续 M 轮无进展 → 停机
PLATEAU_SWITCH_AFTER=8       # verify 连续 N 轮未创新高 → 要求换策略
PLATEAU_STUCK_AFTER=20       # verify 连续 M 轮未创新高 → 停机

# ---- 防篡改 ----
# 受保护的仓库路径（验收测试等），空格分隔；AI 修改后会被自动恢复，第二次修改则停机
PROTECTED_PATHS=""

# ---- claude 参数 ----
CLAUDE_MODEL=""              # 留空用默认模型
CLAUDE_EXTRA_ARGS=""         # 例如 "--effort high"
EXTRA_DISALLOWED_TOOLS=""    # 额外禁用规则，用 ; 分隔，例如 "Bash(docker:*);Bash(psql:*)"

# ---- Bark 通知 ----
NOTIFY_ENABLED=false         # 开启后需在 secrets.sh 中配置 BARK_URL
# 可选事件：start window_start window_end progress timeout strategy need_human
#           done stuck stop crash error milestone_start milestone_done milestone_regress task_done
NOTIFY_EVENTS="start,window_end,timeout,need_human,done,stuck,crash,error,milestone_start,milestone_done,milestone_regress,stop"
BARK_GROUP="autopilot"

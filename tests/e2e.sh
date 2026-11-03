#!/usr/bin/env bash
# autopilot.sh 端到端测试：用 fake-claude.sh 模拟每一轮，时间单位压缩为秒
# 用法：bash tests/e2e.sh [用例名...]
set -u
ROOT="$(cd "$(dirname "$0")/../skills/running-autonomous-iterations" && pwd)"
FAKE="$(cd "$(dirname "$0")" && pwd)/fake-claude.sh"
WORK="${TMPDIR:-/tmp}/autopilot-e2e"
META="${WORK}-meta"   # 测试记录放在项目外，避免被 git clean 清掉
PASSED=0; FAILED=0

ok()   { echo "    ✓ $*"; PASSED=$((PASSED+1)); }
bad()  { echo "    ✗ $*"; FAILED=$((FAILED+1)); }
expect() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# 创建一个带 .autopilot 的临时项目；$1 = 追加到 config.sh 的内容
setup() {
  rm -rf "$WORK" "$META"; mkdir -p "$WORK" "$META"; cd "$WORK" || exit 1
  git init -q -b main && git config user.email t@t && git config user.name t && git config core.autocrlf false
  echo "# demo" >README.md && git add -A && git commit -qm init
  git switch -qc autopilot/test
  mkdir .autopilot
  cp "$ROOT"/scripts/autopilot.sh "$ROOT"/scripts/iteration-prompt.md .autopilot/
  cp "$ROOT"/templates/{config.sh,GOALS.md,PROGRESS.md,NEEDS_HUMAN.md} .autopilot/
  cat >.autopilot/TASKS.md <<'EOF'
# 任务清单
## M1 基础功能 [todo]
- [ ] 功能一
- [ ] 功能二
## M2 进阶功能 [todo]
- [ ] 功能三
EOF
  cat >.autopilot/verify.sh <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
for i in 1 2; do [[ -f f$i.txt ]] && echo "PASS M1 f$i" || echo "FAIL M1 f$i"; done
[[ -f f3.txt ]] && echo "PASS M2 f3" || echo "FAIL M2 f3"
EOF
  cat >>.autopilot/config.sh <<EOF
AUTOPILOT_BRANCH="autopilot/test"
TIME_WINDOWS=""
ITER_TIMEOUT_MIN=4
END_GRACE_MIN=0
NOTIFY_ENABLED=true
NOTIFY_EVENTS="start,window_start,window_end,progress,timeout,strategy,need_human,done,stuck,stop,crash,error,milestone_start,milestone_done,milestone_regress,task_done"
BARK_URL="https://example.invalid/key"
$1
EOF
  export AP_TIME_UNIT=1 AP_POLL_SEC=1 AP_CLAUDE_BIN="$FAKE" AP_NOTIFY_SINK="$META/notify.jsonl"
}

run_ap() { timeout "${2:-120}" bash .autopilot/autopilot.sh run >"$META/run.out" 2>&1; }
has_ref() { git rev-parse -q --verify "$1" >/dev/null; }
notified() { grep -q "$1" "$META/notify.jsonl" 2>/dev/null; }

t_full_flow() {
  echo "■ 完整流程：进展 + 超时 + 遗留改动 + 里程碑 + 完成"
  setup ""
  FAKE_SCRIPT="progress,timeout,dirty,progress,human,progress" run_ap
  expect "生成 DONE"                    test -f .autopilot/DONE
  expect "超时半成品存入 WIP 引用"      has_ref refs/autopilot/wip/iter-2
  expect "WIP 中包含 half.txt"          bash -c "git show --stat refs/autopilot/wip/iter-2 | grep -q half.txt"
  expect "遗留改动存入 WIP"             has_ref refs/autopilot/wip/iter-3
  expect "工作区最终干净"               test -z "$(git status --porcelain)"
  expect "半成品未进入分支"             test ! -f half.txt
  expect "仍在工作分支"                 test "$(git symbolic-ref --short HEAD)" = autopilot/test
  expect "下一轮提示包含超时说明"       grep -q "超时" .autopilot/logs/iter-3.prompt.md
  expect "PROGRESS 有调度脚本记录"      grep -q "调度脚本记录" .autopilot/PROGRESS.md
  expect "通知：启动"                   notified "自主迭代已启动"
  expect "通知：M1 开始"                notified "开始：M1"
  expect "通知：M1 完成"                notified "完成：M1"
  expect "通知：M2 完成"                notified "完成：M2"
  expect "通知：超时"                   notified "iter-2 超时"
  expect "通知：需要人工处理"           notified "需要人工处理"
  expect "通知：目标完成"               notified "目标已完成"
  expect "生成 REPORT.md"               grep -q "目标\|verify" .autopilot/REPORT.md
  expect "history 记录 6 轮"            test "$(($(wc -l <.autopilot/history.tsv) - 1))" -eq 6
}

t_tamper() {
  echo "■ 防篡改：第一次恢复，第二次停机"
  setup ""
  FAKE_SCRIPT="tamper,tamper" run_ap
  expect "生成 STUCK"                   test -f .autopilot/STUCK
  expect "STUCK 原因提到受保护内容"     grep -q "受保护" .autopilot/STUCK
  expect "verify.sh 已恢复"             bash -c "! grep -q cheat .autopilot/verify.sh"
  expect "未被误判完成"                 test ! -f .autopilot/DONE
}

t_protected_paths() {
  echo "■ 受保护路径：AI 修改验收测试后被恢复"
  setup 'PROTECTED_PATHS="acceptance"'
  mkdir acceptance && echo "assert true" >acceptance/t.txt && git add -A && git commit -qm "add acceptance"
  cat >"$META/fake-pp.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo "assert weakened" >acceptance/t.txt; git commit -qam "weaken"
echo '{"type":"result","is_error":false,"result":"x"}'
EOF
  chmod +x "$META/fake-pp.sh"
  AP_CLAUDE_BIN="$META/fake-pp.sh" run_ap
  expect "验收测试内容被恢复"           grep -q "assert true" acceptance/t.txt
  expect "第二次后停机"                 test -f .autopilot/STUCK
}

t_no_progress() {
  echo "■ 卡住检测：先要求换策略，再停机"
  setup "STRATEGY_SWITCH_AFTER=2
STUCK_AFTER=4"
  FAKE_SCRIPT="noop" run_ap
  expect "生成 STUCK"                   test -f .autopilot/STUCK
  expect "第 3 轮提示要求换策略"        grep -q "必须换策略" .autopilot/logs/iter-3.prompt.md
  expect "通知：换策略"                 notified "要求换策略"
  expect "共执行 4 轮"                  test "$(jq .iter .autopilot/state.json)" -eq 4
}

t_errors() {
  echo "■ claude 出错：退避重试，超过上限停机"
  setup "MAX_CONSECUTIVE_ERRORS=3"
  FAKE_SCRIPT="error" run_ap 200
  expect "生成 STUCK"                   test -f .autopilot/STUCK
  expect "STUCK 原因提到连续出错"       grep -q "连续出错" .autopilot/STUCK
  expect "出错不计入无进展"             test "$(jq .no_progress .autopilot/state.json)" -eq 0
  expect "日志记录退避"                 grep -q "退避" .autopilot/logs/autopilot.log
}

t_no_bash() {
  echo "■ 缺少 Bash 工具：按出错处理并说明原因"
  setup "MAX_CONSECUTIVE_ERRORS=1"
  FAKE_SCRIPT="nobash" run_ap
  expect "生成 STUCK"                   test -f .autopilot/STUCK
  expect "原因提到 GIT_BASH_PATH"       grep -q "CLAUDE_CODE_GIT_BASH_PATH" .autopilot/STUCK
}

t_window() {
  echo "■ 时间窗口：窗口外休眠，STOP 可立即退出"
  # 构造一个"一小时后开始、持续一分钟"的窗口，确保当前不在窗口内
  local s e; s=$(TZ=UTC date -d "+1 hour" +%H:%M); e=$(TZ=UTC date -d "+61 min" +%H:%M)
  setup "TIME_WINDOWS=\"$s-$e\"
WINDOW_TZ=UTC"
  ( sleep 4; touch "$WORK/.autopilot/STOP" ) &
  FAKE_SCRIPT="progress" run_ap 30
  expect "未执行任何一轮"               test "$(jq .iter .autopilot/state.json)" -eq 0
  expect "日志记录休眠"                 grep -q "休眠至" .autopilot/logs/autopilot.log
  expect "通知：已停止"                 notified "已按请求停止"
}

t_window_hard_deadline() {
  echo "■ 时间窗口：窗口结束即硬截止"
  local s e; s=$(TZ=UTC date -d "-1 hour" +%H:%M); e=$(TZ=UTC date -d "+2 min" +%H:%M)
  # 窗口约 1~2 分钟后结束，而单轮超时设为 600 秒：本轮应在窗口结束时被终止
  setup "TIME_WINDOWS=\"$s-$e\"
WINDOW_TZ=UTC
ITER_TIMEOUT_MIN=600"
  ( sleep 20; touch "$WORK/.autopilot/STOP" ) &
  FAKE_SCRIPT="timeout" run_ap 120
  expect "第 1 轮因窗口结束被终止"      grep -q "超过截止时间" .autopilot/logs/autopilot.log
  expect "半成品存入 WIP"               has_ref refs/autopilot/wip/iter-1
}

t_check() {
  echo "■ check 子命令"
  setup ""
  bash .autopilot/autopilot.sh check >"$META/check.out" 2>&1
  expect "check 通过"                   grep -q "检查通过" "$META/check.out"
  expect ".autopilot 被本地忽略"        grep -qx '/.autopilot/' .git/info/exclude
  git switch -qc other
  bash .autopilot/autopilot.sh check >"$META/check.out" 2>&1
  expect "分支不符时 check 失败"        grep -q "检查未通过" "$META/check.out"
}

# 仅搭建演示项目：bash tests/e2e.sh --setup <目录> [追加配置]
if [[ "${1:-}" == --setup ]]; then
  WORK=$2; META="$WORK-meta"; setup "${3:-}" >/dev/null; echo "$WORK"; exit 0
fi

cases=("$@")
(( ${#cases[@]} == 0 )) && cases=(check full_flow tamper protected_paths no_progress errors no_bash window window_hard_deadline)
for c in "${cases[@]}"; do "t_$c"; done
echo
echo "通过 $PASSED，失败 $FAILED"
(( FAILED == 0 ))

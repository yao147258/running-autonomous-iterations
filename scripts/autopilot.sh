#!/usr/bin/env bash
# =============================================================================
# autopilot.sh —— 长时自主迭代的外层调度脚本
#
# 部署位置：<项目>/.autopilot/autopilot.sh（由 skill 在启动准备阶段复制过来）
#
# 子命令：
#   check        启动前检查（环境、分支、时间窗口、verify、通知配置）
#   start        后台启动（nohup），关闭终端不影响
#   run          前台运行主循环（start 内部调用的就是它）
#   status       查看运行状态
#   stop         优雅停止：当前轮结束后退出
#   notify-test  发送一条 Bark 测试通知
#   report       生成 / 刷新 REPORT.md
#
# 依赖：bash 4+、git、jq、curl、GNU date/timeout、claude CLI
# =============================================================================
set -uo pipefail

AP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$AP_DIR/.." && pwd)"

# ---- 默认配置（会被 config.sh 覆盖）-------------------------------------------
AUTOPILOT_BRANCH=""
TIME_WINDOWS=""                 # 例："22:00-08:00"；多段用逗号分隔；空 = 全天可运行
WINDOW_TZ=""                    # 空 = 自动；也可写 POSIX 格式如 "UTC-8"（东八区）
ITER_TIMEOUT_MIN=45             # 单轮最长分钟数
END_GRACE_MIN=30                # 距窗口结束不足该分钟数时不再开新轮
VERIFY_TIMEOUT_MIN=15           # verify.sh 最长分钟数
MAX_ITERATIONS=200              # 总轮数上限
MAX_ACTIVE_HOURS=60             # 累计实际运行小时上限（休眠不计）
STRATEGY_SWITCH_AFTER=3         # 连续无进展 N 轮 → 要求换策略
STUCK_AFTER=6                   # 连续无进展 M 轮 → 停机
PLATEAU_SWITCH_AFTER=8          # verify 分数连续 N 轮未创新高 → 要求换策略
PLATEAU_STUCK_AFTER=20          # verify 分数连续 M 轮未创新高 → 停机
MAX_CONSECUTIVE_ERRORS=10       # claude 连续报错（如额度用尽）上限 → 停机
PROTECTED_PATHS=""              # 受保护的仓库路径（如验收测试目录），空格分隔
CLAUDE_MODEL=""                 # 空 = claude 默认模型
CLAUDE_EXTRA_ARGS=""            # 追加给 claude 的参数
EXTRA_DISALLOWED_TOOLS=""       # 追加禁用规则，用 ; 分隔，如 "Bash(docker:*);Bash(kubectl:*)"
NOTIFY_ENABLED=false
NOTIFY_EVENTS="start,window_end,timeout,need_human,done,stuck,crash,error,milestone_start,milestone_done,milestone_regress,stop"
BARK_GROUP="autopilot"
BARK_URL=""

# 测试钩子：时间单位（秒/分钟）与轮询间隔，正常使用不要改
MIN="${AP_TIME_UNIT:-60}"
POLL="${AP_POLL_SEC:-30}"
CLAUDE_BIN="${AP_CLAUDE_BIN:-claude}"

[[ -f "$AP_DIR/config.sh" ]] && source "$AP_DIR/config.sh"
[[ -f "$AP_DIR/secrets.sh" ]] && source "$AP_DIR/secrets.sh"
[[ -n "${AUTOPILOT_BARK_URL:-}" ]] && BARK_URL="$AUTOPILOT_BARK_URL"

STATE="$AP_DIR/state.json"
HISTORY="$AP_DIR/history.tsv"
LOG_DIR="$AP_DIR/logs"
PID_FILE="$AP_DIR/autopilot.pid"
BACKUP_DIR="$AP_DIR/.backup"
NOTES="$AP_DIR/.next-notes.md"
PROTECTED_FILES=(GOALS.md verify.sh config.sh autopilot.sh iteration-prompt.md)
mkdir -p "$LOG_DIR"

PROJECT_NAME="$(basename "$PROJECT_DIR")"
FINISHED_REASON=""
CHILD_PID=""

# ---- 基础工具 ------------------------------------------------------------------
DATE_BIN=date
date -d @0 >/dev/null 2>&1 || DATE_BIN=gdate      # macOS 需要 coreutils 的 gdate

now()      { $DATE_BIN +%s; }
now_str()  { $DATE_BIN "+%F %T"; }
fmt_ts()   { $DATE_BIN -d "@$1" "+%m-%d %H:%M"; }
fmt_dur()  { local s=$1; printf '%dh%02dm' $((s/3600)) $((s%3600/60)); }
log()      { printf '[%s] %s\n' "$(now_str)" "$*" | tee -a "$LOG_DIR/autopilot.log"; }
die()      { echo "错误：$*" >&2; exit 1; }
git_dir()  { git -C "$PROJECT_DIR" rev-parse --absolute-git-dir; }

# 设置时区：Git Bash 常见 TZ 被设成 MSYS 不认识的值而回退成 UTC，导致时间窗口偏移
setup_tz() {
  if [[ -n "$WINDOW_TZ" ]]; then export TZ="$WINDOW_TZ"; return; fi
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      local off sign='-' a
      off=$(powershell.exe -NoProfile -Command \
        "[int]([TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalMinutes)" 2>/dev/null | tr -d '\r ')
      if [[ "$off" =~ ^-?[0-9]+$ ]]; then
        a=$off; (( a < 0 )) && { sign='+'; a=$(( -a )); }   # POSIX TZ 符号与 UTC 偏移相反
        export TZ; TZ=$(printf 'UTC%s%d:%02d' "$sign" $((a/60)) $((a%60)))
      fi ;;
  esac
}

# Windows：headless claude 只有设置了 CLAUDE_CODE_GIT_BASH_PATH 才提供 Bash 工具，
# 否则只有 PowerShell（而 PowerShell 被禁用，禁用规则都是按 Bash 写的）
setup_git_bash() {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) return 0 ;; esac
  [[ -n "${CLAUDE_CODE_GIT_BASH_PATH:-}" ]] && return 0
  local root c; root=$(cygpath -w / 2>/dev/null)
  for c in "${root%\\}\\bin\\bash.exe" "${root%\\}\\usr\\bin\\bash.exe"; do
    if [[ -f "$(cygpath -u "$c")" ]]; then export CLAUDE_CODE_GIT_BASH_PATH="$c"; return 0; fi
  done
  return 1
}

# ---- 状态（state.json）----------------------------------------------------------
st_get() { jq -r "$1" "$STATE"; }
st_set() { local tmp; tmp=$(mktemp) && jq "$@" "$STATE" >"$tmp" && mv "$tmp" "$STATE"; }

init_state() {
  [[ -f "$STATE" ]] && return
  cat >"$STATE" <<'EOF'
{"iter":0,"active_seconds":0,"best_pass":-1,"last_pass":-1,"total":0,
 "no_progress":0,"plateau":0,"strategy_notified":false,"consecutive_errors":0,
 "consecutive_timeouts":0,"timeouts":0,"errors":0,"tamper_count":0,
 "need_human_count":0,"cost_usd":0,"milestones":{},"hashes":{},
 "started_at":0,"base_commit":""}
EOF
  printf 'iter\tstart\tdur_s\tresult\tpass\ttotal\tcommits\thead\n' >"$HISTORY"
}

# ---- 时间窗口 --------------------------------------------------------------------
valid_windows() {
  [[ -z "${TIME_WINDOWS// /}" ]] && return 0
  local w; IFS=',' read -ra _ws <<<"$TIME_WINDOWS"
  for w in "${_ws[@]}"; do
    w="${w// /}"
    [[ "$w" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
  done
}

# 输出当前所在窗口的剩余秒数；不在任何窗口内输出 0
window_remaining() {
  [[ -z "${TIME_WINDOWS// /}" ]] && { echo 999999999; return; }
  local n best=0 w s e d day nday st en
  n=$(now)
  IFS=',' read -ra _ws <<<"$TIME_WINDOWS"
  for w in "${_ws[@]}"; do
    w="${w// /}"; s="${w%-*}"; e="${w#*-}"
    for d in -1 0; do
      day=$($DATE_BIN -d "$d day" +%F); nday=$($DATE_BIN -d "$((d+1)) day" +%F)
      st=$($DATE_BIN -d "$day $s" +%s)
      if [[ "$e" > "$s" ]]; then en=$($DATE_BIN -d "$day $e" +%s); else en=$($DATE_BIN -d "$nday $e" +%s); fi
      if (( n >= st && n < en && en - n > best )); then best=$(( en - n )); fi
    done
  done
  echo "$best"
}

# 剩余秒数是否足够开新的一轮（必须在窗口内，且不少于宽限时间、至少 1 分钟）
can_start() { local r=$1 g=$(( END_GRACE_MIN * MIN )); (( g < MIN )) && g=$MIN; (( r >= g )); }

# 输出下一个窗口的开始时间戳
next_window_start() {
  local n best=0 w s d day st
  n=$(now)
  IFS=',' read -ra _ws <<<"$TIME_WINDOWS"
  for w in "${_ws[@]}"; do
    w="${w// /}"; s="${w%-*}"
    for d in 0 1; do
      day=$($DATE_BIN -d "$d day" +%F); st=$($DATE_BIN -d "$day $s" +%s)
      if (( st > n && (best == 0 || st < best) )); then best=$st; fi
    done
  done
  echo "$best"
}

# ---- Bark 通知 -------------------------------------------------------------------
# 用法：notify <事件> <级别 active|timeSensitive|passive> <标题> <正文>
# 失败只记日志，绝不影响主流程
notify() {
  local ev=$1 level=$2 title=$3 body=$4
  [[ -n "${SILENT:-}" ]] && return 0
  [[ "$NOTIFY_ENABLED" == true ]] || return 0
  [[ ",${NOTIFY_EVENTS// /}," == *",$ev,"* ]] || return 0
  if [[ -z "$BARK_URL" ]]; then log "通知未发送（未配置 BARK_URL）：$title"; return 0; fi

  # 去重：同一事件+标题 10 分钟内只发一次
  local key="$ev|$title" dedupe="$AP_DIR/.notify-dedupe" t; t=$(now)
  touch "$dedupe"
  if awk -F'\t' -v k="$key" -v t="$t" '$2==k && t-$1<600 {f=1} END{exit !f}' "$dedupe"; then return 0; fi
  printf '%s\t%s\n' "$t" "$key" >>"$dedupe"

  # 用文件传 payload：Windows 下命令行参数里的中文会被转码破坏
  local payload resp code
  payload=$(mktemp)
  jq -n --arg t "[$PROJECT_NAME] $title" --arg b "$body" --arg g "$BARK_GROUP" --arg l "$level" \
    '{title:$t, body:$b, group:$g, level:$l}' >"$payload"
  if [[ -n "${AP_NOTIFY_SINK:-}" ]]; then        # 测试钩子：写入文件代替推送
    { cat "$payload"; echo; } >>"$AP_NOTIFY_SINK"; resp='{"code":200}'
  else
    resp=$(curl -sS --max-time 10 -X POST "${BARK_URL%/}" \
      -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$payload" 2>&1)
  fi
  rm -f "$payload"
  code=$(jq -r '.code // empty' <<<"$resp" 2>/dev/null)
  printf '[%s] %s %s -> %s\n' "$(now_str)" "$ev" "$title" "${code:-$resp}" >>"$LOG_DIR/notify.log"
  [[ "$code" == 200 ]]
}

# ---- 受保护文件（防篡改）---------------------------------------------------------
protected_paths_hash() {
  [[ -z "${PROTECTED_PATHS// /}" ]] && { echo none; return; }
  local p files=()
  for p in $PROTECTED_PATHS; do [[ -e "$PROJECT_DIR/$p" ]] && files+=("$p"); done
  (( ${#files[@]} == 0 )) && { echo empty; return; }
  (cd "$PROJECT_DIR" && find "${files[@]}" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-64)
}

snapshot_protected() {
  mkdir -p "$BACKUP_DIR"
  local f h hashes='{}'
  for f in "${PROTECTED_FILES[@]}"; do
    [[ -f "$AP_DIR/$f" ]] || continue
    cp "$AP_DIR/$f" "$BACKUP_DIR/$f"
    h=$(sha256sum "$AP_DIR/$f" | cut -c1-64)
    hashes=$(jq --arg k "$f" --arg v "$h" '.[$k]=$v' <<<"$hashes")
  done
  hashes=$(jq --arg v "$(protected_paths_hash)" '.__paths=$v' <<<"$hashes")
  st_set --argjson h "$hashes" '.hashes=$h'
}

# 返回 0 表示完好；被篡改则恢复并返回 1，篡改说明写入全局 TAMPER_MSG
check_protected() {
  TAMPER_MSG=""
  local f want got
  for f in "${PROTECTED_FILES[@]}"; do
    want=$(jq -r --arg k "$f" '.hashes[$k] // empty' "$STATE")
    [[ -z "$want" ]] && continue
    got=$( [[ -f "$AP_DIR/$f" ]] && sha256sum "$AP_DIR/$f" | cut -c1-64 )
    if [[ "$got" != "$want" ]]; then
      cp "$BACKUP_DIR/$f" "$AP_DIR/$f"
      TAMPER_MSG+=".autopilot/$f "
    fi
  done
  want=$(jq -r '.hashes.__paths // "none"' "$STATE")
  got=$(protected_paths_hash)
  if [[ "$got" != "$want" ]]; then
    local base; base=$(st_get '.protect_commit')
    for f in $PROTECTED_PATHS; do
      git -C "$PROJECT_DIR" rm -rq --cached --ignore-unmatch -- "$f" >/dev/null 2>&1
      rm -rf "${PROJECT_DIR:?}/$f"
      git -C "$PROJECT_DIR" checkout "$base" -- "$f" 2>/dev/null
    done
    git -C "$PROJECT_DIR" add -A -- $PROTECTED_PATHS
    git -C "$PROJECT_DIR" commit -qm "autopilot: 恢复被修改的受保护路径" >/dev/null 2>&1
    TAMPER_MSG+="$PROTECTED_PATHS"
  fi
  [[ -z "$TAMPER_MSG" ]]
}

# ---- verify ----------------------------------------------------------------------
# 运行 verify.sh，设置全局 V_PASS / V_TOTAL，完整输出写入 last-verify.txt
run_verify() {
  local out="$AP_DIR/last-verify.txt"
  (cd "$PROJECT_DIR" && timeout -k 30 "$(( VERIFY_TIMEOUT_MIN * MIN ))" bash "$AP_DIR/verify.sh" </dev/null >"$out" 2>&1)
  local rc=$?
  (( rc == 124 )) && echo "FAIL - verify-timeout (verify.sh 超过 ${VERIFY_TIMEOUT_MIN} 分钟)" >>"$out"
  V_PASS=$(grep -cE '^PASS[[:space:]]' "$out" || true)
  V_TOTAL=$(grep -cE '^(PASS|FAIL)[[:space:]]' "$out" || true)
}

# ---- 里程碑 / 任务 / 待人工 -------------------------------------------------------
# 输出 TASKS.md 中的里程碑：id<TAB>状态<TAB>名称
list_milestones() {
  [[ -f "$AP_DIR/TASKS.md" ]] || return 0
  sed -nE 's/^##[[:space:]]+(M[0-9]+)[[:space:]]+(.*[^[:space:]])[[:space:]]*\[(todo|doing|done)\][[:space:]]*$/\1\t\3\t\2/p' "$AP_DIR/TASKS.md"
}

# 比较里程碑变化并发通知；同时生成"状态不一致"提示
update_milestones() {
  INCONSISTENT=""
  local id tstatus name prev_status prev_done total pass done_now fails
  local ms_total=0 ms_done=0
  while IFS=$'\t' read -r id tstatus name; do
    [[ -z "$id" ]] && continue
    ms_total=$((ms_total+1))
    prev_status=$(jq -r --arg k "$id" '.milestones[$k].status // "todo"' "$STATE")
    prev_done=$(jq -r --arg k "$id" '.milestones[$k].done // false' "$STATE")
    total=$(awk -v m="$id" '($1=="PASS"||$1=="FAIL") && $2==m' "$AP_DIR/last-verify.txt" | wc -l)
    pass=$(awk -v m="$id" '$1=="PASS" && $2==m' "$AP_DIR/last-verify.txt" | wc -l)
    if (( total > 0 )); then
      [[ $pass -eq $total ]] && done_now=true || done_now=false
    else
      [[ "$tstatus" == done ]] && done_now=true || done_now=false
    fi
    [[ "$done_now" == true ]] && ms_done=$((ms_done+1))

    if [[ "$prev_status" == todo && "$tstatus" != todo && "$done_now" != true ]]; then
      notify milestone_start active "开始：$id $name" "任务进度 ${MS_DONE_PREV:-?}/${MS_TOTAL_PREV:-?} 里程碑 | iter-$ITER"
    fi
    if [[ "$done_now" == true && "$prev_done" != true ]]; then
      notify milestone_done active "完成：$id $name" "verify $V_PASS/$V_TOTAL | iter-$ITER"
    fi
    if [[ "$done_now" != true && "$prev_done" == true && $total -gt 0 ]]; then
      fails=$(awk -v m="$id" '$1=="FAIL" && $2==m {print $3}' "$AP_DIR/last-verify.txt" | paste -sd, -)
      notify milestone_regress timeSensitive "回退：$id $name" "失败检查：$fails，由 iter-$ITER 引入，下一轮优先修复"
      INCONSISTENT+="- 里程碑 $id 曾经完成，但现在检查失败（$fails），这是回退，必须优先修复。"$'\n'
    fi
    if [[ "$tstatus" == done && "$done_now" != true ]]; then
      INCONSISTENT+="- 里程碑 $id 在 TASKS.md 中标为 [done]，但 verify 检查未全部通过。完成只以 verify 为准，请改回 [doing] 并继续。"$'\n'
    fi
    st_set --arg k "$id" --arg s "$tstatus" --argjson d "$done_now" '.milestones[$k]={status:$s,done:$d}'
  done < <(list_milestones)
  MS_TOTAL_PREV=$ms_total; MS_DONE_PREV=$ms_done
}

notify_tasks_done() {
  local cur="$AP_DIR/.tasks-done.cur" prev="$AP_DIR/.tasks-done.prev" t
  grep -E '^[[:space:]]*- \[x\]' "$AP_DIR/TASKS.md" 2>/dev/null | sed -E 's/^[[:space:]]*- \[x\][[:space:]]*//' | sort >"$cur"
  touch "$prev"
  while IFS= read -r t; do
    [[ -n "$t" ]] && notify task_done passive "任务完成：${t:0:40}" "$t"
  done < <(comm -13 "$prev" "$cur")
  mv "$cur" "$prev"
}

check_need_human() {
  local f="$AP_DIR/NEEDS_HUMAN.md" cnt prev latest
  [[ -f "$f" ]] || return 0
  cnt=$(grep -cE '^[[:space:]]*- \[ \]' "$f" || true)
  prev=$(st_get '.need_human_count')
  if (( cnt > prev )); then
    latest=$(grep -E '^[[:space:]]*- \[ \]' "$f" | tail -n $((cnt - prev)) | sed -E 's/^[[:space:]]*- \[ \][[:space:]]*//' | head -c 300)
    notify need_human timeSensitive "需要人工处理（共 $cnt 项）" "$latest"
  fi
  st_set --argjson c "$cnt" '.need_human_count=$c'
}

# ---- git 现场处理 ----------------------------------------------------------------
# 让 .autopilot/ 被本地忽略（写 .git/info/exclude，不改项目的 .gitignore）；新加入时返回 0
ensure_excluded() {
  local ex; ex="$(git_dir)/info/exclude"
  grep -qxF '/.autopilot/' "$ex" 2>/dev/null && return 1
  mkdir -p "$(dirname "$ex")"; echo '/.autopilot/' >>"$ex"
}

current_branch() { git -C "$PROJECT_DIR" symbolic-ref --short -q HEAD; }
is_dirty()       { [[ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]]; }

# 把未提交改动保存到 refs/autopilot/wip/iter-N（不移动分支），写全局 WIP_INFO
save_wip() {
  local n=$1 why=$2 gd idx tree commit
  gd=$(git_dir); idx="$gd/autopilot-wip-index"
  rm -f "$idx"; cp "$gd/index" "$idx" 2>/dev/null
  GIT_INDEX_FILE="$idx" git -C "$PROJECT_DIR" add -A
  tree=$(GIT_INDEX_FILE="$idx" git -C "$PROJECT_DIR" write-tree)
  commit=$(git -C "$PROJECT_DIR" commit-tree "$tree" -p HEAD -m "autopilot WIP iter-$n（$why）")
  git -C "$PROJECT_DIR" update-ref "refs/autopilot/wip/iter-$n" "$commit"
  rm -f "$idx"
  WIP_INFO="未提交改动已保存到 refs/autopilot/wip/iter-$n
改动统计：
$(git -C "$PROJECT_DIR" diff --stat HEAD "$commit" | tail -n 30)"
}

# 每轮结束后让工作区回到干净状态（已提交的内容全部保留）
clean_worktree() {
  local n=$1 why=$2 gd
  WIP_INFO=""
  gd=$(git_dir)
  [[ -f "$gd/index.lock" ]] && rm -f "$gd/index.lock"
  local br; br=$(current_branch)
  if is_dirty; then
    save_wip "$n" "$why"
    git -C "$PROJECT_DIR" reset -q --hard HEAD
    git -C "$PROJECT_DIR" clean -qfd
  fi
  if [[ -n "$AUTOPILOT_BRANCH" && "$br" != "$AUTOPILOT_BRANCH" ]]; then
    git -C "$PROJECT_DIR" checkout -q "$AUTOPILOT_BRANCH"
    WIP_INFO+=$'\n'"注意：上一轮切换到了分支 ${br:-（游离 HEAD）}，已切回 $AUTOPILOT_BRANCH。禁止切换分支。"
  fi
}

append_progress() {
  printf '\n## iter-%s（调度脚本记录）%s\n%s\n' "$1" "$(now_str)" "$2" >>"$AP_DIR/PROGRESS.md"
}

# ---- 运行 claude -----------------------------------------------------------------
kill_tree() {
  local pid=$1
  [[ -z "$pid" ]] && return
  if [[ -r "/proc/$pid/winpid" ]] && command -v taskkill >/dev/null 2>&1; then
    taskkill //T //F //PID "$(cat "/proc/$pid/winpid")" >/dev/null 2>&1
  fi
  kill -TERM -- "-$pid" 2>/dev/null; sleep 3; kill -KILL -- "-$pid" 2>/dev/null
}

build_prompt() {
  local n=$1 deadline_ts=$2
  cat "$AP_DIR/iteration-prompt.md"
  cat <<EOF

---
# 本轮运行信息（调度脚本生成）
- 轮次：iter-$n
- 工作分支：${AUTOPILOT_BRANCH:-$(current_branch)}（禁止切换）
- 本轮硬性截止：$(fmt_ts "$deadline_ts")（约 $(( (deadline_ts - $(now)) / 60 )) 分钟后）。超时会被强制终止，未提交改动会被移入 WIP 引用
- 当前 verify：$(st_get '.last_pass')/$(st_get '.total')（详情见 .autopilot/last-verify.txt，各检查日志见 verify.sh 的输出说明）
- 里程碑：$(list_milestones | awk -F'\t' '{printf "%s[%s] ", $1, $2}')
EOF
  if [[ -s "$NOTES" ]]; then
    printf '\n# 调度脚本对本轮的特别提示（优先处理）\n'
    cat "$NOTES"
  fi
}

# 返回：0 正常；124 超时；其他 = 出错
run_claude() {
  local n=$1 limit=$2 deadline_ts
  deadline_ts=$(( $(now) + limit ))
  local prompt="$LOG_DIR/iter-$n.prompt.md" out="$LOG_DIR/iter-$n.jsonl" err="$LOG_DIR/iter-$n.stderr"
  build_prompt "$n" "$deadline_ts" >"$prompt"

  local deny=("Bash(git push:*)" "Bash(git reset:*)" "Bash(git rebase:*)" "Bash(git clean:*)"
    "Bash(git checkout:*)" "Bash(git switch:*)" "Bash(git branch -D:*)" "Bash(git update-ref:*)"
    "Bash(git config:*)" "Bash(git filter-branch:*)" "Bash(git stash:*)"
    "Bash(rm -rf:*)" "Bash(rm -fr:*)" "Bash(rm -r:*)" "Bash(npm publish:*)" "Bash(pnpm publish:*)"
    "Bash(yarn publish:*)" "Bash(cargo publish:*)" "Bash(twine upload:*)" "Bash(docker push:*)"
    "Bash(shutdown:*)" "Bash(taskkill:*)" "Bash(curl:*)" "Bash(wget:*)" "PowerShell"
    "Edit(.autopilot/GOALS.md)" "Write(.autopilot/GOALS.md)" "Edit(.autopilot/verify.sh)" "Write(.autopilot/verify.sh)"
    "Edit(.autopilot/config.sh)" "Write(.autopilot/config.sh)" "Edit(.autopilot/autopilot.sh)" "Write(.autopilot/autopilot.sh)"
    "Edit(.autopilot/iteration-prompt.md)" "Write(.autopilot/iteration-prompt.md)" "Read(.autopilot/secrets.sh)")
  local p; for p in $PROTECTED_PATHS; do deny+=("Edit($p/**)" "Write($p/**)" "Edit($p)" "Write($p)"); done
  if [[ -n "$EXTRA_DISALLOWED_TOOLS" ]]; then IFS=';' read -ra _extra <<<"$EXTRA_DISALLOWED_TOOLS"; deny+=("${_extra[@]}"); fi

  local args=(-p --output-format stream-json --verbose --permission-mode dontAsk
    --append-system-prompt "你正在无人值守模式下运行，没有人会回答问题。执行命令请使用 Bash 工具（PowerShell 已禁用）。"
    --allowedTools Read Edit Write Glob Grep Bash TodoWrite NotebookEdit WebSearch WebFetch Agent
    --disallowedTools "${deny[@]}")
  [[ -n "$CLAUDE_MODEL" ]] && args+=(--model "$CLAUDE_MODEL")
  # shellcheck disable=SC2206
  [[ -n "$CLAUDE_EXTRA_ARGS" ]] && args+=($CLAUDE_EXTRA_ARGS)

  set -m   # 让子进程拥有独立进程组，超时时可整组终止
  ( cd "$PROJECT_DIR" && exec env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u AUTOPILOT_BARK_URL \
      "$CLAUDE_BIN" "${args[@]}" <"$prompt" >"$out" 2>"$err" ) &
  CHILD_PID=$!
  set +m

  local rc
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    if (( $(now) >= deadline_ts )); then
      log "iter-$n 超过截止时间，强制终止"
      kill_tree "$CHILD_PID"; wait "$CHILD_PID" 2>/dev/null; CHILD_PID=""
      return 124
    fi
    sleep $(( POLL < 5 ? POLL : 5 ))
  done
  wait "$CHILD_PID"; rc=$?
  CHILD_PID=""

  # 没有 Bash 工具时 AI 只能迂回（如委派子代理），禁用规则形同虚设：按出错处理
  local init_tools; init_tools=$(grep -m1 '"subtype":"init"' "$out" 2>/dev/null | jq -r 'if (.tools|type)=="array" then (.tools|index("Bash") != null) else "unknown" end' 2>/dev/null)
  if [[ "$init_tools" == false ]]; then
    echo "autopilot: 本轮 claude 没有 Bash 工具（Windows 需设置 CLAUDE_CODE_GIT_BASH_PATH 指向 Git 的 bin\\bash.exe）" >>"$err"
    log "警告：iter-$n 的 claude 没有 Bash 工具"
    return 2
  fi

  # stream-json 最后一条 result 消息里有 is_error 与费用
  local result; result=$(grep '"type":"result"' "$out" 2>/dev/null | tail -n1)
  if [[ -n "$result" ]]; then
    local cost; cost=$(jq -r '.total_cost_usd // 0' <<<"$result" 2>/dev/null)
    st_set --argjson c "${cost:-0}" '.cost_usd += $c'
    if [[ "$(jq -r '.is_error // false' <<<"$result" 2>/dev/null)" == true ]] && (( rc == 0 )); then rc=1; fi
  elif (( rc == 0 )); then
    rc=1
  fi
  return "$rc"
}

# ---- 结束处理 --------------------------------------------------------------------
gen_report() {
  local r="$AP_DIR/REPORT.md" base status
  base=$(st_get '.base_commit')
  status="运行中/未结束"
  for f in DONE STUCK STOP; do [[ -f "$AP_DIR/$f" ]] && status="$f：$(head -c 500 "$AP_DIR/$f")"; done
  {
    echo "# 自主迭代报告：$PROJECT_NAME"
    echo
    echo "- 生成时间：$(now_str)"
    echo "- 结束状态：$status"
    echo "- 工作分支：${AUTOPILOT_BRANCH:-$(current_branch)}"
    echo "- 总轮数：$(st_get '.iter') | 实际运行：$(fmt_dur "$(st_get '.active_seconds')") | 超时：$(st_get '.timeouts') 次 | 出错：$(st_get '.errors') 次"
    echo "- verify：$(st_get '.last_pass')/$(st_get '.total')（最好成绩 $(st_get '.best_pass')）"
    echo "- 累计费用（claude 报告值）：\$$(st_get '.cost_usd')"
    echo
    echo "## 里程碑"
    echo
    echo "| ID | 名称 | TASKS 状态 | verify 判定 |"
    echo "|---|---|---|---|"
    list_milestones | while IFS=$'\t' read -r id s name; do
      echo "| $id | $name | $s | $(jq -r --arg k "$id" 'if .milestones[$k].done then "完成" else "未完成" end' "$STATE") |"
    done
    echo
    echo "## verify 分数变化"
    echo
    echo '```'
    awk -F'\t' 'NR>1 {printf "iter-%-4s %-8s %s/%s  commits=%s\n", $1, $4, $5, $6, $7}' "$HISTORY" | tail -n 60
    echo '```'
    echo
    echo "## 最后一次 verify"
    echo
    echo '```'
    cat "$AP_DIR/last-verify.txt" 2>/dev/null | head -n 80
    echo '```'
    echo
    echo "## 提交记录"
    echo
    echo '```'
    [[ -n "$base" ]] && git -C "$PROJECT_DIR" log --oneline "$base..HEAD" | head -n 200
    echo '```'
    echo
    echo "## 保存的 WIP（超时/未提交的半成品）"
    echo
    echo '```'
    git -C "$PROJECT_DIR" for-each-ref --format='%(refname)  %(subject)' refs/autopilot/wip
    echo '```'
    echo
    echo "## 待人工处理"
    echo
    grep -E '^[[:space:]]*- \[ \]' "$AP_DIR/NEEDS_HUMAN.md" 2>/dev/null || echo "（无）"
    echo
    echo "## 早上验收建议"
    echo
    echo '```bash'
    echo "bash .autopilot/verify.sh                      # 亲自复验"
    [[ -n "$base" ]] && echo "git diff --stat $base..${AUTOPILOT_BRANCH:-HEAD}   # 审阅全部改动"
    echo '```'
  } >"$r"
}

# 写结束标记、生成报告、发通知并退出
finish() {
  local kind=$1 msg=$2 level=timeSensitive title
  FINISHED_REASON=$kind
  case $kind in
    DONE)  echo "$msg" >"$AP_DIR/DONE";  title="目标已完成" ;;
    STUCK) echo "$msg" >"$AP_DIR/STUCK"; title="已停机（STUCK）" ;;
    STOP)  title="已按请求停止"; level=active ;;
  esac
  log "结束：$kind —— $msg"
  gen_report
  local ev; ev=$(tr '[:upper:]' '[:lower:]' <<<"$kind")
  notify "$ev" "$level" "$title" "$msg | 共 $(st_get '.iter') 轮，实际运行 $(fmt_dur "$(st_get '.active_seconds')")，verify $(st_get '.last_pass')/$(st_get '.total')。报告见 .autopilot/REPORT.md"
  exit 0
}

on_exit() {
  local rc=$?
  [[ -n "$CHILD_PID" ]] && kill_tree "$CHILD_PID"
  if [[ -z "$FINISHED_REASON" ]]; then
    log "调度脚本异常退出（退出码 $rc）"
    gen_report 2>/dev/null
    notify crash timeSensitive "调度脚本异常退出" "退出码 $rc，最后日志：$(tail -n 3 "$LOG_DIR/autopilot.log" | tr '\n' ' ' | head -c 300)"
  fi
  [[ "$(cat "$PID_FILE" 2>/dev/null)" == "$$" ]] && rm -f "$PID_FILE"
}

# 可被 STOP 打断的休眠；收到 STOP 返回 1
nap() {
  local until_ts=$1
  while (( $(now) < until_ts )); do
    [[ -f "$AP_DIR/STOP" ]] && return 1
    local left=$(( until_ts - $(now) )); (( left > POLL )) && left=$POLL; (( left > 0 )) && sleep "$left"
  done
  return 0
}

# ---- 单轮迭代 --------------------------------------------------------------------
one_iteration() {
  local remaining=$1
  ITER=$(( $(st_get '.iter') + 1 ))
  st_set --argjson n "$ITER" '.iter=$n'

  local limit=$(( ITER_TIMEOUT_MIN * MIN ))
  (( remaining < limit )) && limit=$remaining          # 窗口结束即硬截止
  local head_before t0 rc result dur
  head_before=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  t0=$(now)
  log "iter-$ITER 开始（截止 $(fmt_ts $(( t0 + limit )))）"

  run_claude "$ITER" "$limit"; rc=$?
  dur=$(( $(now) - t0 ))
  st_set --argjson d "$dur" '.active_seconds += $d'
  : >"$NOTES"

  if (( rc == 124 )); then result=timeout
  elif (( rc != 0 )); then result=error
  else result=ok; fi

  clean_worktree "$ITER" "$result"

  # ---- 防篡改 ----
  if ! check_protected; then
    st_set '.tamper_count += 1'
    append_progress "$ITER" "- 检测到受保护内容被修改：$TAMPER_MSG，已恢复。"
    if (( $(st_get '.tamper_count') >= 2 )); then
      finish STUCK "受保护内容被多次修改（$TAMPER_MSG）"
    fi
    notify stuck timeSensitive "警告：受保护内容被修改" "$TAMPER_MSG 已恢复；再次发生将停机"
    echo "- 上一轮修改了受保护内容（$TAMPER_MSG），已被自动恢复。这些内容只读，再次修改将导致整个任务停机。" >>"$NOTES"
  fi

  run_verify
  local commits pass_prev best
  commits=$(git -C "$PROJECT_DIR" rev-list --count "$head_before..HEAD")
  pass_prev=$(st_get '.last_pass'); best=$(st_get '.best_pass')
  st_set --argjson p "$V_PASS" --argjson t "$V_TOTAL" '.last_pass=$p | .total=$t'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ITER" "$(now_str)" "$dur" "$result" "$V_PASS" "$V_TOTAL" "$commits" \
    "$(git -C "$PROJECT_DIR" rev-parse --short HEAD)" >>"$HISTORY"
  log "iter-$ITER 结束：$result，耗时 $(fmt_dur "$dur")，verify $V_PASS/$V_TOTAL，新提交 $commits"

  # ---- 结果分类处理 ----
  case $result in
    timeout)
      st_set '.timeouts += 1 | .consecutive_timeouts += 1 | .consecutive_errors = 0'
      append_progress "$ITER" "- 本轮超时被终止（限时 $(( limit / 60 )) 分钟）。
- ${WIP_INFO:-无未提交改动}"
      echo "- 上一轮（iter-$ITER）超时。${WIP_INFO:+先查看 WIP：git show --stat refs/autopilot/wip/iter-$ITER，判断是 cherry-pick 继续还是放弃，并在 PROGRESS 中记录决定。}" >>"$NOTES"
      if (( $(st_get '.consecutive_timeouts') >= 2 )); then
        echo "- 已连续 $(st_get '.consecutive_timeouts') 轮超时：本轮禁止直接重做原任务，必须先把它拆成更小的子任务写回 TASKS.md，再只做其中第一个。" >>"$NOTES"
      fi
      notify timeout active "iter-$ITER 超时" "${WIP_INFO:+半成品已存入 wip/iter-$ITER；}verify $V_PASS/$V_TOTAL"
      ;;
    error)
      st_set '.errors += 1 | .consecutive_errors += 1 | .consecutive_timeouts = 0'
      local ce errtxt; ce=$(st_get '.consecutive_errors')
      errtxt=$( (tail -c 400 "$LOG_DIR/iter-$ITER.stderr"; grep '"type":"result"' "$LOG_DIR/iter-$ITER.jsonl" | tail -n1 | jq -r '.result // empty' 2>/dev/null) | tr '\n' ' ' | head -c 300)
      append_progress "$ITER" "- claude 运行出错（连续第 $ce 次）：$errtxt
- ${WIP_INFO:-无未提交改动}"
      (( ce >= MAX_CONSECUTIVE_ERRORS )) && finish STUCK "claude 连续出错 $ce 次：$errtxt"
      (( ce % 3 == 0 )) && notify error active "claude 连续出错 $ce 次" "$errtxt"
      # 退避：5、10、20、40、60 分钟……（多半是额度/限流）
      local backoff=$(( 5 * (1 << (ce - 1)) )); (( backoff > 60 )) && backoff=60
      st_set --argjson u "$(( $(now) + backoff * MIN ))" '.backoff_until=$u'
      log "出错退避 $backoff 分钟"
      ;;
    ok)
      st_set '.consecutive_timeouts = 0 | .consecutive_errors = 0'
      if [[ -n "$WIP_INFO" ]]; then
        append_progress "$ITER" "- 本轮结束时仍有未提交改动，已移入 WIP。
- $WIP_INFO"
        echo "- 上一轮结束时留下了未提交改动（已存入 refs/autopilot/wip/iter-$ITER）。每轮结束前必须 commit 或撤销。" >>"$NOTES"
      fi
      ;;
  esac

  # ---- 进展判定 ----
  if [[ $result != error ]]; then
    if (( V_PASS > best )); then
      st_set --argjson p "$V_PASS" '.best_pass=$p | .no_progress=0 | .plateau=0 | .strategy_notified=false'
      (( best >= 0 )) && notify progress passive "verify 提升" "$best → $V_PASS / $V_TOTAL（iter-$ITER）"
    else
      st_set '.plateau += 1'
      if [[ $result == ok ]] && (( commits > 0 )); then st_set '.no_progress = 0'; else st_set '.no_progress += 1'; fi
    fi
    if (( pass_prev >= 0 && V_PASS < pass_prev )); then
      echo "- verify 从 $pass_prev 降到了 $V_PASS：上一轮引入了回退。先查看 .autopilot/last-verify.txt，优先修复回退，再做新任务。" >>"$NOTES"
    fi
  fi

  update_milestones
  [[ -n "$INCONSISTENT" ]] && printf '%s' "$INCONSISTENT" >>"$NOTES"
  notify_tasks_done
  check_need_human

  # ---- 完成 / 卡住判定 ----
  if (( V_TOTAL > 0 && V_PASS == V_TOTAL )); then
    finish DONE "verify 全部通过（$V_PASS/$V_TOTAL）"
  fi
  if (( V_TOTAL == 0 )); then
    echo "- verify.sh 没有输出任何 PASS/FAIL 行，可能是项目无法构建或环境异常，请先排查。" >>"$NOTES"
  fi

  local np pl; np=$(st_get '.no_progress'); pl=$(st_get '.plateau')
  if (( np >= STUCK_AFTER )); then finish STUCK "连续 $np 轮无进展（无新提交且 verify 未提升）"; fi
  if (( pl >= PLATEAU_STUCK_AFTER )); then finish STUCK "verify 分数连续 $pl 轮未创新高（停在 $(st_get '.best_pass')/$V_TOTAL）"; fi
  if (( np >= STRATEGY_SWITCH_AFTER || pl >= PLATEAU_SWITCH_AFTER )); then
    cat >>"$NOTES" <<EOF
- 【必须换策略】已连续 $np 轮无进展 / $pl 轮 verify 未创新高。先阅读 PROGRESS.md 中最近几轮的记录，
  在 PROGRESS.md 写下"之前为何失败 + 新思路（必须与之前不同）"，然后再动手。可选做法：换实现方案、
  先写最小复现、拆小任务、先处理别的里程碑；确实需要人决策的写入 NEEDS_HUMAN.md 后跳过。
EOF
    if [[ "$(st_get '.strategy_notified')" != true ]]; then
      notify strategy active "要求换策略" "连续 $np 轮无进展 / $pl 轮未创新高，verify $V_PASS/$V_TOTAL"
      st_set '.strategy_notified=true'
    fi
  fi
}

# ---- 子命令 ----------------------------------------------------------------------
cmd_check() {
  local ok=1
  pass() { echo "  [通过] $*"; }
  warn() { echo "  [警告] $*"; }
  fail() { echo "  [失败] $*"; ok=0; }

  echo "== 环境 =="
  local t
  for t in git jq curl timeout "$CLAUDE_BIN"; do
    command -v "$t" >/dev/null 2>&1 && pass "$t" || fail "缺少命令：$t"
  done
  $DATE_BIN -d "tomorrow 08:00" +%s >/dev/null 2>&1 && pass "GNU date" || fail "需要 GNU date（macOS 请安装 coreutils）"

  echo "== 仓库 =="
  git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || { fail "$PROJECT_DIR 不是 git 仓库"; echo; return 1; }
  [[ "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel)" -ef "$PROJECT_DIR" ]] && pass "仓库根目录" || fail ".autopilot 必须位于仓库根目录"
  ensure_excluded && pass "已将 /.autopilot/ 加入 .git/info/exclude（状态文件不进入提交）" || pass ".autopilot 已被本地忽略"
  local br; br=$(current_branch)
  if [[ -z "$AUTOPILOT_BRANCH" ]]; then fail "config.sh 未设置 AUTOPILOT_BRANCH"
  elif [[ "$br" != "$AUTOPILOT_BRANCH" ]]; then fail "当前分支 $br ≠ AUTOPILOT_BRANCH=$AUTOPILOT_BRANCH"
  elif [[ "$br" =~ ^(main|master|develop)$ ]]; then fail "不要在 $br 上运行，请使用独立分支"
  else pass "分支 $br"; fi
  is_dirty && fail "工作区不干净，请先提交或清理" || pass "工作区干净"

  echo "== 文件 =="
  local f
  for f in GOALS.md TASKS.md verify.sh iteration-prompt.md config.sh PROGRESS.md NEEDS_HUMAN.md; do
    [[ -f "$AP_DIR/$f" ]] && pass "$f" || fail "缺少 .autopilot/$f"
  done
  local ms; ms=$(list_milestones | wc -l)
  (( ms > 0 )) && pass "TASKS.md 中有 $ms 个里程碑" || warn "TASKS.md 中没有可识别的里程碑标题（格式：## M1 名称 [todo]）"
  for f in $PROTECTED_PATHS; do [[ -e "$PROJECT_DIR/$f" ]] && pass "受保护路径 $f" || fail "受保护路径不存在：$f"; done

  echo "== 时间窗口 =="
  setup_tz
  echo "  时区 TZ=${TZ:-（系统默认）}，脚本眼中的当前时间：$(now_str)（请核对是否为本地时间）"
  if ! valid_windows; then fail "TIME_WINDOWS 格式错误：$TIME_WINDOWS（应为 HH:MM-HH:MM[,HH:MM-HH:MM]）"
  elif [[ -z "${TIME_WINDOWS// /}" ]]; then pass "未设置窗口：全天运行"
  else
    local rem; rem=$(window_remaining)
    if (( rem > 0 )); then pass "窗口 $TIME_WINDOWS：当前在窗口内，剩余 $(fmt_dur "$rem")"
    else pass "窗口 $TIME_WINDOWS：当前不在窗口内，下次开始 $(fmt_ts "$(next_window_start)")"; fi
  fi

  echo "== verify =="
  if [[ -f "$AP_DIR/verify.sh" ]]; then
    run_verify
    if (( V_TOTAL == 0 )); then fail "verify.sh 没有输出 PASS/FAIL 行（格式：PASS <里程碑ID|-> <检查名>）"
    elif (( V_PASS == V_TOTAL )); then warn "verify 已全部通过（$V_PASS/$V_TOTAL）：标准可能过松，启动后会立即结束"
    else pass "verify 当前 $V_PASS/$V_TOTAL"; fi
    sed 's/^/    /' "$AP_DIR/last-verify.txt" | head -n 30
  fi

  echo "== 通知 =="
  if [[ "$NOTIFY_ENABLED" == true ]]; then
    [[ -n "$BARK_URL" ]] && pass "Bark 已开启，事件：$NOTIFY_EVENTS" || fail "已开启通知但未配置 BARK_URL（secrets.sh 或环境变量 AUTOPILOT_BARK_URL）"
  else pass "通知未开启"; fi

  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*)
    echo "== Windows =="
    if setup_git_bash; then pass "claude 将使用 Git Bash：$CLAUDE_CODE_GIT_BASH_PATH"
    else fail "找不到 Git Bash，请设置环境变量 CLAUDE_CODE_GIT_BASH_PATH"; fi
    warn "请确认电源设置为插电时不睡眠（powercfg /change standby-timeout-ac 0），否则夜间会中断" ;;
  esac
  echo
  (( ok )) && { echo "检查通过"; return 0; } || { echo "检查未通过"; return 1; }
}

is_running() { [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

cmd_start() {
  is_running && die "已在运行（PID $(cat "$PID_FILE")）"
  [[ -f "$AP_DIR/DONE" ]] && die "存在 DONE 标记，目标已完成。如需重跑请先删除 .autopilot/DONE"
  [[ -f "$AP_DIR/STUCK" ]] && die "存在 STUCK 标记（$(cat "$AP_DIR/STUCK")）。处理后删除 .autopilot/STUCK 再启动"
  rm -f "$AP_DIR/STOP"
  nohup bash "$AP_DIR/autopilot.sh" run >>"$AP_DIR/autopilot.out" 2>&1 </dev/null &
  disown 2>/dev/null
  sleep 2
  is_running && echo "已在后台启动（PID $(cat "$PID_FILE")）。查看：bash .autopilot/autopilot.sh status" \
    || { echo "启动失败，查看 .autopilot/autopilot.out："; tail -n 20 "$AP_DIR/autopilot.out"; return 1; }
}

cmd_run() {
  is_running && die "已在运行（PID $(cat "$PID_FILE")）"
  echo $$ >"$PID_FILE"
  trap on_exit EXIT
  trap 'FINISHED_REASON=""; log "收到终止信号"; exit 130' INT TERM
  trap '' HUP
  setup_tz
  setup_git_bash || die "找不到 Git Bash，请在环境变量 CLAUDE_CODE_GIT_BASH_PATH 中指定 bash.exe 路径"
  valid_windows || die "TIME_WINDOWS 格式错误：$TIME_WINDOWS"
  init_state
  ensure_excluded
  [[ -f "$AP_DIR/NEEDS_HUMAN.md" ]] || echo "# 待人工处理" >"$AP_DIR/NEEDS_HUMAN.md"
  is_dirty && clean_worktree "$(st_get '.iter')" "启动前残留"
  st_set --arg b "$(git -C "$PROJECT_DIR" rev-parse HEAD)" --argjson t "$(now)" \
    '.base_commit = (if .base_commit == "" then $b else .base_commit end) | .protect_commit = $b | .started_at = (if .started_at == 0 then $t else .started_at end) | .tamper_count = 0'
  snapshot_protected     # 每次启动重新登记（允许用户在停机期间修改目标）
  log "调度启动：分支 $(current_branch)，窗口 ${TIME_WINDOWS:-全天}，TZ=${TZ:-默认}"

  ITER=$(st_get '.iter')
  run_verify
  st_set --argjson p "$V_PASS" --argjson t "$V_TOTAL" \
    '.last_pass=$p | .total=$t | .best_pass = (if .best_pass < $p then $p else .best_pass end)'
  SILENT=1 update_milestones          # 静默登记初始里程碑状态
  SILENT=""
  notify start active "自主迭代已启动" "窗口 ${TIME_WINDOWS:-全天} | verify $V_PASS/$V_TOTAL | 里程碑 ${MS_DONE_PREV:-0}/${MS_TOTAL_PREV:-0}"
  (( V_TOTAL > 0 && V_PASS == V_TOTAL )) && finish DONE "启动时 verify 已全部通过（$V_PASS/$V_TOTAL）"

  local in_session=0 first=1 s_iter=0 s_pass=0 s_ms=0 s_to=0
  while true; do
    [[ -z "$WINDOW_TZ" ]] && setup_tz
    [[ -f "$AP_DIR/STOP" ]] && finish STOP "收到 STOP"

    local it act; it=$(st_get '.iter'); act=$(st_get '.active_seconds')
    (( it >= MAX_ITERATIONS )) && finish STUCK "已达最大轮数 $MAX_ITERATIONS"
    (( act >= MAX_ACTIVE_HOURS * 3600 )) && finish STUCK "已达累计运行上限 $MAX_ACTIVE_HOURS 小时"

    local rem; rem=$(window_remaining)
    if ! can_start "$rem"; then
      if (( in_session )); then
        local n_iter=$(( $(st_get '.iter') - s_iter ))
        notify window_end active "本时段小结" "$n_iter 轮 | verify $s_pass → $(st_get '.last_pass')/$(st_get '.total') | 里程碑 $s_ms → ${MS_DONE_PREV:-0}/${MS_TOTAL_PREV:-0} | 超时 $(( $(st_get '.timeouts') - s_to )) 次 | 待人工 $(st_get '.need_human_count') 项"
        in_session=0
      fi
      local nxt; nxt=$(next_window_start)
      log "不在可运行时段，休眠至 $(fmt_ts "$nxt")"
      while ! can_start "$(window_remaining)"; do
        nap $(( $(now) + POLL )) || finish STOP "收到 STOP"
      done
      continue
    fi

    if (( ! in_session )); then
      in_session=1; s_iter=$(st_get '.iter'); s_pass=$(st_get '.last_pass'); s_ms=${MS_DONE_PREV:-0}; s_to=$(st_get '.timeouts')
      (( first )) || { log "进入可运行时段"; notify window_start passive "恢复运行" "verify $s_pass/$(st_get '.total')"; }
    fi
    first=0

    local bo; bo=$(jq -r '.backoff_until // 0' "$STATE")
    if (( bo > $(now) )); then
      local wake=$bo; (( wake > $(now) + rem )) && wake=$(( $(now) + rem ))
      nap "$wake" || finish STOP "收到 STOP"
      continue
    fi

    one_iteration "$rem"
  done
}

cmd_status() {
  if is_running; then echo "状态：运行中（PID $(cat "$PID_FILE")）"; else echo "状态：未运行"; fi
  local f; for f in DONE STUCK STOP; do [[ -f "$AP_DIR/$f" ]] && echo "标记：$f $(cat "$AP_DIR/$f")"; done
  [[ -f "$STATE" ]] || { echo "尚未开始"; return; }
  setup_tz
  echo "轮次：$(st_get '.iter') | 实际运行：$(fmt_dur "$(st_get '.active_seconds')") | verify：$(st_get '.last_pass')/$(st_get '.total')（最好 $(st_get '.best_pass')）"
  echo "连续无进展：$(st_get '.no_progress') | 未创新高：$(st_get '.plateau') | 超时：$(st_get '.timeouts') | 出错：$(st_get '.errors') | 费用：\$$(st_get '.cost_usd')"
  echo "里程碑："; list_milestones | while IFS=$'\t' read -r id s name; do
    echo "  $id [$s] $name —— verify 判定：$(jq -r --arg k "$id" 'if .milestones[$k].done then "完成" else "未完成" end' "$STATE")"; done
  if [[ -n "${TIME_WINDOWS// /}" ]]; then
    local rem; rem=$(window_remaining)
    (( rem > 0 )) && echo "时段：窗口内，剩余 $(fmt_dur "$rem")" || echo "时段：窗口外，下次开始 $(fmt_ts "$(next_window_start)")"
  fi
  echo "最近日志："; tail -n 8 "$LOG_DIR/autopilot.log" 2>/dev/null | sed 's/^/  /'
}

cmd_notify_test() {
  [[ -n "$BARK_URL" ]] || die "未配置 BARK_URL（写入 .autopilot/secrets.sh 或设置 AUTOPILOT_BARK_URL）"
  NOTIFY_ENABLED=true NOTIFY_EVENTS=test
  rm -f "$AP_DIR/.notify-dedupe"
  if notify test active "测试通知" "如果你在手机上看到这条消息，说明 Bark 配置成功（$(now_str)）"; then
    echo "已发送，请确认手机收到"
  else
    echo "发送失败：$(tail -n1 "$LOG_DIR/notify.log")"; return 1
  fi
}

main() {
  cd "$PROJECT_DIR" || exit 1
  case "${1:-}" in
    check)       cmd_check ;;
    start)       cmd_start ;;
    run)         cmd_run ;;
    status)      cmd_status ;;
    stop)        touch "$AP_DIR/STOP"; echo "已请求停止：当前轮结束后退出（休眠中会立即退出）" ;;
    notify-test) cmd_notify_test ;;
    report)      init_state; setup_tz; gen_report; echo "已生成 .autopilot/REPORT.md" ;;
    *) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 1 ;;
  esac
}

# 整个逻辑包在 main 里并在同一行 exit：运行期间即使脚本文件被改，也不会读到新内容
main "$@"; exit $?

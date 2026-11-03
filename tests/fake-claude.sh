#!/usr/bin/env bash
# 模拟 claude -p 的行为，用于端到端测试 autopilot.sh（不消耗额度）
# 行为序列由环境变量 FAKE_SCRIPT 指定，逗号分隔，每次调用消费一个：
#   progress  新增一个功能文件并提交，勾选任务，写 PROGRESS
#   timeout   写入未提交改动后长时间休眠（触发超时）
#   dirty     写入未提交改动后正常退出
#   noop      什么都不做
#   tamper    修改受保护的 .autopilot/verify.sh
#   error     返回 is_error 结果
#   nobash    init 中没有 Bash 工具（模拟 Windows 未配置 Git Bash）
set -u
cat >/dev/null                                  # 读掉 stdin 中的 prompt
counter=.autopilot/.fake-counter
n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$counter"
IFS=',' read -ra steps <<<"${FAKE_SCRIPT:-progress}"
step=${steps[$((n-1))]:-${steps[-1]}}

result() { printf '{"type":"result","subtype":"success","is_error":%s,"result":"%s","total_cost_usd":0.01}\n' "$1" "$2"; }
if [[ $step == nobash ]]; then echo '{"type":"system","subtype":"init","tools":["Read","PowerShell"]}'; else echo '{"type":"system","subtype":"init","tools":["Read","Bash"]}'; fi

case $step in
  progress)
    k=$(( $(ls f*.txt 2>/dev/null | wc -l) + 1 ))
    echo "feature $k" >"f$k.txt"
    git add -A && git commit -qm "autopilot iter: feature $k"
    sed -i "0,/- \[ \]/s//- [x]/" .autopilot/TASKS.md
    (( k == 1 )) && sed -i 's/^## M1 \(.*\) \[todo\]/## M1 \1 [doing]/' .autopilot/TASKS.md
    (( k == 3 )) && sed -i 's/^## M2 \(.*\) \[todo\]/## M2 \1 [doing]/' .autopilot/TASKS.md
    printf '\n## iter  fake\n- 任务：feature %s\n' "$k" >>.autopilot/PROGRESS.md
    result false "done feature $k" ;;
  timeout)
    echo "half work" >half.txt
    sleep 600 ;;
  dirty)
    echo "left over" >dirty.txt
    result false "forgot to commit" ;;
  noop)
    result false "nothing" ;;
  tamper)
    echo "echo PASS - cheat" >>.autopilot/verify.sh
    result false "tampered" ;;
  human)
    echo "- [ ] 需要确认数据库类型（iter-$n）" >>.autopilot/NEEDS_HUMAN.md
    result false "asked human" ;;
  nobash)
    result false "used subagent instead" ;;
  error)
    echo "API Error: usage limit reached" >&2
    result true "usage limit reached"; exit 1 ;;
esac
exit 0

#!/usr/bin/env bash
# =============================================================================
# 验收脚本：调度脚本以它的结果作为唯一的完成判定
#
# 输出格式（每条检查一行）：PASS|FAIL  <里程碑ID 或 ->  <检查名>
# 每条检查的完整输出写入 .autopilot/verify-logs/<检查名>.log，供 AI 排查
# 启动后此文件只读（哈希校验）
# =============================================================================
cd "$(dirname "$0")/.." || exit 1
LOGS=.autopilot/verify-logs
mkdir -p "$LOGS"

# 用法：check <里程碑ID|-> <检查名> <命令...>
check() {
  local ms=$1 name=$2; shift 2
  if "$@" >"$LOGS/$name.log" 2>&1; then echo "PASS $ms $name"; else echo "FAIL $ms $name"; fi
}

# 用法：check_absent <里程碑ID|-> <检查名> <正则> <路径...>
# 路径中不应出现某模式（例如防止 skip/only 削弱测试）
check_absent() {
  local ms=$1 name=$2 re=$3; shift 3
  if grep -rnE "$re" "$@" >"$LOGS/$name.log" 2>&1; then echo "FAIL $ms $name"; else echo "PASS $ms $name"; fi
}

# ---------------- 按项目修改以下检查 ----------------
# 示例（Node.js + jest）：
# check M1 order-api        npx jest tests/acceptance/order --ci
# check M2 inventory        npx jest tests/acceptance/inventory --ci
# check -  all-tests        npx jest --ci
# check -  build            npm run build
# check_absent - no-skip    '\.(skip|only)\(|\bxit\(|\bxdescribe\(' tests src

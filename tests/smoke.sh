#!/usr/bin/env bash
#
# census.sh 的冒烟测试：在一个完全受控的沙箱里跑一遍，断言该出现的告警都出现了。
#
# 为什么要沙箱：census 的结果依赖这台机器上装了什么东西，直接拿真实机器当测试环境，
# 断言会随机器变化而失效。这里用一套人造的"机器"（假 HOME + 假声明 + 假 shim + 人造
# PATH），让告警集合变成确定的。
#
# 覆盖的告警（全部与是否装了 mise 无关）：
#   CONVENTION  —— 人造一个 node22 约定 shim
#   DRIFT       —— 假声明与仓库模板不一致
#   XDG_SHIFT   —— 沙箱里设置了 XDG_CONFIG_HOME
#   PATH_DIRT   —— 沙箱 PATH 里塞一条重复条目
#   MISSING     —— 假声明要求一个没装的运行时（go）
#   SHADOWED    —— 同一个运行时放两份副本，都不在 PATH 上
# 另有两条按环境而定，不参与断言但会打印出来：
#   PATH_ORDER  —— 需要本机装了 mise 且纳管了对应版本
#   NO_MISE     —— 没装 mise 时出现
#
# 用法: bash tests/smoke.sh   （从仓库根目录或任意目录都可）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CENSUS="$REPO_ROOT/scripts/census.sh"

FX="${TMPDIR:-/tmp}/census-smoke-$$"
FAIL=0

cleanup() { rm -rf "$FX"; }
trap cleanup EXIT

pass() { printf '  [通过] %s\n' "$1"; }
fail() { printf '  [失败] %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ---------- 搭沙箱 ----------
mkdir -p "$FX/home/.config/mise" "$FX/bin" "$FX/rt1/bin" "$FX/rt2/bin"

# 假声明：与仓库模板相比少 python/java、多一个没装的 go
# 注意放在 XDG 的全局配置位置（沙箱里设置了 XDG_CONFIG_HOME，mise 也会读这里）
mkdir -p "$FX/home/mise"
cat > "$FX/home/mise/config.toml" <<'EOF'
[tools]
node = ["22"]
go = ["1.22"]
EOF

# 假 node（会遮蔽 mise 的 node）与假约定 shim node22
printf '#!/bin/sh\necho v16.0.0\n' > "$FX/bin/node"; chmod +x "$FX/bin/node"
printf '#!/bin/sh\necho v22.23.2\n' > "$FX/bin/node22"; chmod +x "$FX/bin/node22"

# 两份"游离副本"，用来触发 SHADOWED（都不在 PATH 上）
printf '#!/bin/sh\necho v18.0.0\n' > "$FX/rt1/bin/node"; chmod +x "$FX/rt1/bin/node"
printf '#!/bin/sh\necho v19.0.0\n' > "$FX/rt2/bin/node"; chmod +x "$FX/rt2/bin/node"

# 受控 PATH：重复的 $FX/bin 触发 PATH_DIRT；mise 若存在则一并纳入，便于覆盖 PATH_ORDER
MISE_BIN="${MISE_BIN:-$HOME/.local/share/mise/shims}"
export PATH="$FX/bin:$FX/bin:$MISE_BIN:/usr/bin:/bin"
export HOME="$FX/home"
export XDG_CONFIG_HOME="$FX/home"    # 同时触发 XDG_SHIFT，并统一两个实现的部署路径口径

# ---------- 跑一遍 ----------
printf '\n census.sh 冒烟测试\n'
cd "$REPO_ROOT" || exit 1

"$CENSUS" > "$FX/out.txt" 2>"$FX/err.txt"
[ -s "$FX/out.txt" ] && pass "人类可读模式有输出" || fail "人类可读模式没有输出"

KINDS="$(grep -oE '^\s+\[[A-Z_]+\]' "$FX/out.txt" | tr -d ' []' | sort -u | tr '\n' ',')"
printf '  这次报出的告警: %s\n' "${KINDS%,}"

for want in CONVENTION DRIFT XDG_SHIFT PATH_DIRT MISSING SHADOWED; do
  case ",$KINDS," in
    *",$want,"*) pass "报出了 $want" ;;
    *)           fail "缺少 $want（沙箱是确定的，这就是回归）" ;;
  esac
done

# 英文模式要能跑，且章节标题换成英文
"$CENSUS" --lang en > "$FX/out-en.txt" 2>/dev/null
if grep -q '6. Warnings — things that need a human decision' "$FX/out-en.txt"; then
  pass "英文模式的章节标题已本地化"
else
  fail "英文模式没有输出英文标题"
fi
if grep -qE '^\s+\[CONVENTION\] Found a naming convention' "$FX/out-en.txt"; then
  pass "英文模式的告警正文已本地化"
else
  fail "英文模式的告警正文仍是中文"
fi

# JSON 模式：结构完整 + 可被机器解析
"$CENSUS" --json --lang en > "$FX/out.json" 2>/dev/null
if command -v python3 >/dev/null 2>&1; then
  python3 - "$FX/out.json" <<'PY' || FAIL=$((FAIL + 1))
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert set(d) >= {"generatedAt", "host", "runtimes", "conventions", "resolution", "warnings", "timings"}, d.keys()
assert d["warnings"], "warnings 不该为空"
assert all({"kind", "message", "action"} <= set(w) for w in d["warnings"]), "告警缺字段"
print("  [通过] JSON 可解析，且 warnings 带 kind/message/action")
PY
else
  printf '  [跳过] 没有 python3，未校验 JSON 结构\n'
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf ' 全部通过\n\n'
  exit 0
else
  printf ' 有 %d 项失败\n\n' "$FAIL"
  exit 1
fi

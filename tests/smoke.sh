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
# 期望事实（含 kind/tool/关键字）与 parity.ps1 共用 tests/fixtures/census-expected.tsv。
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
# 假声明：与仓库模板相比少 python/java、多一个"永远不可能存在"的工具
# （用 go / jadx 这类真工具名会被 CI runner 上刚好装了的版本干扰——实测
#  GitHub 的 ubuntu 镜像里有 /usr/bin/go，于是"声明了但没装"这条断言失效）。
mkdir -p "$FX/home/mise" "$FX/bin" "$FX/rt1/bin" "$FX/rt2/bin" "$FX/custom-shims"
cat > "$FX/home/mise/config.toml" <<'EOF'
[tools]
node = ["22"]
census-absent-tool = ["1.0"]
EOF

# 假 node（会遮蔽 mise 的 node）与假约定 shim node22
printf '#!/bin/sh\necho v16.0.0\n' > "$FX/bin/node"; chmod +x "$FX/bin/node"
printf '#!/bin/sh\necho v22.23.2\n' > "$FX/bin/node22"; chmod +x "$FX/bin/node22"

# 两份"游离副本"，用来触发 SHADOWED（都不在 PATH 上）
printf '#!/bin/sh\necho v18.0.0\n' > "$FX/rt1/bin/node"; chmod +x "$FX/rt1/bin/node"
printf '#!/bin/sh\necho v19.0.0\n' > "$FX/rt2/bin/node"; chmod +x "$FX/rt2/bin/node"

# 受控 PATH：重复的 $FX/bin 触发 PATH_DIRT。
# 这里【刻意不包含真实的 mise】：测试不应该依赖开发机上的 mise 状态——实测踩过，
# 本机 mise 一旦卡住（陈旧锁），会调用 mise 的 census 会一起挂住，测试白等十几分钟。
# 想顺带覆盖 mise 相关告警时，用环境变量显式指一个可用的 shims 目录：
#   MISE_BIN=/path/to/mise/shims bash tests/smoke.sh
MISE_BIN="${MISE_BIN:-$FX/__no_mise_here__}"
export PATH="$FX/bin:$FX/bin:$MISE_BIN:/usr/bin:/bin"
export HOME="$FX/home"
export XDG_CONFIG_HOME="$FX/home"    # 同时触发 XDG_SHIFT，并统一两个实现的部署路径口径

# 非默认目录中的 shim 是可发现路径，但任何扫描阶段都不能执行它。
printf '#!/bin/sh\necho executed > "%s"\necho v99.0.0\n' "$FX/shim-executed" > "$FX/custom-shims/node"
chmod +x "$FX/custom-shims/node"
export MISE_SHIMS_DIR="$FX/custom-shims/"

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
    *)           fail "缺少 ${want}（沙箱是确定的，这就是回归）" ;;
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
# 文案来自同目录的 scripts/census-text.tsv：漏查的 key 会原样露出键名
if grep -qE 'warn\.[A-Z_]+\.(message|action)|(^| )(sec|sum|no)\.[a-zA-Z]+' "$FX/out-en.txt" "$FX/out.txt"; then
  fail "输出里残留了未解析的文案 key"
else
  pass "输出里没有残留的文案 key"
fi
# 文案表缺失时必须明确失败（退出码 2 + 提示），而不是把键名当文案输出
mkdir -p "$FX/no-text"
cp "$CENSUS" "$FX/no-text/census.sh"
"$FX/no-text/census.sh" --json > /dev/null 2> "$FX/no-text.err"
NO_TEXT_CODE=$?
if [ "$NO_TEXT_CODE" -eq 2 ] && grep -q 'census-text.tsv' "$FX/no-text.err"; then
  pass "文案表缺失时以退出码 2 失败并指明 census-text.tsv"
else
  fail "文案表缺失时没有明确失败（退出码 ${NO_TEXT_CODE}）"
fi

# 扫描数据表同理：只带文案表、不带 census-data.tsv 时也必须以退出码 2 明确失败
mkdir -p "$FX/no-data"
cp "$CENSUS" "$REPO_ROOT/scripts/census-text.tsv" "$FX/no-data/"
"$FX/no-data/census.sh" --json > /dev/null 2> "$FX/no-data.err"
NO_DATA_CODE=$?
if [ "$NO_DATA_CODE" -eq 2 ] && grep -q 'census-data.tsv' "$FX/no-data.err"; then
  pass "扫描数据表缺失时以退出码 2 失败并指明 census-data.tsv"
else
  fail "扫描数据表缺失时没有明确失败（退出码 ${NO_DATA_CODE}）"
fi

# JSON 模式：结构完整 + 可被机器解析。
# 先确认 python3 真的能跑：有些环境里 `command -v python3` 成功，但它指向一个失效的
# shim（实测踩过），那属于环境问题，不该被算成 JSON 校验失败。
"$CENSUS" --json --lang en > "$FX/out.json" 2>/dev/null

# 期望事实与 parity.ps1 共用 tests/fixtures/census-expected.tsv（scope 为 both 或 smoke 的行）：
# 告警 kind、tool 与 detail/message 里的字面子串都要对上，比上面只看告警种类更严格。
# 不依赖 python3 / jq：census.sh 把 warnings 数组写在一行里，字符串内的引号都转义成 \"，
# 所以 {"kind":" 只会出现在每条告警的开头，按它切分即可。awk 只用 index/substr，
# 不用多字符分隔符或带花括号的正则（macOS 的 awk 与 ubuntu 的 mawk 行为不一）。
warn_has() { # <kind> <tool> <needle>
  awk -v want_kind="$1" -v want_tool="$2" -v want_needle="$3" '
    BEGIN { mark = "{\"kind\":\""; found = 0 }
    index($0, "  \"warnings\": [") == 1 {
      rest = $0
      while ((i = index(rest, mark)) > 0) {
        rest = substr(rest, i + length(mark))
        j = index(rest, mark)
        obj = (j > 0) ? substr(rest, 1, j - 1) : rest
        k = substr(obj, 1, index(obj, "\"") - 1)
        t = ""
        p = index(obj, "\"tool\":\"")
        if (p > 0) { t = substr(obj, p + 8); t = substr(t, 1, index(t, "\"") - 1) }
        if (k == want_kind && (want_tool == "*" || t == want_tool || index("/" t "/", "/" want_tool "/") > 0) && index(obj, want_needle) > 0) { found = 1 }
      }
    }
    END { exit (found ? 0 : 1) }' "$FX/out.json"
}
EXPECTED="$REPO_ROOT/tests/fixtures/census-expected.tsv"
LEAF="$(basename "$FX")"
CHECKED=0
while IFS="$(printf '\t')" read -r scope kind tool needle; do
  case "$scope" in both|smoke) ;; *) continue ;; esac   # 注释、空行与其他 scope
  needle="${needle%"$(printf '\r')"}"
  needle="${needle//\{sandbox\}/$LEAF}"
  CHECKED=$((CHECKED + 1))
  if warn_has "$kind" "$tool" "$needle"; then
    pass "JSON 告警符合期望：$kind tool=$tool 含 $needle"
  else
    fail "JSON 缺少期望告警：$kind tool=$tool 含 ${needle}（见 tests/fixtures/census-expected.tsv）"
  fi
done < "$EXPECTED"
[ "$CHECKED" -gt 0 ] || fail "期望文件 tests/fixtures/census-expected.tsv 没有可用的行"

PATH="$FX/custom-shims:$PATH" "$CENSUS" --json > "$FX/shim.json" 2>/dev/null
[ ! -e "$FX/shim-executed" ] && pass "自定义 shim 未被扫描执行" || fail "扫描执行了 shim"

# 脚本型启动器：自己不是 shim，但会再去调用 PATH 上的 node（复现 /usr/bin/npm 的
# `#!/usr/bin/env node`，以及优先同目录 node、否则走 PATH 的 sh 启动器）。
# 自带假启动器，不依赖 runner 上有没有装 npm。
mkdir -p "$FX/launchers"
printf '#!/usr/bin/env node\n' > "$FX/launchers/npm"; chmod +x "$FX/launchers/npm"
printf '#!/bin/sh\nexec node "$0.js" "$@"\n' > "$FX/launchers/pnpm"; chmod +x "$FX/launchers/pnpm"
rm -f "$FX/shim-executed"
PATH="$FX/custom-shims:$FX/launchers:$PATH" "$CENSUS" --json > "$FX/launcher-shim.json" 2>/dev/null
[ ! -e "$FX/shim-executed" ] && pass "npm/pnpm 启动器未经由 PATH 执行 shim" || fail "npm/pnpm 启动器经由 PATH 执行了 shim"
# 对照：PATH 上的 node 不是 shim 时，启动器照常探测版本（护栏不能把正常探测一起关掉）
PATH="$FX/launchers:$PATH" "$CENSUS" --json > "$FX/launcher-ok.json" 2>/dev/null
if grep -qE '"command": "npm", "resolvesTo": "[^"]*/launchers/npm", "version": "[^"]+"' "$FX/launcher-ok.json"; then
  pass "node 非 shim 时启动器仍探测版本"
else
  fail "node 非 shim 时启动器没有探测版本"
fi
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
  python3 - "$FX/out.json" <<'PY' || FAIL=$((FAIL + 1))
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert set(d) >= {"generatedAt", "host", "runtimes", "conventions", "resolution", "warnings", "timings"}, d.keys()
assert d["warnings"], "warnings 不该为空"
assert all({"kind", "message", "action"} <= set(w) for w in d["warnings"]), "告警缺字段"
print("  [通过] JSON 可解析，且 warnings 带 kind/message/action")
PY
else
  printf '  [跳过] 没有可用的 python3，未校验 JSON 结构\n'
fi

# probeStats（附加字段，schemaVersion 仍为 1）：launches 是非负整数，ms 是非负整数或 null（bash < 5 量不到）。
# 用 grep 而不是 python3：macOS 冒烟也要跑到这一条。
if grep -qE '"probeStats": \{"launches": [0-9]+, "ms": ([0-9]+|null)\}' "$FX/out.json"; then
  pass "JSON 带 probeStats，launches 为非负整数"
else
  fail "JSON 缺 probeStats 或 launches 不是非负整数"
fi
# --timing 的阶段键必须落在与 census.ps1 共用的集合里，ms 是非负整数——两边才能逐阶段对比。
"$CENSUS" --json --timing > "$FX/timing.json" 2>/dev/null
_timings="$(grep '"timings"' "$FX/timing.json" || true)"
_phases="$(printf '%s' "$_timings" | grep -oE '"phase":"[^"]*"' | sed -E 's/"phase":"([^"]*)"/\1/' | tr '\n' ' ')"
_bad_phase=""
for _ph in $_phases; do
  case " path-index declarations managed conventions roots probe deep-scan resolution warnings " in
    *" ${_ph} "*) ;;
    *) _bad_phase="${_bad_phase} ${_ph}" ;;
  esac
done
_bad_ms="$(printf '%s' "$_timings" | grep -oE '"ms":[^,}]*' | grep -vE '^"ms":[0-9]+$' || true)"
_core_missing=""
for _ph in declarations managed conventions roots probe resolution warnings; do
  case " ${_phases} " in *" ${_ph} "*) ;; *) _core_missing="${_core_missing} ${_ph}" ;; esac
done
if [ -z "${_bad_phase}${_bad_ms}${_core_missing}" ]; then
  pass "--timing 阶段键与 census.ps1 一致，ms 为非负整数"
else
  fail "--timing 阶段键/毫秒不对：未知=[${_bad_phase}] 缺=[${_core_missing}] ms=[${_bad_ms}]"
fi

# 回归（第 4 阶段候选根）：候选根目录里含空格的路径不能被按空白切分。
# 旧写法 `for r in $CANDIDATE_ROOTS` 会把 "$FX/data dir/mise" 拆成 "$FX/data" 和 "dir/mise"，
# 于是探测落到两个不存在的目录上。静态候选根来自 census-data.tsv，其中 {MISE_DATA}
# 展开成 $XDG_DATA_HOME/mise，所以把 XDG_DATA_HOME 指到一个带空格的目录，
# 就能造出一个"本身就带空格的候选根"。
mkdir -p "$FX/data dir/mise/spacey/bin"
printf '#!/bin/sh\necho v17.0.0\n' > "$FX/data dir/mise/spacey/bin/node"
chmod +x "$FX/data dir/mise/spacey/bin/node"
XDG_DATA_HOME="$FX/data dir" "$CENSUS" --json > "$FX/space.json" 2>/dev/null
if grep -qF "$FX/data dir/mise/spacey/bin/node" "$FX/space.json"; then
  pass "候选根目录含空格时仍被逐行探测到"
else
  fail "候选根目录含空格时被空白切分，没探测到那个 node"
fi

# 回归（第 5 阶段解析层）：声明里点名、同时又在默认解析表里的命令只能出现一次。
# 沙箱声明了 node（见上面的 config.toml），而 node 也在 census-data.tsv 的默认解析表里。
_n_node="$(grep -c '"command": "node"' "$FX/out.json" || true)"
if [ "${_n_node:-0}" -eq 1 ]; then
  pass "默认解析表与声明表去重：node 只解析一次"
else
  fail "node 在 resolution 里出现了 ${_n_node:-0} 次（应为 1）"
fi

# 回归（UNDECLARED）：项目里有 .nvmrc / .node-version 时不该报 UNDECLARED
# （census.ps1 把它们也算项目声明）；只有 package.json 的 engines 时才报。
# 两个项目目录都用沙箱环境（HOME/PATH/XDG 均不变），只差一个 .nvmrc。
mkdir -p "$FX/proj-plain" "$FX/proj-nvmrc"
printf '{ "name": "x", "engines": { "node": ">=22" } }\n' > "$FX/proj-plain/package.json"
printf '{ "name": "x", "engines": { "node": ">=22" } }\n' > "$FX/proj-nvmrc/package.json"
printf '22\n' > "$FX/proj-nvmrc/.nvmrc"
( cd "$FX/proj-plain" && "$CENSUS" --json > "$FX/proj-plain.json" 2>/dev/null )
( cd "$FX/proj-nvmrc" && "$CENSUS" --json > "$FX/proj-nvmrc.json" 2>/dev/null )
if grep -q '"UNDECLARED"' "$FX/proj-plain.json"; then
  pass "只有 package.json 时报出 UNDECLARED"
else
  fail "只有 package.json 时没有报出 UNDECLARED"
fi
if grep -q '"UNDECLARED"' "$FX/proj-nvmrc.json"; then
  fail "有 .nvmrc 时仍然报出 UNDECLARED"
else
  pass "有 .nvmrc 时不再报 UNDECLARED"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf ' 全部通过\n\n'
  exit 0
else
  printf ' 有 %d 项失败\n\n' "$FAIL"
  exit 1
fi

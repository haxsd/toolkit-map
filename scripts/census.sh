#!/usr/bin/env bash
#
# 运行时普查（census）—— 回答"这台机器上到底有哪些运行时"，而不是"PATH 解析到哪个"。
#
# 要解决的根本问题：`node --version` 这类命令是解析器（回答"现在用哪个"），
# 不是盘点器（回答"这台机器有哪些"）。把解析结果当成全量清单，就会得出
# "本机只有 Node 16" 这种关于机器的错误结论。
#
# 这是 scripts/census.ps1 的 Unix 实现，设计、分节和输出结构完全一致。
#
# 用法:
#   ./census.sh              人类可读报告
#   ./census.sh --json       JSON 输出，供 agent 消费
#   ./census.sh --deep       额外扫描常见安装根目录（较慢）
#   ./census.sh --timing     附带各阶段耗时
#   ./census.sh --lang en    英文输出（章节、告警与处置建议都是英文；默认 zh）
#
set -uo pipefail

JSON=0
DEEP=0
TIMING=0
OUT_LANG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --deep) DEEP=1; shift ;;
    --timing) TIMING=1; shift ;;
    --lang) OUT_LANG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

# 语言选择：--lang 参数 > 环境变量 CENSUS_LANG > 默认 zh。
# 不要用 LANG 这个变量名——它是系统的 locale 变量，覆盖它会波及子进程。
OUT_LANG="$(printf '%s' "${OUT_LANG:-${CENSUS_LANG:-zh}}" | tr 'A-Z' 'a-z')"
case "$OUT_LANG" in zh|en) ;; *) OUT_LANG=zh ;; esac

# 仓库内的相对路径（机器声明模板等）靠它定位，不能用当前工作目录推
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- 输出小工具 ----------
# JSON 模式下所有人类可读输出都进 stderr，保证 stdout 只有合法的 JSON。
say()  { if [ "$JSON" -eq 0 ]; then printf '%s\n' "$*"; fi; }
sec()  { if [ "$JSON" -eq 0 ]; then printf '\n%s\n %s\n%s\n' \
           "========================================================================" "$1" \
           "========================================================================"; fi; }
note() { if [ "$JSON" -eq 0 ]; then printf '  %s\n' "$*"; fi; }
dim()  { if [ "$JSON" -eq 0 ]; then printf '    %s\n' "$*"; fi; }

# JSON 字符串转义（只处理必须的字符，避免依赖 jq）
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\r' \
    | awk 'BEGIN{ORS="\\n"} {gsub(/\n/,"\\n")} 1' | sed 's/\\n$//'
}

# ============================================================
# 语言与文案
# ============================================================
# 文案表用 TSV 形式（键@@语言@@文本）放在 here-doc 里，用 awk 按需查。
# 刻意不用关联数组：macOS 自带的 /bin/bash 是 3.2，不支持 declare -A，
# 而这个脚本承诺在 macOS 上开箱即用。
catalog() {
  cat <<'CATALOG'
title@@zh@@运行时普查报告 (census)
title@@en@@runtime-census report
meta@@zh@@生成时间: {time}   主机: {user}@{arch}   当前目录: {cwd}
meta@@en@@generated {time}   host {user}@{arch}   cwd {cwd}
sec.decl@@zh@@1. 声明层 —— 谁在要求哪些工具与版本
sec.decl@@en@@1. Declarations — who asks for which tools and versions
sec.managed@@zh@@2. 纳管层 —— mise 管理的工具
sec.managed@@en@@2. Managed — tools that mise manages
sec.conv@@zh@@3. 约定层 —— 带版本号的命名 shim（最容易失传的约定）
sec.conv@@en@@3. Conventions — version-suffixed shims (the kind that gets lost)
sec.inv@@zh@@4. 工具清单 —— 磁盘上实际存在的运行时与工具（含纳管与未纳管）
sec.inv@@en@@4. Inventory — runtimes and tools actually present on disk (managed or not)
sec.res@@zh@@5. 解析层 —— 命令实际解析到哪
sec.res@@en@@5. Resolution — what each command actually resolves to
sec.warn@@zh@@6. 告警 —— 需要人工确认的问题
sec.warn@@en@@6. Warnings — things that need a human decision
sec.summary@@zh@@汇总
sec.summary@@en@@Summary
sec.timing@@zh@@性能分解 —— 各阶段耗时
sec.timing@@en@@Timing — per-stage cost
no.decl@@zh@@（未发现任何 mise.toml / .tool-versions 声明）
no.decl@@en@@(no mise.toml / .tool-versions declarations found)
no.mise@@zh@@mise 未安装（PATH 上找不到）。
no.mise@@en@@mise is not installed (not found on PATH).
no.managed@@zh@@mise 已安装，但尚未纳管任何工具。
no.managed@@en@@mise is installed but manages no tools yet.
no.conv@@zh@@（未发现）
no.conv@@en@@(none found)
no.warn@@zh@@未发现问题。
no.warn@@en@@No problems found.
scope.global@@zh@@[全局]
scope.global@@en@@[global]
scope.project@@zh@@[项目]
scope.project@@en@@[project]
conv.line@@zh@@{shim} 名称声明 {declared} 实际 {actual} [{state}]
conv.line@@en@@{shim} declares {declared}, actual {actual} [{state}]
state.ok@@zh@@OK
state.ok@@en@@OK
state.bad@@zh@@不可用
state.bad@@en@@not usable
inv.count@@zh@@{tool}  共 {count} 个
inv.count@@en@@{tool}  {count} found
res.hits@@zh@@{command} -> {path}  ({version})  [{hits} 个 PATH 命中]
res.hits@@en@@{command} -> {path}  ({version})  [{hits} PATH hits]
res.line@@zh@@{command} -> {path}  ({version})
res.line@@en@@{command} -> {path}  ({version})
res.stub@@zh@@^ 警告：实测无法执行（应用执行别名的目标未安装，运行 --version 无输出、退出码 9009）
res.stub@@en@@^ warning: cannot actually run (app-execution alias whose target app is missing; --version gives no output, exit 9009)
sum.runtimes@@zh@@发现的运行时/工具条目数: {count}
sum.runtimes@@en@@Runtime/tool entries found: {count}
sum.byTool@@zh@@{tool}  {count} 个版本: {versions}
sum.byTool@@en@@{tool}  {count} versions: {versions}
sum.placement@@zh@@位置分布: {text}
sum.placement@@en@@Placement: {text}
sum.root@@zh@@规范根:   {root}
sum.root@@en@@Canonical root: {root}
sum.warnings@@zh@@告警数量: {count}
sum.warnings@@en@@Warnings: {count}
timing.total@@zh@@合计
timing.total@@en@@total
lbl.托管@@zh@@托管
lbl.托管@@en@@managed
lbl.宿主@@zh@@宿主
lbl.宿主@@en@@bundled with IDE
lbl.公认@@zh@@公认
lbl.公认@@en@@standard location
lbl.规范根@@zh@@规范根
lbl.规范根@@en@@canonical root
lbl.游离@@zh@@游离
lbl.游离@@en@@stray
lbl.游离位置@@zh@@游离位置
lbl.游离位置@@en@@stray location
lbl.不可用@@zh@@不可用
lbl.不可用@@en@@not usable
lbl.系统安装@@zh@@系统安装
lbl.系统安装@@en@@system install
lbl.IDE 内置@@zh@@IDE 内置
lbl.IDE 内置@@en@@bundled with IDE
lbl.自定义位置@@zh@@自定义位置
lbl.自定义位置@@en@@custom location
lbl.版本管理器@@zh@@版本管理器
lbl.版本管理器@@en@@version manager
lbl.mise@@zh@@mise
lbl.mise@@en@@mise
lbl.conda@@zh@@conda
lbl.conda@@en@@conda
lbl.scoop@@zh@@scoop
lbl.scoop@@en@@scoop
lbl.chocolatey@@zh@@chocolatey
lbl.chocolatey@@en@@chocolatey
lbl.homebrew@@zh@@homebrew
lbl.homebrew@@en@@homebrew
lbl.0. PATH 索引@@zh@@0. PATH 索引
lbl.0. PATH 索引@@en@@0. PATH index
lbl.1. 声明层@@zh@@1. 声明层
lbl.1. 声明层@@en@@1. Declarations
lbl.2. mise 纳管层@@zh@@2. mise 纳管层
lbl.2. mise 纳管层@@en@@2. Managed (mise)
lbl.3. 约定层@@zh@@3. 约定层
lbl.3. 约定层@@en@@3. Conventions (shims)
lbl.4. 定向探测@@zh@@4. 定向探测
lbl.4. 定向探测@@en@@4. Targeted probing
lbl.5. 解析层@@zh@@5. 解析层
lbl.5. 解析层@@en@@5. Resolution
lbl.6. 汇总告警@@zh@@6. 汇总告警
lbl.6. 汇总告警@@en@@6. Warnings
dirt.dupes@@zh@@重复条目 {n} 条
dirt.dupes@@en@@duplicate entries: {n}
dirt.quoted@@zh@@带引号的条目 {n} 条
dirt.quoted@@en@@quoted entries: {n}
dirt.join@@zh@@、
dirt.join@@en@@ and 
drift.onlyTpl@@zh@@模板有而部署副本没有: {keys}
drift.onlyTpl@@en@@in the template but not deployed: {keys}
drift.onlyDep@@zh@@部署副本有而模板没有: {keys}
drift.onlyDep@@en@@deployed but not in the template: {keys}
drift.sameKeys@@zh@@[tools] 的键相同，但内容有差异（版本或注释不同）
drift.sameKeys@@en@@same [tools] keys, different content (versions or comments)
drift.join@@zh@@；
drift.join@@en@@; 
warn.STUB.message@@zh@@命令 '{command}' 解析到 '{path}'，实测无法执行（运行 --version 无输出、退出码 9009）。这类文件是 Windows 应用执行别名，目标应用没装时执行会静默失败，而 Get-Command / where.exe 都会把它当成可用命令。
warn.STUB.message@@en@@'{command}' resolves to '{path}', which cannot actually run (probing --version gives no output, exit code 9009). This is a Windows app-execution alias: when the target app is missing the call fails silently, yet Get-Command and where.exe both list it as usable.
warn.STUB.action@@zh@@换用其它命令，或安装该别名对应的应用
warn.STUB.action@@en@@Use another command, or install the app behind the alias
warn.PATH_ORDER.message@@zh@@声明要求 {tool} {wanted}（{file}），mise 也装有 {have}，但 '{command}' 解析到 '{path}'（{version}）。未激活 mise 的场景（cmd、图形程序、IDE 任务、-NoProfile 脚本）会用到错版本；根因是 PATH 组合顺序，不是运行时本身有问题。
warn.PATH_ORDER.message@@en@@'{file}' asks for {tool} {wanted} and mise has {have}, but '{command}' resolves to '{path}' ({version}). Contexts without mise activation (cmd, GUI apps, IDE tasks, -NoProfile scripts) get the wrong version — the root cause is PATH ordering, not the runtime itself.
warn.PATH_ORDER.action@@zh@@交互式会话里 mise activate 会把 shims 前置来救场；要让所有场景都对，需要把 shims 放到用户级 PATH 首位（bootstrap 会做），机器级条目（如 Oracle 的 javapath）需要管理员权限调整或让位
warn.PATH_ORDER.action@@en@@mise activate prepends the shims inside interactive sessions; to fix every context, put the shims first on the user PATH (bootstrap does this) — machine-level entries such as Oracle javapath need admin rights to change
warn.SHADOWED.message@@zh@@'{tool}' 在磁盘上有 {total} 个副本，其中 {hidden} 个不在 PATH 上，无法被直接调用。被遮蔽的位置见下。
warn.SHADOWED.message@@en@@'{tool}' exists {total} times on disk; {hidden} cannot be reached through PATH (the hidden copies are listed below).
warn.SHADOWED.action@@zh@@要固定用某一版就写进声明文件；不要靠 PATH 顺序记住它
warn.SHADOWED.action@@en@@Pin the version you want in a declaration file instead of relying on PATH order
warn.CONVENTION.message@@zh@@发现自定义命名约定 '{shim}'（文件名里声明版本 {declared}，实际 {actual}）。这类约定不在任何标准里，必须写进声明文件否则会失传。
warn.CONVENTION.message@@en@@Found a naming convention: '{shim}' (the filename claims {declared}, the binary is actually {actual}). Conventions that live only in a filename are invisible to every tool — record it in a declaration file or it will be lost.
warn.CONVENTION.action@@zh@@把这条约定登记到声明文件（mise.toml / .tool-versions）
warn.CONVENTION.action@@en@@Record it in a declaration file (mise.toml / .tool-versions)
warn.PATH_DIRT.message@@zh@@PATH 里有{parts}。它们不改变解析结果，但会让「改了却没生效」这类问题更难查。
warn.PATH_DIRT.message@@en@@PATH contains {parts}. They do not change resolution, but they hide “I changed it but nothing took effect” problems.
warn.PATH_DIRT.action@@zh@@清理这些条目（重复条目可以直接删掉）
warn.PATH_DIRT.action@@en@@Clean them up (duplicate entries can simply be dropped)
warn.DRIFT.message@@zh@@部署的全局声明（{deployed}）与仓库模板不一致。模板代表这台机器想要的状态，漂移意味着模板里新加的工具永远不会被安装。
warn.DRIFT.message@@en@@The deployed machine manifest ({deployed}) differs from the repo template. The template is the state this machine wants; while they drift, tools added to the template are never installed.
warn.DRIFT.action@@zh@@刷新: scripts/bootstrap.sh --refresh-config（会先备份）
warn.DRIFT.action@@en@@Refresh it: scripts/bootstrap.sh --refresh-config (backs up first)
warn.XDG_SHIFT.message@@zh@@本机设置了 XDG_CONFIG_HOME={xdg}，mise 的全局配置目录会跟着搬到这里（{config}）。后果是 ~/.config/mise/config.toml 不再是全局配置，而是「从工作目录向上发现」的配置——工作目录不在用户目录之下时它不生效。
warn.XDG_SHIFT.message@@en@@XDG_CONFIG_HOME={xdg} is set, so mise moves its global config directory to {config}. As a result ~/.config/mise/config.toml is no longer the global config: it becomes a config discovered by walking up from the working directory, and has no effect outside the home tree.
warn.XDG_SHIFT.action@@zh@@要么去掉这个变量（推荐，机器声明就写在 ~/.config/mise/config.toml），要么把声明迁到 {config}
warn.XDG_SHIFT.action@@en@@Either unset the variable (recommended: the manifest lives in ~/.config/mise/config.toml) or move the manifest to {config}
warn.STRAY.message@@zh@@有 {count} 个工具/运行时放在非规范位置，且没有任何管理器纳管它们。它们只靠 PATH 被找到——PATH 一变就失传。建议登记到声明文件；今后新装的工具请落在 {root}。
warn.STRAY.message@@en@@{count} tool(s)/runtime(s) sit outside the canonical root and are tracked by no manager. They are reachable only through PATH, so a PATH change loses them. Record them in a declaration file; install future tools under {root}.
warn.STRAY.action@@zh@@登记它们（不要搬动路径：路径可能被项目配置或 IDE 写死）
warn.STRAY.action@@en@@Record them — do not move the paths (project config or IDEs may hard-code them)
warn.UNDECLARED.message@@zh@@当前目录的 package.json 要求 node {wanted}，但没有任何工具读得到的声明文件。engines 只在版本不符时给警告，不会切换版本——这就是当初需要 node22.cmd 那类私有约定的原因。
warn.UNDECLARED.message@@en@@This directory's package.json asks for node {wanted}, but no tool can read a declaration here. engines only warns on mismatch; it never switches versions — which is why private conventions like node22.cmd existed.
warn.UNDECLARED.action@@zh@@在项目根目录建 mise.toml（[tools] node = "22"）或 .tool-versions（nodejs 22）；之后 cd 进项目会自动用对版本
warn.UNDECLARED.action@@en@@Add mise.toml ([tools] node = "22") or .tool-versions (nodejs 22) at the project root; from then on cd-ing in selects the right version
warn.MISSING.message@@zh@@声明文件 '{file}' 要求 {tool} {wanted}，但本机没有发现它——既不在 PATH 上，也没有被任何管理器纳管。
warn.MISSING.message@@en@@'{file}' asks for {tool} {wanted}, but it was not found on this machine — not on PATH, and not managed by anything.
warn.MISSING.action@@zh@@执行 mise install 把它装上（新机器可直接跑 scripts/bootstrap.sh）
warn.MISSING.action@@en@@Install it with mise install (on a new machine, just run scripts/bootstrap.sh)
warn.NO_MISE.message@@zh@@本机未安装 mise。运行时只能靠 PATH 解析，无法按项目自动切换版本。
warn.NO_MISE.message@@en@@mise is not installed. Runtimes can only be resolved through PATH, so per-project version switching is unavailable.
warn.NO_MISE.action@@zh@@执行 scripts/bootstrap.sh 建立声明式层
warn.NO_MISE.action@@en@@Run scripts/bootstrap.sh to set up the declarative layer
CATALOG
}

# 取一条文案并用 k=v 参数替换 {占位符}。缺失的键返回键名本身，
# 这样漏翻译会立刻在输出里露出来，而不是静默变成空白。
# 文案表只在第一次调用时生成一次并落成临时文件：报告里 T 会被调用几十次，
# 每次都重跑一次 catalog+awk 会白白多出上百个进程（实测占掉数秒）。
TEXT_FILE=""
ensure_text_file() {
  [ -n "$TEXT_FILE" ] && return 0
  TEXT_FILE="${TMPDIR:-/tmp}/census-text-$$.tsv"
  catalog > "$TEXT_FILE" 2>/dev/null || TEXT_FILE=""
  [ -n "$TEXT_FILE" ] && trap 'rm -f "$TEXT_FILE"' EXIT
  return 0
}
T() {
  local key="$1"; shift
  local s
  ensure_text_file
  if [ -n "$TEXT_FILE" ]; then
    s="$(awk -F'@@' -v k="$key" -v l="$OUT_LANG" '$1==k && $2==l {print $3; exit}' "$TEXT_FILE")"
    [ -n "$s" ] || s="$(awk -F'@@' -v k="$key" '$1==k {print $3; exit}' "$TEXT_FILE")"
  else
    s="$(catalog | awk -F'@@' -v k="$key" -v l="$OUT_LANG" '$1==k && $2==l {print $3; exit}')"
  fi
  [ -n "$s" ] || s="$key"
  local kv k2 v2 pat
  for kv in "$@"; do
    k2="${kv%%=*}"; v2="${kv#*=}"; pat="{$k2}"
    s="${s//$pat/$v2}"
  done
  printf '%s' "$s"
}

# 内部取值（位置、来源、阶段名）→ 当前语言的显示名
label_text() {
  local s
  s="$(T "lbl.$1" 2>/dev/null)"
  if [ "$s" = "lbl.$1" ]; then printf '%s' "$1"; else printf '%s' "$s"; fi
}

# 内部取值 → JSON 里的稳定 ASCII 键（agent 不该依赖中文取值）
stable_key() {
  case "$1" in
    托管) echo managed ;; 宿主) echo host ;; 公认) echo standard ;;
    规范根) echo canonical ;; 游离) echo stray ;;
    mise) echo mise ;; conda) echo conda ;; scoop) echo scoop ;;
    chocolatey) echo chocolatey ;; homebrew) echo homebrew ;;
    系统安装) echo system ;; "IDE 内置") echo ide ;; 自定义位置) echo custom ;;
    版本管理器) echo version-manager ;; 定向探测) echo probe ;; "(深度扫描)") echo deep-scan ;;
    # 计时阶段名
    "0. PATH 索引") echo path-index ;; "1. 声明层") echo declarations ;;
    "2. mise 纳管层") echo managed ;; "3. 约定层") echo conventions ;;
    "4. 定向探测") echo roots ;; "5. 解析层") echo resolution ;; "6. 汇总告警") echo warnings ;;
    *) echo "$1" ;;
  esac
}

# ---------- 数据收集 ----------
RUNTIME_ROWS=""      # tool|version|path|source|placement|usable|root|pattern
CONV_ROWS=""         # shim|shimVersion|actualVersion|target|usable
WARN_JSON="[]"
WARN_TEXT=""
WARN_JSON_ITEMS=""   # 逐条拼出来的 JSON 片段，供 --json 输出使用

# 当前探测起点与发现阶段，写进每条记录的 root / pattern 字段。
# 与 census.ps1 的 -Root / -Pattern 参数一一对应：JSON 契约要求两个平台的
# runtimes 记录字段完全一致，缺字段会让按文档写的消费者在某一侧拿到 null。
CUR_ROOT=""
CUR_PATTERN="定向探测"

# 运行时行的字段顺序：tool|version|path|source|placement|usable|root|pattern
# 注意必须收满 6 个字段：下游的去重（NF>=6）、[STRAY]（$6=="yes"）、
# 位置分布统计、§4 的标记全都依赖第 6 列。少收一个字段会让整节静默变空。
# 后两列刻意追加在末尾（而不是插在中间）：$1..$6 的既有含义不能动。
add_runtime() { RUNTIME_ROWS="${RUNTIME_ROWS}${1}|${2}|${3}|${4}|${5}|${6}|${7}|${8}
"; }
add_conv()    { CONV_ROWS="${CONV_ROWS}${1}|${2}|${3}|${4}|${5}
"; }
# 记一条告警：人类可读文本与 JSON 片段同时产出，保证 --json 里也能看到全部告警
# 记一条告警：kind 是稳定的 ASCII 代码；message / action 跟随语言；
# detail 是事实（路径、版本）。人类可读文本与 JSON 片段同时产出，
# 保证 --json 里也能看到全部告警（含处置建议）。
# 用法: add_warn <KIND> <TOOL> <DETAIL> [k=v ...]
add_warn()    {
  local kind="$1" tool="$2" detail="$3"; shift 3
  local message action entry
  message="$(T "warn.$kind.message" "$@")"
  action="$(T "warn.$kind.action" "$@")"
  entry="[$kind] ${message}"
  [ -n "$action" ] && entry="${entry}
        -> ${action}"
  [ -n "$detail" ] && entry="${entry}
        ${detail}"
  WARN_TEXT="${WARN_TEXT}${entry}
"
  WARN_JSON_ITEMS="${WARN_JSON_ITEMS}${WARN_JSON_ITEMS:+,}{\"kind\":\"$kind\",\"tool\":\"$(json_escape "$tool")\",\"message\":\"$(json_escape "$message")\",\"action\":\"$(json_escape "$action")\",\"detail\":\"$(json_escape "$detail")\"}"
}

# 判断文件是否"真的可执行"：存在、非常规文件、非 0 字节。
# 0 字节的假文件在 Windows 上很常见（商店应用别名），Unix 上少见但仍需防。
is_real() {
  [ -f "$1" ] && [ -s "$1" ] && [ -x "$1" ]
}

# 带超时地运行命令并捕获 stdout。
# 为什么需要它：census 是只读诊断工具，不能跟着别的进程卡死——实测 mise 会因为
# 陈旧的锁或联网自检无限等待，`mise ls` 一挂，整份报告就出不来。
# 优先用 coreutils 的 timeout；macOS 默认没有它，退回到"后台进程 + 看门狗"。
# 顺带把 MISE_AUTO_UPDATE 关掉：诊断不该等着检查更新，结果才可复现。
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    MISE_AUTO_UPDATE=0 timeout "$secs" "$@" 2>/dev/null
    return 0
  fi
  local out_file pid wd
  out_file="${TMPDIR:-/tmp}/census-cmd-$$.out"
  MISE_AUTO_UPDATE=0 "$@" >"$out_file" 2>/dev/null &
  pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) 2>/dev/null &
  wd=$!
  wait "$pid" 2>/dev/null
  kill "$wd" 2>/dev/null
  cat "$out_file" 2>/dev/null
  rm -f "$out_file"
}

# ---------- 声明文件读取（供漂移 / 缺失 / 遮罩三类告警共用）----------

# 去掉可能的 UTF-8 BOM。用 tr 而不是 awk 的 \x 转义：
# \x 是 gawk 扩展，ubuntu 上默认的 mawk 不认（有的版本还会直接报错），
# 而 \357\273\277 是 POSIX 的八进制写法，到处都能用。
strip_bom() {
  tr -d '\357\273\277' < "$1" 2>/dev/null || cat "$1" 2>/dev/null
}

# 取出某个文件 [tools] 段的键名。极简扫描，不解析数组与嵌套表。
tools_keys() {
  strip_bom "$1" | awk '/^\[tools\]/{f=1;next} /^\[/{f=0} f && /^[A-Za-z0-9_.-]+[ \t]*=/{sub(/[ \t]*=.*/,"");print}' | sort -u
}

# 读出所有声明文件里的"工具|期望版本|来源文件"。
# toml 读 [tools] 段；.tool-versions 读每行的前两列。
declared_tools() {
  local f
  for f in $DECL_FILES; do
    case "$f" in
      *.toml)
        strip_bom "$f" | awk -v src="$f" '/^\[tools\]/{f=1;next} /^\[/{f=0} f && /^[A-Za-z0-9_.-]+[ \t]*=/{
              key=$0; sub(/[ \t]*=.*/,"",key);
              val=$0; sub(/^[^=]*=[ \t]*/,"",val); gsub(/[\[\]"]/,"",val);
              print key "|" val "|" src }'
        ;;
      *)
        strip_bom "$f" | awk -v src="$f" '$1 ~ /^[A-Za-z0-9_.-]+$/ && $2 != "" && $0 !~ /^[[:space:]]*#/ { print $1 "|" $2 "|" src }'
        ;;
    esac
  done
}

# mise 纳管的工具版本查询。
# MISE_TOOLS 每行形如 "node  22.23.2  <配置文件>  22"，同一工具可能有多行（22 和 20 都在）。
# 优先返回与期望版本前缀匹配的那个，否则回退到第一个——这样告警里显示的版本
# 与声明要求的是同一个，而不是碰巧排在前面的那个。
mise_version() {
  printf '%s' "$MISE_TOOLS" | awk -v t="$1" -v want="${2:-}" '
    $1==t {
      if (want != "" && index($2, want) == 1) { print $2; found=1; exit }
      if (first == "") first = $2
    }
    END { if (!found && first != "") print first }'
}
runtime_installed() { printf '%s' "$RUNTIME_ROWS" | awk -F'|' -v t="$1" '$1==t {found=1} END{exit !found}'; }

# 声明里的工具名 → 运行时名（nodejs/python3 这些别名要归一化）
short_tool() {
  case "$1" in
    nodejs|node)     echo node ;;
    python3|python)  echo python ;;
    *)               echo "$1" ;;
  esac
}

# 判断解析到的实际版本是否已经满足声明要求。规则与 census.ps1 的 Test-VersionSatisfies
# 完全一致（两个实现必须给出同样的结论，否则同一台机器会得出两套告警）：
#   声明 "3.12" 满足 "3.12.10"、声明 "22" 满足 "22.23.2"（按数字段比前缀）；
#   带发行版前缀的声明先剥前缀（temurin-21 -> 21）；
#   声明是一串时（TOML 数组去掉括号后的 "22, 20"）任意一条满足即可；
#   latest / stable 这类判断不出来的一律当作满足——宁可漏报，也不要在用户本来就
#   满足声明时喊"版本不对"（实测：Windows 的 py 启动器不受 mise 管，改 PATH 也不会消失）。
version_satisfies() {
  local actual="$1" wanted="$2" one w v
  [ -n "$wanted" ] || return 0
  [ -n "$actual" ] || return 1
  v="$(printf '%s' "$actual" | sed -E 's/[^0-9]+/./g; s/^\.+//; s/\.+$//')"
  # 注意必须用 printf '%s\n'（带结尾换行）：while read 在 EOF 处不会执行最后一行，
  # 少这个换行会把"最后一个候选版本"整个丢掉——单词声明（temurin-21）就只有一个候选，
  # 丢了它等于这条判定永远返回"不满足"。
  while IFS= read -r one; do
    one="$(printf '%s' "$one" | tr -d ' \t"')"
    [ -n "$one" ] || continue
    case "$one" in latest|stable|lts|system|any|'*') return 0 ;; esac
    w="${one#*-}"                                            # 发行版前缀：temurin-21 -> 21
    w="$(printf '%s' "$w" | sed -E 's/[^0-9]+/./g; s/^\.+//; s/\.+$//')"
    [ -n "$w" ] || return 0
    case "$v" in "$w"|"$w".*) return 0 ;; esac
  done < <(printf '%s\n' "$wanted" | tr ',;' '\n')
  return 1
}

# ---------- 阶段计时（--timing）----------
# 用 date +%s 而不是 GNU 的 %N：macOS 的 date 不认 %N，粒度到秒对本脚本足够。
TIMING_ROWS=""
TIMING_JSON_ITEMS=""
LAST_TICK="$(date +%s)"
tick() {
  [ "$TIMING" -eq 1 ] || return 0
  local now elapsed
  now="$(date +%s)"
  elapsed=$((now - LAST_TICK))
  TIMING_ROWS="${TIMING_ROWS}${1}|${elapsed}
"
  # JSON 里的字段名与单位必须与 census.ps1 一致（毫秒）：文档承诺的是 per-stage milliseconds，
  # 消费者读 timings[i].ms。本脚本计时粒度是秒（为了兼容 macOS 的 date），所以换算成毫秒输出——
  # 值会是 1000 的整数倍，精度如实反映，但字段名和单位不能两边各写各的。
  TIMING_JSON_ITEMS="${TIMING_JSON_ITEMS}${TIMING_JSON_ITEMS:+,}{\"phase\":\"$(stable_key "$1")\",\"ms\":$((elapsed * 1000))}"
  LAST_TICK="$now"
}

# ---------- 规范根与位置基准 ----------
# 规范根：非托管的手装运行时应该放在这里，按 <工具>/<版本>/ 排列。
# 它不是一个强制约束，而是给 census 一个判断"位置是否规范"的基准。
# 新机器由 bootstrap 建立；存量机器只检查、不迁移——搬动已有运行时的风险
# （路径被项目配置、IDE 设置、CI 脚本写死）远大于收益。
TOOLS_ROOT="${TOOLCHAIN_ROOT:-$HOME/toolchains}"

# 操作系统与发行版的公认安装位置。落在这些位置下的运行时不算游离。
STANDARD_ROOTS="/usr /usr/local /opt /Library /Applications /System $HOME/Applications"

# 判断一个运行时安装的位置属于哪一类：
#   宿主   —— IDE 捆绑的运行时（jbr 等），由 IDE 自己管理
#   托管   —— mise / nvm / fnm / volta / asdf / pyenv / conda / scoop / homebrew
#   公认   —— 操作系统或发行版的标准安装目录
#   规范根 —— 本套件约定的 <工具>/<版本>/ 根
#   游离   —— 以上都不是：手工放在某处，且没有任何机制记得它
placement_of() {
  local p="$1" r
  # 先判宿主：IDE 捆绑的 JBR 里有完整 JDK，但记进"游离"会把真正需要登记的东西淹没
  case "$p" in
    */jbr/*|*[Pp]y[Cc]harm*|*[Ii]ntelli[Jj]*|*[Jj]et[Bb]rains*|*Android\ Studio*) echo "宿主"; return ;;
  esac
  # 各种版本管理器与 conda 的安装根
  case "$p" in
    */mise/*|*/nvm/*|*/fnm/*|*/volta/*|*/asdf/*|*/pyenv/*|*/scoop/*|*/Cellar/*|*homebrew*|*/envs/*|*miniconda*|*anaconda*)
      echo "托管"; return ;;
  esac
  for r in $STANDARD_ROOTS; do
    case "$p" in "$r"/*) echo "公认"; return ;; esac
  done
  case "$p" in "$TOOLS_ROOT"/*) echo "规范根"; return ;; esac
  echo "游离"
}

# ---------- 第 1 阶段：声明层 ----------
declare_mise_files() {
  local dir
  dir="$(pwd)"
  while [ -n "$dir" ]; do
    for f in mise.toml .mise.toml .tool-versions; do
      [ -f "$dir/$f" ] && printf '%s\n' "$dir/$f"
    done
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done
  # 全局声明。XDG_CONFIG_HOME 被设置时 mise 的全局配置会搬走，这里必须跟着走，
  # 否则"声明层"与"漂移检测"会看两个不同的文件，报出的结论互相矛盾。
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    [ -f "$XDG_CONFIG_HOME/mise/config.toml" ] && printf '%s\n' "$XDG_CONFIG_HOME/mise/config.toml"
  fi
  for f in "${HOME}/.config/mise/config.toml" "${HOME}/.tool-versions"; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

DECL_FILES="$(declare_mise_files 2>/dev/null || true)"

# 只列项目作用域的声明文件（当前目录向上），不含全局配置。
# 用于判断"这个项目有没有声明"——全局配置存在不代表项目声明过。
project_decl_files() {
  local dir
  dir="$(pwd)"
  while [ -n "$dir" ]; do
    for f in mise.toml .mise.toml .tool-versions; do
      [ -f "$dir/$f" ] && printf '%s\n' "$dir/$f"
    done
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done
}
PROJECT_DECL_FILES="$(project_decl_files 2>/dev/null || true)"
tick '1. 声明层'

# ---------- 第 2 阶段：mise 纳管层 ----------
MISE_AVAILABLE=0
MISE_TOOLS=""
if command -v mise >/dev/null 2>&1; then
  MISE_AVAILABLE=1
  MISE_TOOLS="$(run_with_timeout 20 mise ls)"
fi
tick '2. mise 纳管层'

# ---------- 第 3 阶段：约定层（带版本号的命名 shim）----------
# 形如 node22 / node-22 / python312 / java8。这类约定只保存在文件名里，
# 换台机器、换个 agent 就彻底失传，所以要主动发现并提醒写进声明文件。
scan_conventions() {
  local dir base tool decl target actual ok
  local IFS_OLD="$IFS"
  # 先给 PATH 去重：重复条目（PATH_DIRT 会单独报告）会让同一目录被扫两遍，
  # 同一个约定就会重复上报一次。
  local seen_dirs=""
  local path_dirs=""
  IFS=':'
  for dir in $PATH; do
    IFS="$IFS_OLD"
    [ -n "$dir" ] || { IFS=':'; continue; }
    case ":$seen_dirs:" in *":$dir:"*) IFS=':'; continue ;; esac
    seen_dirs="${seen_dirs}:$dir"
    path_dirs="${path_dirs}${path_dirs:+
}${dir}"
    IFS=':'
  done
  IFS="$IFS_OLD"

  IFS='
'
  for dir in $path_dirs; do
    IFS="$IFS_OLD"
    [ -d "$dir" ] || continue
    # 性能要点：不要对目录里的每个文件都起进程去判断。
    # 旧写法对每个文件跑一次 grep，遇到 /usr/bin 这种上千文件的目录（Git Bash 下尤其明显）
    # 会卡到分钟级。现在改成：一次 ls 列出文件名 + 一次 grep 过滤，只有命中少数名字
    # 才进入后面的权限检查与版本探测。
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      # 去掉常见可执行后缀
      base="${base%.exe}"; base="${base%.cmd}"; base="${base%.bat}"
      base="${base%.ps1}"; base="${base%.sh}"
      if printf '%s' "$base" | grep -qiE '^(node|nodejs|npm|npx|pnpm|yarn|python|python3|py|pip|uv|java|javac|mvn|gradle|go|cargo|rustc|deno|bun|dotnet|php|ruby)([-_]?v?)[0-9]+(\.[0-9]+){0,3}$'; then
        # python3 / python3.12 / pip3 是跨平台公认的名字，不算本地私有约定
        if printf '%s' "$base" | grep -qiE '^(python|pip)[23](\.[0-9]+){0,2}$'; then continue; fi
        f="$dir/$base"
        # 后缀被剥掉了，回到真实文件名要按候选后缀逐个试
        [ -e "$f" ] || {
          for _ext in .exe .cmd .bat .ps1 .sh; do
            [ -e "$dir/$base$_ext" ] && { f="$dir/$base$_ext"; break; }
          done
        }
        is_real "$f" || continue
        tool="$(printf '%s' "$base" | sed -E 's/^([a-zA-Z]+).*/\1/' | tr 'A-Z' 'a-z')"
        decl="$(printf '%s' "$base" | grep -oE '[0-9]+(\.[0-9]+){0,3}$')"
        # 从 shim 脚本内容里找它真正调用的可执行文件
        target="$f"
        case "$f" in
          *.cmd|*.bat|*.ps1|*.sh)
            local found
            found="$(grep -oE '/[^"'"'"' ]+/(bin/)?[a-zA-Z0-9._-]+' "$f" 2>/dev/null | head -n1 || true)"
            [ -n "$found" ] && [ -x "$found" ] && target="$found"
            ;;
        esac
        actual=""
        case "$tool" in
          node|npm|npx|pnpm|yarn) actual="$("$target" --version 2>&1 | head -n1 || true)" ;;
          python|pip)             actual="$("$target" --version 2>&1 | head -n1 || true)" ;;
          java|javac)             actual="$("$target" -version 2>&1 | head -n1 || true)" ;;
          *)                      actual="$("$target" --version 2>&1 | head -n1 || true)" ;;
        esac
        # targetOk：约定入口最终指向的文件是否真的可执行（对应 census.ps1 的同名字段）。
        # 命中 shim 内容里的目标时 target 就是那个文件；没命中就退回 shim 自身。
        ok="yes"
        [ -x "$target" ] || ok="no"
        add_conv "$base" "$decl" "$actual" "$target" "$ok"
      fi
    done <<EOF
$(ls -1 "$dir" 2>/dev/null | grep -iE '^(node|nodejs|npm|npx|pnpm|yarn|python|python3|py|pip|uv|java|javac|mvn|gradle|go|cargo|rustc|deno|bun|dotnet|php|ruby)[-_]?v?[0-9]' | head -n 200)
EOF
  done
  # 外层循环用换行分隔目录列表（去重后的 path_dirs 是换行拼的），
  # 循环体内先恢复成原始 IFS，避免影响 basename/路径展开。
  IFS="$IFS_OLD"
}
scan_conventions
tick '3. 约定层'

# ---------- 第 4 阶段：定向探测已知安装位置 ----------
# 只做存在性检查，不遍历目录树——一次 stat 比一次目录枚举便宜得多。
probe_path() {
  local p="$1" tool ver src
  [ -f "$p" ] || return 0
  case "$(basename "$p")" in
    node*)   tool=node ;;
    python*) tool=python ;;
    java*)   tool=java ;;
    *) return 0 ;;
  esac
  case "$p" in
    */mise/*)                     src="mise" ;;
    */envs/*|*miniconda*|*anaconda*) src="conda" ;;
    */jbr/*|*pycharm*|*IntelliJ*|*JetBrains*) src="IDE 内置" ;;
    */nvm/*|*fnm/*|*volta/*|*asdf/*|*pyenv/*) src="版本管理器" ;;
    */homebrew/*|*/Cellar/*)      src="homebrew" ;;
    *)                            src="自定义位置" ;;
  esac
  case "$tool" in
    node)   ver="$("$p" --version 2>/dev/null | head -n1 | sed 's/^v//' || true)" ;;
    python) ver="$("$p" --version 2>/dev/null | head -n1 | sed -E 's/^Python //' || true)" ;;
    java)   ver="$("$p" -version 2>&1 | head -n1 | sed -E 's/.*version "([^"]+)".*/\1/' || true)" ;;
  esac
  add_runtime "$tool" "$ver" "$p" "$src" "$(placement_of "$p")" "yes" "$CUR_ROOT" "$CUR_PATTERN"
}

probe_root() {
  local root="$1" rel
  [ -d "$root" ] || return 0
  # 记下这棵树的起点，probe_path 会把它写进记录的 root 字段
  CUR_ROOT="$root"
  for rel in node.exe bin/node python.exe bin/python bin/python3 Scripts/python.exe \
             java.exe bin/java jbr/bin/java jre/bin/java; do
    probe_path "$root/$rel"
  done
  # 第二层：直接子目录。覆盖版本号目录与 IDE 安装目录两种布局。
  local d
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    for rel in node.exe bin/node python.exe bin/python bin/python3 Scripts/python.exe \
               java.exe bin/java jbr/bin/java jre/bin/java; do
      probe_path "${d%/}/$rel"
    done
  done
  # conda 专门处理
  for envdir in envs env; do
    [ -d "$root/$envdir" ] || continue
    for d in "$root/$envdir"/*/; do
      [ -d "$d" ] || continue
      probe_path "${d%/}/python.exe"
      probe_path "${d%/}/bin/python"
    done
  done
}

MISE_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/mise"
CANDIDATE_ROOTS="
$HOME/.nvm/versions/node
$HOME/.fnm
$HOME/.local/share/fnm
$HOME/.volta/tools/image
$HOME/.asdf
$MISE_DATA
$HOME/.pyenv/versions
$HOME/miniconda3
$HOME/anaconda3
$HOME/miniforge3
$HOME/.local/bin
$HOME/.cargo/bin
/opt/homebrew/opt
/usr/local/opt
/usr/local
/opt
/Library/Java/JavaVirtualMachines
/Applications/Android Studio.app/Contents/jbr
$HOME/Applications
"

for r in $CANDIDATE_ROOTS; do probe_root "$r"; done

# PATH 上的目录本身，以及它们的父目录（捕捉 ~/tools/bin -> ~/tools/node22 这类约定）
IFS_OLD="$IFS"; IFS=':'
for d in $PATH; do
  IFS="$IFS_OLD"
  [ -d "$d" ] || { IFS=':'; continue; }
  probe_root "$d"
  parent="$(dirname "$d")"
  case "$parent" in /|"") ;; *) [ -d "$parent" ] && probe_root "$parent" ;; esac
  IFS=':'
done
IFS="$IFS_OLD"

# IDE 内置运行时（JetBrains 的 jbr 里带完整 JDK，最容易被忽略）
for app in /Applications/*.app /Applications/JetBrains/*.app "$HOME"/Applications/*.app; do
  [ -d "$app" ] || continue
  case "$app" in
    *PyCharm*|*IntelliJ*|*WebStorm*|*GoLand*|*Android*Studio*|*IDEA*)
      CUR_ROOT="$app"
      probe_path "$app/Contents/jbr/Contents/Home/bin/java" ;;
  esac
done
# Linux 上的 JetBrains Toolbox 安装位置
for d in "$HOME"/.local/share/JetBrains/Toolbox/apps/*/*/; do
  [ -d "$d" ] || continue
  CUR_ROOT="${d%/}"
  probe_path "${d%/}/jbr/bin/java"
done

# 去重：同一个真实路径只保留一条
# 注意这一步必须在 --deep 深扫之前完成（下面的深扫会再补一批记录）。
RUNTIME_ROWS="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' 'NF>=6 { key=tolower($3); if (!(key in seen)) { seen[key]=1; print } }')"

# ---------- 第 4 阶段补充：--deep 宽松深扫 ----------
# 定向探测只覆盖已知安装布局，装在奇怪位置的运行时只有深扫才看得见。
# 默认关闭：这是唯一非线性的开销来源，所以要限深度、限文件名、限结果条数。
# （census.ps1 的 -Deep 是同一件事：对每个盘符做有深度上限的扫描。）
if [ "$DEEP" -eq 1 ]; then
  # 深扫产出的记录标记为 deep-scan，与 census.ps1 的 -Pattern '(深度扫描)' 对齐：
  # 消费者据此区分"定向探测找到的"和"只有深扫才看得见的"。
  CUR_PATTERN="(深度扫描)"
  for _root in /usr/local /opt /usr/lib "$HOME/.local" "$HOME/opt" "$HOME/.opt" /Applications; do
    [ -d "$_root" ] || continue
    CUR_ROOT="$_root"
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      probe_path "$hit"
    done <<EOF
$(find "$_root" -maxdepth 4 \( -name node -o -name node.exe -o -name python -o -name python.exe -o -name python3 -o -name java -o -name java.exe \) -type f 2>/dev/null | head -n 300)
EOF
  done
  # 深扫结果同样按路径去重
  RUNTIME_ROWS="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' 'NF>=6 { key=tolower($3); if (!(key in seen)) { seen[key]=1; print } }')"
  # 深扫结束，恢复默认标记（后面还有别的记录来源，不该继承深扫标记）
  CUR_PATTERN="定向探测"; CUR_ROOT=""
fi
tick '4. 定向探测'

# ---------- 第 5 阶段：解析层 ----------
RESOLVE_ROWS=""
probe_cmd() {
  local name="$1" resolved ver hits hit hitcount=0 hitlist=""
  resolved="$(command -v "$name" 2>/dev/null || true)"
  [ -n "$resolved" ] || return 0
  # PATH 上有几个同名命令，以及它们分别是谁。只报数量等于把"PATH 是单值命名空间"
  # 这个核心事实丢掉一半：消费者想知道的是"另外那几个在哪儿"。
  # census.ps1 的 allHits 就是这个列表，两边字段必须一一对应。
  hitlist="$(type -a -p "$name" 2>/dev/null | awk '!seen[tolower($0)]++' | tr '\n' ';' | sed 's/;$//')"
  hits="$(printf '%s' "$hitlist" | awk -F';' 'NF{print NF}')"
  hitcount="${hits:-1}"
  ver=""
  case "$name" in
    node)   ver="$("$name" --version 2>/dev/null | head -n1 | sed 's/^v//' || true)" ;;
    npm|npx|pnpm|yarn) ver="$("$name" --version 2>/dev/null | head -n1 || true)" ;;
    python|python3|py|pip|pip3) ver="$("$name" --version 2>/dev/null | head -n1 | sed -E 's/^Python //' || true)" ;;
    java|javac) ver="$("$name" -version 2>&1 | head -n1 | sed -E 's/.*version "([^"]+)".*/\1/' || true)" ;;
    *)      ver="$("$name" --version 2>/dev/null | head -n1 || true)" ;;
  esac
  # usable 作为第 5 列一起记下来：判断"装没装"要用它，
  # 而且 JSON 里与 census.ps1 的 resolution 记录对齐。
  # 第 6 列是这条命令在 PATH 上的全部命中（与 PS 的 allHits 对应）。
  # 注意：第 6 列追加在末尾，读取端必须一起收满，否则最后一个变量会吞掉剩余字段
  # （bash 的 read 把余下内容全给最后一个变量，`[ "$usable" = "no" ]` 这种比较会静默失效）。
  usable="yes"
  is_real "$resolved" || usable="no"
  RESOLVE_ROWS="${RESOLVE_ROWS}${name}|${resolved}|${ver}|${hitcount}|${usable}|${hitlist}
"
  # 解析到不可执行的文件 → 高危告警
  if [ "$usable" = "no" ]; then
    add_warn "STUB" "$name" "$resolved" "command=$name" "path=$resolved"
  fi
}
# 固定列表只是"默认值得看一眼的常见命令"；声明里点名的工具也一并解析，
# 因为这个套件面向的是【所有工具】，不是只认语言的运行时。
DECLARED_CMDS="$(declared_tools | awk -F'|' '{print $1}' | sort -u | tr '\n' ' ')"
for c in node npm npx pnpm yarn python python3 py pip uv java javac mvn gradle go cargo rustc deno bun dotnet mise $DECLARED_CMDS; do
  probe_cmd "$c"
done
tick '5. 解析层'

# ---------- 汇总告警 ----------
# 1) 同一运行时多版本共存，但 PATH 只暴露一个
for tool in node python java; do
  paths="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' -v t="$tool" '$1==t {print $3}')"
  total="$(printf '%s\n' "$paths" | grep -c . || true)"
  [ "${total:-0}" -le 1 ] && continue
  hidden=""
  hcount=0
  # 用 while read 而不是 for 循环：路径里带空格时 for 会把它拆成两个词
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    d="$(dirname "$p")"
    case ":$PATH:" in *":$d:"*) ;; *) hidden="${hidden}${p} | "; hcount=$((hcount+1)) ;; esac
  done <<EOF
$paths
EOF
  hidden="${hidden% | }"
  [ "$hcount" -gt 0 ] || continue
  add_warn "SHADOWED" "$tool" "$hidden" "tool=$tool" "total=$total" "hidden=$hcount"
done

# 2) 自定义命名约定
#    这里必须用 < <(...) 而不是管道：管道里的循环跑在子 shell 里，add_warn 写进
#    WARN_TEXT / WARN_JSON_ITEMS 的内容会随子 shell 一起丢掉。
while IFS='|' read -r shim decl actual target ok; do
  [ -n "$shim" ] || continue
  c_tool="$(printf '%s' "$shim" | sed -E 's/^([a-zA-Z]+).*/\1/' | tr 'A-Z' 'a-z')"
  add_warn "CONVENTION" "$c_tool" "$target" "shim=$shim" "declared=$decl" "actual=$actual"
done < <(printf '%s' "$CONV_ROWS")

# 3) mise 未安装
if [ "$MISE_AVAILABLE" -eq 0 ]; then
  add_warn "NO_MISE" "mise" ""
fi

# 4) 游离运行时：没有任何管理器纳管，也不在公认位置或规范根下
#    只报告不迁移。搬动已有运行时的风险（路径被项目配置、IDE 设置、CI 脚本写死）
#    远大于收益，而"登记到声明文件"能用接近零的成本解决真正的问题——
#    它们目前只靠 PATH 被找到，PATH 一变就没人知道它们在哪儿。
STRAY_ROWS="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' '$5=="游离" && $6=="yes" {print $1" "$2" @ "$3}')"
STRAY_COUNT="$(printf '%s\n' "$STRAY_ROWS" | grep -c . || true)"
if [ "${STRAY_COUNT:-0}" -gt 0 ]; then
  add_warn "STRAY" "stray" "$(printf '%s' "$STRAY_ROWS" | tr '\n' '|' | sed 's/|$//; s/|/ | /g')" \
    "count=$STRAY_COUNT" "root=$TOOLS_ROOT"
fi

# 5) 项目有版本约束，但没有工具读得到的声明文件
#    package.json 的 engines 只在版本不符时给一条警告，它不会切换版本。
#    于是"这个项目需要某个版本"这个事实只存在于 engines 里，用上它得靠人记住某个路径。
if [ -z "$PROJECT_DECL_FILES" ] && [ -f "$(pwd)/package.json" ]; then
  WANT_NODE="$(grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]*"' "$(pwd)/package.json" 2>/dev/null \
    | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  if [ -n "$WANT_NODE" ]; then
    add_warn "UNDECLARED" "node" "" "wanted=$WANT_NODE"
  fi
fi

# 6) 声明与部署副本漂移：模板代表"这台机器想要的状态"，部署副本是"现在实际声明的状态"。
#    两份文件之间没有同步机制，模板里新加的工具会永远装不上，而报告显示一切正常。
DEPLOYED_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml"
TEMPLATE_CFG="$SCRIPT_DIR/../templates/mise-config.toml"
if [ -f "$TEMPLATE_CFG" ] && [ -f "$DEPLOYED_CFG" ] && ! cmp -s "$TEMPLATE_CFG" "$DEPLOYED_CFG"; then
  ONLY_TPL="$(comm -23 <(tools_keys "$TEMPLATE_CFG") <(tools_keys "$DEPLOYED_CFG") | grep -v '^$' | tr '\n' ' ' || true)"
  ONLY_DEP="$(comm -13 <(tools_keys "$TEMPLATE_CFG") <(tools_keys "$DEPLOYED_CFG") | grep -v '^$' | tr '\n' ' ' || true)"
  DRIFT_DETAIL=""
  [ -n "$ONLY_TPL" ] && DRIFT_DETAIL="$(T 'drift.onlyTpl' "keys=$ONLY_TPL")"
  [ -n "$ONLY_DEP" ] && DRIFT_DETAIL="${DRIFT_DETAIL}$( [ -n "$DRIFT_DETAIL" ] && T 'drift.join' || true )$(T 'drift.onlyDep' "keys=$ONLY_DEP")"
  [ -n "$DRIFT_DETAIL" ] || DRIFT_DETAIL="$(T 'drift.sameKeys')"
  add_warn "DRIFT" "mise" "$DRIFT_DETAIL" "deployed=$DEPLOYED_CFG"
fi

# 7) XDG_CONFIG_HOME 被设置：mise 的"全局"配置会搬家
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  add_warn "XDG_SHIFT" "mise" "" \
    "xdg=$XDG_CONFIG_HOME" "config=${XDG_CONFIG_HOME}/mise/config.toml"
fi

# 8) PATH 里的重复条目
PATH_DUPES="$(printf '%s' "$PATH" | tr ':' '\n' | awk 'NF' | sort | uniq -d)"
if [ -n "$PATH_DUPES" ]; then
  d_parts="$(T 'dirt.dupes' "n=$(printf '%s\n' "$PATH_DUPES" | grep -c . || true)")"
  add_warn "PATH_DIRT" "PATH" "$(printf '%s' "$PATH_DUPES" | tr '\n' '|' | sed 's/|$//; s/|/ | /g')" \
    "parts=$d_parts"
fi

# 9) 声明被 PATH 顺序遮蔽：声明要求某个版本、mise 也装了，但解析到的副本连"满足声明"
#    都谈不上（解析到的版本本来就符合声明就不报，见 version_satisfies）。
#    Unix 上同样成立——/usr/local/bin/node 之类排在 mise 的 shims 之前就会这样。
#    用 < <(...) 而不是管道：管道里的循环是子 shell，add_warn 写进去的告警会丢掉。
while IFS='|' read -r d_tool d_ver d_src; do
  [ -n "$d_tool" ] || continue
  s_tool="$(short_tool "$d_tool")"
  m_ver="$(mise_version "$s_tool" "$d_ver")"
  [ -n "$m_ver" ] || continue
  case "$s_tool" in
    node)   d_cmds="node npm npx pnpm yarn" ;;
    # 注意不含 pip：pip --version 报的是 pip 自己的版本（如 25.0.1），
    # 拿它和"声明要求 python 3.12"比是范畴错误，只会造成误报。
    # 下面的清单必须与 census.ps1 的解析名单完全一致。
    python) d_cmds="python python3 py" ;;
    *)      d_cmds="$s_tool" ;;
  esac
  for c in $d_cmds; do
    r_path="$(printf '%s' "$RESOLVE_ROWS" | awk -F'|' -v c="$c" '$1==c {print $2; exit}')"
    [ -n "$r_path" ] || continue
    case "$r_path" in */mise/*) continue ;; esac
    r_ver="$(printf '%s' "$RESOLVE_ROWS" | awk -F'|' -v c="$c" '$1==c {print $3; exit}')"
    # 解析到的副本本来就满足声明就不报（版本是对的，只是不是 mise 那一份）；
    # 与 census.ps1 的 Test-VersionSatisfies 判断一致。
    version_satisfies "$r_ver" "$d_ver" && continue
    add_warn "PATH_ORDER" "$c" "" \
      "tool=$d_tool" "wanted=$d_ver" "file=$d_src" "have=$m_ver" \
      "command=$c" "path=$r_path" "version=$r_ver"
  done
done < <(declared_tools)

# 10) 声明了但没装
while IFS='|' read -r d_tool d_ver d_src; do
  [ -n "$d_tool" ] || continue
  s_tool="$(short_tool "$d_tool")"
  [ -n "$(mise_version "$s_tool")" ] && continue
  runtime_installed "$s_tool" && continue
  # PATH 上能解析到、而且真的能执行，就算装了——工具可能不在运行时清单里
  # （声明里写 jadx / nmap / ffmpeg 就是这种情况）。
  r_ok="$(printf '%s' "$RESOLVE_ROWS" | awk -F'|' -v c="$s_tool" '$1==c && $5!="no" {found=1} END{print (found ? "yes" : "no")}')"
  [ "$r_ok" = "yes" ] && continue
  add_warn "MISSING" "$s_tool" "$d_src" \
    "tool=$d_tool" "wanted=$d_ver" "file=$d_src"
done < <(declared_tools)
tick '6. 汇总告警'

# ---------- 输出 ----------
if [ "$JSON" -eq 1 ]; then
  # JSON 里的每个字符串字段都必须转义。实测踩过的坑：pip --version 会打印
  # "...from C:\Users\...\site-packages\pip (python 3.12)"，里面的 \U 这种序列
  # 会让整个 JSON 非法，ConvertFrom-Json / jq 直接报 "Unrecognized escape sequence"。
  # awk 的 esc() 负责反斜杠、双引号和控制字符，三个数组块共用。
  AWK_ESC='function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\r\n\t]/, " ", s); return s }
           # 从 shim 路径里取出文件名（census.ps1 的 shimName）
           function bname(s) { sub(/.*\//, "", s); return s }
           # 从 shim 文件名反推工具名：node22.cmd -> node、python3.12 -> python
           function toolof(s,   b) {
             b = bname(s); sub(/\.[A-Za-z0-9]+$/, "", b); sub(/[-_]?[vV]?[0-9].*/, "", b)
             return tolower(b)
           }
           # 把 "a;b;c" 形式的列表变成 JSON 字符串数组。空值输出 []（不是 [""]）。
           function arr(s,   n, i, parts, out) {
             if (s == "") return ""
             n = split(s, parts, ";"); out = ""
             for (i = 1; i <= n; i++) { if (parts[i] == "") continue; out = out (out == "" ? "" : ", ") "\"" esc(parts[i]) "\"" }
             return out
           }
           function sk(s) {
             if (s == "托管") return "managed"; if (s == "宿主") return "host";
             if (s == "公认") return "standard"; if (s == "规范根") return "canonical";
             if (s == "游离") return "stray"; if (s == "系统安装") return "system";
             if (s == "IDE 内置") return "ide"; if (s == "自定义位置") return "custom";
             if (s == "版本管理器") return "version-manager";
             # 发现阶段标记：必须与上面的 stable_key() 保持一致（两份表各自漂移过一次）
             if (s == "定向探测") return "probe"; if (s == "(深度扫描)") return "deep-scan";
             return s
           }'
  printf '{\n'
  # schemaVersion 与字段结构必须与 census.ps1 完全一致：
  # Agent / CI 跨平台消费同一份 JSON 时，不该为"哪个平台"写两套解析逻辑。
  printf '  "schemaVersion": 1,\n'
  printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "host": {"os": "%s", "arch": "%s", "user": "%s", "cwd": "%s"},\n' \
    "$(uname -s)" "$(uname -m)" "$(whoami)" "$(json_escape "$(pwd)")"

  # declarations：声明文件 + 它们声明的工具（按文件聚合，与 census.ps1 的结构一致）
  printf '  "declarations": ['
  _first=1
  for _f in $DECL_FILES; do
    _scope="project"
    case "$_f" in
      "$HOME"/*|"$HOME"|"${XDG_CONFIG_HOME:-/nonexistent}"/*) _scope="global" ;;
    esac
    _tools="$(declared_tools | awk -F'|' -v s="$_f" '$3==s {printf "%s\"%s\": \"%s\"", (n++ ? ", " : ""), $1, $2}')"
    if [ "$_first" -eq 1 ]; then printf '\n'; _first=0; else printf ',\n'; fi
    printf '    {"scope": "%s", "path": "%s", "tools": {%s}}' \
      "$_scope" "$(json_escape "$_f")" "$_tools"
  done
  [ "$_first" -eq 1 ] || printf '\n'
  printf '  ],\n'

  printf '  "toolsRoot": "%s",\n' "$(json_escape "$TOOLS_ROOT")"
  printf '  "mise": {"available": %s, "tools": [' "$([ "$MISE_AVAILABLE" -eq 1 ] && echo true || echo false)"
  printf '%s' "$MISE_TOOLS" | awk -F'[ \t]+' "$AWK_ESC"' NF>=2 {printf "%s{\"tool\": \"%s\", \"version\": \"%s\", \"requested\": \"%s\"}", (NR>1?", ":""), esc($1), esc($2), esc($NF)}'
  printf ']},\n'
  printf '  "conventions": [\n'
  printf '%s' "$CONV_ROWS" | awk -F'|' "$AWK_ESC"' NF>=4 {printf "%s    {\"shim\": \"%s\", \"shimName\": \"%s\", \"tool\": \"%s\", \"nameVersion\": \"%s\", \"target\": \"%s\", \"targetOk\": %s, \"actualVersion\": \"%s\", \"source\": \"convention\", \"managed\": false}", (NR>1?",\n":""), esc($1), esc(bname($1)), esc(toolof($1)), esc($2), esc($4), ($5 == "no" ? "false" : "true"), esc($3)}'
  printf '\n  ],\n'
  printf '  "runtimes": [\n'
  printf '%s' "$RUNTIME_ROWS" | awk -F'|' "$AWK_ESC"' NF>=6 {printf "%s    {\"tool\": \"%s\", \"version\": \"%s\", \"path\": \"%s\", \"source\": \"%s\", \"placement\": \"%s\", \"managed\": %s, \"real\": %s, \"root\": \"%s\", \"pattern\": \"%s\"}", (NR>1?",\n":""), esc($1), esc($2), esc($3), sk($4), sk($5), ($3 ~ /\/mise\// ? "true" : "false"), ($6 == "yes" ? "true" : "false"), esc($7), sk($8)}'
  printf '\n  ],\n'
  printf '  "resolution": [\n'
  printf '%s' "$RESOLVE_ROWS" | awk -F'|' "$AWK_ESC"' NF>=4 {printf "%s    {\"command\": \"%s\", \"resolvesTo\": \"%s\", \"version\": \"%s\", \"allHits\": [%s], \"hitCount\": %s, \"stub\": %s, \"usable\": %s}", (NR>1?",\n":""), esc($1), esc($2), esc($3), arr($6), $4, ($5 == "no" ? "true" : "false"), ($5 == "no" ? "false" : "true")}'
  printf '\n  ],\n'
  printf '  "warnings": [%s],\n' "$WARN_JSON_ITEMS"
  printf '  "timings": [%s],\n' "$TIMING_JSON_ITEMS"

  # summary：与 census.ps1 对齐（runtimeCount / warningCount / byTool）
  # 逐工具构造，不要在一个 awk 里同时管"开数组/加逗号/收尾"——那种写法极易漏逗号，
  # 上一版就是这么把 byTool 拼成非法 JSON 的（parity 测试立刻抓到了）。
  _bytool=""
  _sep=""
  for _t in $(printf '%s' "$RUNTIME_ROWS" | awk -F'|' '$1 != "" {print $1}' | sort -u); do
    _vers="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' -v t="$_t" '$1==t && !seen[$2]++ {printf "%s\"%s\"", (n++ ? ", " : ""), $2}')"
    _bytool="${_bytool}${_sep}\"${_t}\": [${_vers}]"
    _sep=", "
  done
  printf '  "summary": {"runtimeCount": %s, "warningCount": %s, "byTool": {%s}}\n' \
    "$(printf '%s\n' "$RUNTIME_ROWS" | grep -c . || true)" \
    "$(printf '%s\n' "$WARN_TEXT" | grep -c '^\[' || true)" \
    "$_bytool"
  printf '}\n'
  exit 0
fi

echo
echo " $(T 'title')"
echo " $(T 'meta' "time=$(date '+%Y-%m-%dT%H:%M:%S')" "user=$(whoami)" "arch=$(uname -m)" "cwd=$(pwd)")"

sec "$(T 'sec.decl')"
if [ -z "$DECL_FILES" ]; then
  note "$(T 'no.decl')"
else
  for f in $DECL_FILES; do
    note "$f"
    grep -vE '^\s*(#|$)' "$f" 2>/dev/null | sed 's/^/        /'
  done
fi

sec "$(T 'sec.managed')"
if [ "$MISE_AVAILABLE" -eq 0 ]; then
  note "$(T 'no.mise')"
elif [ -z "$MISE_TOOLS" ]; then
  note "$(T 'no.managed')"
else
  printf '%s\n' "$MISE_TOOLS" | sed 's/^/  /'
fi

sec "$(T 'sec.conv')"
if [ -z "$CONV_ROWS" ]; then
  note "$(T 'no.conv')"
else
  printf '%s' "$CONV_ROWS" | while IFS='|' read -r shim decl actual target ok; do
    [ -n "$shim" ] || continue
    _state="$(T 'state.ok')"
    [ "$ok" = "yes" ] || _state="$(T 'state.bad')"
    echo "  $(T 'conv.line' "shim=$shim" "declared=$decl" "actual=$actual" "state=$_state")"
    echo "        -> $target"
  done
fi

sec "$(T 'sec.inv')"
# 这一节把每条运行时连同它的来源与位置一起打印。来源/位置内部是固定中文取值，
# 显示时经 label_text 映射到当前语言（JSON 那边则换成 ASCII 键）。
# inv_current 必须在循环前初始化：脚本开着 set -u，未定义变量会让整个循环直接退出。
inv_current=""
while IFS='|' read -r r_tool r_ver r_path r_src r_place r_usable r_root r_pattern; do
  [ -n "$r_tool" ] || continue
  if [ "$r_tool" != "$inv_current" ]; then
    inv_current="$r_tool"
    cnt="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' -v t="$r_tool" '$1==t' | grep -c . || true)"
    echo "  $(T 'inv.count' "tool=$(printf '%s' "$r_tool" | tr 'a-z' 'A-Z')" "count=$cnt")"
  fi
  flags="$(label_text "$r_src")"
  if [ "$r_usable" = "yes" ]; then
    [ "$r_place" = "游离" ]   && flags="${flags} | $(T 'lbl.游离位置')"
    [ "$r_place" = "规范根" ] && flags="${flags} | $(T 'lbl.规范根')"
  else
    flags="${flags} | $(T 'lbl.不可用')"
  fi
  printf '    %-16s %s\n' "$r_ver" "$r_path"
  printf '                   [%s]\n' "$flags"
done < <(printf '%s\n' "$RUNTIME_ROWS" | sort -t'|' -k1,1)

sec "$(T 'sec.res')"
while IFS='|' read -r cmd resolved ver hits usable hitlist; do
  [ -n "$cmd" ] || continue
  if [ "${hits:-1}" -gt 1 ]; then
    echo "  $(T 'res.hits' "command=$cmd" "path=$resolved" "version=$ver" "hits=$hits")"
  else
    echo "  $(T 'res.line' "command=$cmd" "path=$resolved" "version=$ver")"
  fi
  # 解析到不可执行的文件 → 就地标出来
  [ "$usable" = "no" ] && echo "             $(T 'res.stub')"
done < <(printf '%s' "$RESOLVE_ROWS" | sort)

sec "$(T 'sec.warn')"
if [ -z "$WARN_TEXT" ]; then
  echo "  $(T 'no.warn')"
else
  printf '%s' "$WARN_TEXT" | sed 's/^/  /'
fi

sec "$(T 'sec.summary')"
note "$(T 'sum.runtimes' "count=$(printf '%s\n' "$RUNTIME_ROWS" | grep -c . || true)")"
# 按工具统计版本数
for tool in node python java; do
  versions="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' -v t="$tool" '$1==t {print $2}' | sort -u | grep -v '^$' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  [ -n "$versions" ] || continue
  vcount="$(printf '%s' "$versions" | awk -F', ' '{print NF}')"
  note "$(T 'sum.byTool' "tool=$tool" "count=$vcount" "versions=$versions")"
done
# 位置分布：一眼看出有多少运行时是"只靠 PATH 被记住"的
PLACEMENT_TEXT="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' '$6=="yes" {c[$5]++} END {
  split("托管 宿主 公认 规范根 游离", order, " ")
  out = ""
  for (i = 1; i <= 5; i++) { k = order[i]; if (c[k] > 0) out = out (out == "" ? "" : "|") k " " c[k] }
  print out
}')"
PLACEMENT_PRETTY=""
_old_ifs="$IFS"; IFS='|'
for seg in $PLACEMENT_TEXT; do
  IFS="$_old_ifs"
  [ -n "$seg" ] || { IFS='|'; continue; }
  k="${seg%% *}"; n="${seg##* }"
  PLACEMENT_PRETTY="${PLACEMENT_PRETTY}$( [ -n "$PLACEMENT_PRETTY" ] && printf '  /  ' )$(label_text "$k") $n"
  IFS='|'
done
IFS="$_old_ifs"
note "$(T 'sum.placement' "text=$PLACEMENT_PRETTY")"
note "$(T 'sum.root' "root=$TOOLS_ROOT")"
note "$(T 'sum.warnings' "count=$(printf '%s\n' "$WARN_TEXT" | grep -c '^\[' || true)")"
if [ "$TIMING" -eq 1 ]; then
  sec "$(T 'sec.timing')"
  # 阶段名经 label_text 映射；JSON 那边用的是 stable_key 的 ASCII 键
  while IFS='|' read -r _ph _sec; do
    [ -n "$_ph" ] || continue
    printf '  %-24s %6s s\n' "$(label_text "$_ph")" "$_sec"
  done <<EOF
$TIMING_ROWS
EOF
fi
echo

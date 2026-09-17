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
#
set -uo pipefail

JSON=0
DEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --deep) DEEP=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

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

# ---------- 数据收集 ----------
RUNTIME_ROWS=""      # tool|version|path|source|placement|usable
CONV_ROWS=""         # shim|shimVersion|actualVersion|target|usable
WARN_JSON="[]"
WARN_TEXT=""

add_runtime() { RUNTIME_ROWS="${RUNTIME_ROWS}${1}|${2}|${3}|${4}|${5}
"; }
add_conv()    { CONV_ROWS="${CONV_ROWS}${1}|${2}|${3}|${4}|${5}
"; }
add_warn()    { WARN_TEXT="${WARN_TEXT}[$1] $2
        $3
"; }

# 判断文件是否"真的可执行"：存在、非常规文件、非 0 字节。
# 0 字节的假文件在 Windows 上很常见（商店应用别名），Unix 上少见但仍需防。
is_real() {
  [ -f "$1" ] && [ -s "$1" ] && [ -x "$1" ]
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
  for f in "${HOME}/.config/mise/config.toml" "${HOME}/.tool-versions"; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

DECL_FILES="$(declare_mise_files 2>/dev/null || true)"

# ---------- 第 2 阶段：mise 纳管层 ----------
MISE_AVAILABLE=0
MISE_TOOLS=""
if command -v mise >/dev/null 2>&1; then
  MISE_AVAILABLE=1
  MISE_TOOLS="$(mise ls 2>/dev/null || true)"
fi

# ---------- 第 3 阶段：约定层（带版本号的命名 shim）----------
# 形如 node22 / node-22 / python312 / java8。这类约定只保存在文件名里，
# 换台机器、换个 agent 就彻底失传，所以要主动发现并提醒写进声明文件。
scan_conventions() {
  local dir base tool decl target actual
  local IFS_OLD="$IFS"
  IFS=':'
  for dir in $PATH; do
    IFS="$IFS_OLD"
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      # 去掉常见可执行后缀
      base="${base%.exe}"; base="${base%.cmd}"; base="${base%.bat}"
      base="${base%.ps1}"; base="${base%.sh}"
      if printf '%s' "$base" | grep -qiE '^(node|nodejs|npm|npx|pnpm|yarn|python|python3|py|pip|uv|java|javac|mvn|gradle|go|cargo|rustc|deno|bun|dotnet|php|ruby)([-_]?v?)[0-9]+(\.[0-9]+){0,3}$'; then
        # python3 / python3.12 / pip3 是跨平台公认的名字，不算本地私有约定
        if printf '%s' "$base" | grep -qiE '^(python|pip)[23](\.[0-9]+){0,2}$'; then continue; fi
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
        add_conv "$base" "$decl" "$actual" "$target" "yes"
      fi
    done
    IFS=':'
  done
  IFS="$IFS_OLD"
}
scan_conventions

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
  add_runtime "$tool" "$ver" "$p" "$src" "$(placement_of "$p")" "yes"
}

probe_root() {
  local root="$1" rel
  [ -d "$root" ] || return 0
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
      probe_path "$app/Contents/jbr/Contents/Home/bin/java" ;;
  esac
done
# Linux 上的 JetBrains Toolbox 安装位置
for d in "$HOME"/.local/share/JetBrains/Toolbox/apps/*/*/; do
  [ -d "$d" ] || continue
  probe_path "${d%/}/jbr/bin/java"
done

# 去重：同一个真实路径只保留一条
RUNTIME_ROWS="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' 'NF>=6 { key=tolower($3); if (!(key in seen)) { seen[key]=1; print } }')"

# ---------- 第 5 阶段：解析层 ----------
RESOLVE_ROWS=""
probe_cmd() {
  local name="$1" resolved ver hits hit hitcount=0
  resolved="$(command -v "$name" 2>/dev/null || true)"
  [ -n "$resolved" ] || return 0
  # 数一数 PATH 上有几个同名命令
  hits="$(type -a -p "$name" 2>/dev/null | awk '!seen[tolower($0)]++' | wc -l | tr -d ' ')"
  hitcount="${hits:-1}"
  ver=""
  case "$name" in
    node)   ver="$("$name" --version 2>/dev/null | head -n1 | sed 's/^v//' || true)" ;;
    npm|npx|pnpm|yarn) ver="$("$name" --version 2>/dev/null | head -n1 || true)" ;;
    python|python3|py|pip|pip3) ver="$("$name" --version 2>/dev/null | head -n1 | sed -E 's/^Python //' || true)" ;;
    java|javac) ver="$("$name" -version 2>&1 | head -n1 | sed -E 's/.*version "([^"]+)".*/\1/' || true)" ;;
    *)      ver="$("$name" --version 2>/dev/null | head -n1 || true)" ;;
  esac
  RESOLVE_ROWS="${RESOLVE_ROWS}${name}|${resolved}|${ver}|${hitcount}
"
  # 解析到不可执行的文件 → 高危告警
  if ! is_real "$resolved"; then
    add_warn "STUB" "命令 '${name}' 解析到 '${resolved}'，但该文件不可执行。执行会失败。" "$resolved"
  fi
}
for c in node npm npx pnpm yarn python python3 py pip uv java javac mvn gradle go cargo rustc deno bun dotnet mise; do
  probe_cmd "$c"
done

# ---------- 汇总告警 ----------
# 1) 同一运行时多版本共存，但 PATH 只暴露一个
for tool in node python java; do
  paths="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' -v t="$tool" '$1==t {print $3}')"
  total="$(printf '%s\n' "$paths" | grep -c . || true)"
  [ "${total:-0}" -le 1 ] && continue
  hidden=""
  for p in $paths; do
    d="$(dirname "$p")"
    case ":$PATH:" in *":$d:"*) ;; *) hidden="${hidden}${p} | " ;; esac
  done
  hidden="${hidden% | }"
  [ -n "$hidden" ] || continue
  add_warn "SHADOWED" "'${tool}' 在磁盘上有 ${total} 个副本，其中一部分不在 PATH 上，无法被直接调用。" "$hidden"
done

# 2) 自定义命名约定
printf '%s' "$CONV_ROWS" | while IFS='|' read -r shim decl actual target ok; do
  [ -n "$shim" ] || continue
  printf '[CONVENTION] 发现自定义命名约定 %s（文件名声明 %s，实际 %s）。这类约定必须写进声明文件否则会失传。\n        %s\n' \
    "$shim" "$decl" "$actual" "$target" >&2
done

# 3) mise 未安装
if [ "$MISE_AVAILABLE" -eq 0 ]; then
  add_warn "NO_MISE" "本机未安装 mise。运行时只能靠 PATH 解析，无法按项目自动切换版本。执行 scripts/bootstrap.sh 可一键建立。" ""
fi

# 4) 游离运行时：没有任何管理器纳管，也不在公认位置或规范根下
#    只报告不迁移。搬动已有运行时的风险（路径被项目配置、IDE 设置、CI 脚本写死）
#    远大于收益，而"登记到声明文件"能用接近零的成本解决真正的问题——
#    它们目前只靠 PATH 被找到，PATH 一变就没人知道它们在哪儿。
STRAY_ROWS="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' '$5=="游离" && $6=="yes" {print $1" "$2" @ "$3}')"
STRAY_COUNT="$(printf '%s\n' "$STRAY_ROWS" | grep -c . || true)"
if [ "${STRAY_COUNT:-0}" -gt 0 ]; then
  add_warn "STRAY" \
    "有 ${STRAY_COUNT} 个运行时放在非规范位置，且没有任何管理器纳管它们。它们只靠 PATH 被找到——PATH 一变就失传。建议登记到声明文件；今后新装的运行时请落在 ${TOOLS_ROOT}。" \
    "$(printf '%s' "$STRAY_ROWS" | tr '\n' '|' | sed 's/|$//; s/|/ | /g')"
fi

# ---------- 输出 ----------
if [ "$JSON" -eq 1 ]; then
  printf '{\n'
  printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "host": {"os": "%s", "arch": "%s", "user": "%s", "cwd": "%s"},\n' \
    "$(uname -s)" "$(uname -m)" "$(whoami)" "$(json_escape "$(pwd)")"
  printf '  "miseAvailable": %s,\n' "$([ "$MISE_AVAILABLE" -eq 1 ] && echo true || echo false)"
  printf '  "toolsRoot": "%s",\n' "$(json_escape "$TOOLS_ROOT")"
  printf '  "runtimes": [\n'
  printf '%s' "$RUNTIME_ROWS" | awk -F'|' 'NF>=6 {printf "%s    {\"tool\": \"%s\", \"version\": \"%s\", \"path\": \"%s\", \"source\": \"%s\", \"placement\": \"%s\"}", (NR>1?",\n":""), $1, $2, $3, $4, $5}'
  printf '\n  ],\n'
  printf '  "conventions": [\n'
  printf '%s' "$CONV_ROWS" | awk -F'|' 'NF>=4 {printf "%s    {\"shim\": \"%s\", \"nameVersion\": \"%s\", \"actualVersion\": \"%s\", \"target\": \"%s\"}", (NR>1?",\n":""), $1, $2, $3, $4}'
  printf '\n  ],\n'
  printf '  "resolution": [\n'
  printf '%s' "$RESOLVE_ROWS" | awk -F'|' 'NF>=4 {printf "%s    {\"command\": \"%s\", \"resolvesTo\": \"%s\", \"version\": \"%s\", \"hitCount\": %s}", (NR>1?",\n":""), $1, $2, $3, $4}'
  printf '\n  ]\n}\n'
  exit 0
fi

echo
echo " 运行时普查报告 (census)"
echo " 生成时间: $(date '+%Y-%m-%dT%H:%M:%S')   主机: $(whoami)@$(uname -m)   当前目录: $(pwd)"

sec '1. 声明层 —— 谁在要求什么版本'
if [ -z "$DECL_FILES" ]; then
  note "（未发现任何 mise.toml / .tool-versions 声明）"
else
  for f in $DECL_FILES; do
    note "$f"
    grep -vE '^\s*(#|$)' "$f" 2>/dev/null | sed 's/^/        /'
  done
fi

sec '2. 纳管层 —— mise 管理的运行时'
if [ "$MISE_AVAILABLE" -eq 0 ]; then
  note "mise 未安装（PATH 上找不到）。"
elif [ -z "$MISE_TOOLS" ]; then
  note "mise 已安装，但尚未纳管任何运行时。"
else
  printf '%s\n' "$MISE_TOOLS" | sed 's/^/  /'
fi

sec '3. 约定层 —— 带版本号的命名 shim（最容易失传的约定）'
if [ -z "$CONV_ROWS" ]; then
  note "（未发现）"
else
  printf '%s' "$CONV_ROWS" | while IFS='|' read -r shim decl actual target ok; do
    [ -n "$shim" ] || continue
    printf '  %-16s 名称声明 %-12s 实际 %-24s\n        -> %s\n' "$shim" "$decl" "$actual" "$target"
  done
fi

sec '4. 运行时清单 —— 磁盘上实际存在的运行时（含纳管与未纳管）'
for tool in node python java; do
  cnt="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' -v t="$tool" '$1==t' | grep -c . || true)"
  [ "${cnt:-0}" -eq 0 ] && continue
  echo "  $(printf '%s' "$tool" | tr 'a-z' 'A-Z')  共 ${cnt} 个"
  printf '%s' "$RUNTIME_ROWS" | awk -F'|' -v t="$tool" '$1==t {
      extra = "";
      if ($6 == "yes" && $5 == "游离")   extra = " | 游离位置";
      if ($6 == "yes" && $5 == "规范根") extra = " | 规范根";
      if ($6 != "yes")                   extra = " | 不可用";
      printf "    %-16s %s\n                   [%s%s]\n", $2, $3, $4, extra
    }'
done

sec '5. 解析层 —— 命令实际解析到哪'
printf '%s' "$RESOLVE_ROWS" | while IFS='|' read -r cmd resolved ver hits; do
  [ -n "$cmd" ] || continue
  if [ "${hits:-1}" -gt 1 ]; then
    printf '  %-9s -> %s  (%s)  [%s 个 PATH 命中]\n' "$cmd" "$resolved" "$ver" "$hits"
  else
    printf '  %-9s -> %s  (%s)\n' "$cmd" "$resolved" "$ver"
  fi
done

sec '6. 告警 —— 需要人工确认的问题'
if [ -z "$WARN_TEXT" ]; then
  echo "  未发现问题。"
else
  printf '%s' "$WARN_TEXT" | sed 's/^/  /'
fi

sec '汇总'
note "发现的运行时条目数: $(printf '%s\n' "$RUNTIME_ROWS" | grep -c . || true)"
# 位置分布：一眼看出有多少运行时是"只靠 PATH 被记住"的
PLACEMENT_TEXT="$(printf '%s' "$RUNTIME_ROWS" | awk -F'|' '$6=="yes" {c[$5]++} END {
  split("托管 宿主 公认 规范根 游离", order, " ")
  out = ""
  for (i = 1; i <= 5; i++) { k = order[i]; if (c[k] > 0) out = out (out == "" ? "" : "  /  ") k " " c[k] }
  print out
}')"
note "位置分布: $PLACEMENT_TEXT"
note "规范根:   $TOOLS_ROOT"
note "告警数量: $(printf '%s\n' "$WARN_TEXT" | grep -c '^\[' || true)"
echo

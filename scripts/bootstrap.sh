#!/usr/bin/env bash
#
# 一键把本机改造成"声明式工具链"模式：装好 mise、写入机器声明、配好 PATH。
#
# 与 scripts/bootstrap.ps1 是同一套设计的 Unix 实现。
#
# 用法:
#   ./bootstrap.sh --dry-run        只打印将要执行的改动
#   ./bootstrap.sh                  实际执行
#   ./bootstrap.sh --no-rc          不修改 shell 启动文件
#   ./bootstrap.sh --skip-tools     只装 mise 和配置，不拉取运行时
#   ./bootstrap.sh --refresh-config 用模板覆盖已部署的全局声明（覆盖前先备份）
#
set -uo pipefail

DRY_RUN=0
NO_RC=0
SKIP_TOOLS=0
REFRESH_CONFIG=0
TOOLS_ROOT=""
# 模板刻意不放在 mise/ 目录下：mise 会把 <任意目录>/mise/config.toml 当成项目配置自动读取，
# 放那里会让仓库本身被当成一个"未授权的 mise 项目"。
CONFIG_SOURCE="$(cd "$(dirname "$0")/.." && pwd)/templates/mise-config.toml"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --no-rc)      NO_RC=1; shift ;;
    --skip-tools) SKIP_TOOLS=1; shift ;;
    --refresh-config) REFRESH_CONFIG=1; shift ;;
    --config)     CONFIG_SOURCE="$2"; shift 2 ;;
    --tools-root) TOOLS_ROOT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

# 规范根：非托管的手装运行时的落脚点，按 <工具>/<版本>/ 排列。
# 优先级：命令行参数 > 环境变量 TOOLCHAIN_ROOT > 默认 ~/toolchains。
[ -n "$TOOLS_ROOT" ] || TOOLS_ROOT="${TOOLCHAIN_ROOT:-$HOME/toolchains}"

step()    { printf '\n==> %s\n' "$1"; }
ok()      { printf '    [完成] %s\n' "$1"; }
skip()    { printf '    [跳过] %s\n' "$1"; }
warn()    { printf '    [注意] %s\n' "$1"; }
plan()    { printf '    [计划] %s\n' "$1"; }
# 只在真正执行过之后才宣告完成；空运行模式下什么都不说，避免造成"已经改了"的错觉
done_msg() { [ "$DRY_RUN" -eq 1 ] || ok "$1"; }

# 执行一条命令；--dry-run 时只打印
run_action() {
  local desc="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then plan "$desc"; return 0; fi
  "$@"
}

MISE_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/mise"
MISE_SHIMS="$MISE_DATA/shims"
MISE_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml"

printf '\n 工具链引导脚本 bootstrap.sh\n'
printf ' 目标：把本机改造成声明式工具链模式\n'
[ "$DRY_RUN" -eq 1 ] && printf ' 模式：空运行（不会修改任何东西）\n'

# ============================================================
# 步骤 0：环境自检
# ============================================================
step '环境自检'
ok "$(uname -s) $(uname -m)"

PKG_MANAGERS=""
for pm in brew apt dnf pacman zypper apk; do
  if command -v "$pm" >/dev/null 2>&1; then
    PKG_MANAGERS="$PKG_MANAGERS $pm"
    ok "找到包管理器: $pm"
  fi
done

# ============================================================
# 步骤 1：安装 mise
# ============================================================
step '安装 mise'

if command -v mise >/dev/null 2>&1; then
  skip "mise 已安装: $(mise --version 2>&1 | head -n1)（位置 $(command -v mise)）"
else
  installed=0
  # 官方推荐：单文件安装脚本，性能最好，且支持 mise self-update
  if [ "$installed" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      plan '通过官方脚本安装 mise（curl -fsSL https://mise.run | sh）'
    else
      if curl -fsSL https://mise.run | sh; then
        ok 'mise 已安装到 ~/.local/bin/mise'
      else
        warn '官方脚本安装失败，继续尝试包管理器'
      fi
    fi
    installed=1
  fi
  if [ "$installed" -eq 0 ] && printf '%s' "$PKG_MANAGERS" | grep -q brew; then
    run_action '通过 Homebrew 安装 mise' brew install mise
    installed=1
  fi
  if [ "$installed" -eq 0 ]; then
    warn '请手工安装 mise，参考 https://mise.jdx.dev/installing-mise.html'
    [ "$DRY_RUN" -eq 0 ] && exit 1
  fi
  warn '安装完成后需要重开终端，或先 export PATH="$HOME/.local/bin:$PATH"'
fi

# ============================================================
# 步骤 2：写入全局机器声明
# ============================================================
step '写入全局机器声明'

if [ ! -f "$CONFIG_SOURCE" ]; then
  warn "找不到配置模板: $CONFIG_SOURCE"
else
  ok "模板: $CONFIG_SOURCE"
  ok "目标: $MISE_CONFIG_FILE"

  # 取出 [tools] 段的键名。用 awk 而不是解析 TOML：这里只需要知道"声明了哪些工具"，
  # 不关心数组、嵌套表这些细节，够用且零依赖。
  # 开头先剥掉可能存在的 UTF-8 BOM（PowerShell 5.1 的 Set-Content -Encoding utf8 会写 BOM，
  # 带 BOM 时 /^\[tools\]/ 匹配不上，会把所有键都误报成"模板独有"）。
  tools_keys() {
    awk 'NR==1{sub(/^\xef\xbb\xbf/,"")} /^\[tools\]/{f=1;next} /^\[/{f=0} f && /^[A-Za-z0-9_.-]+[ \t]*=/{sub(/[ \t]*=.*/,"");print}' "$1" | sort -u
  }

  # 声明漂移检测：模板是"这台机器想要的状态"，部署副本是"现在实际声明的状态"。
  # 两份文件之间没有任何同步机制，模板里新加的工具会永远装不上——这是最容易被
  # 忽视的一类失效，因为 census 只看部署副本，会报告一切正常。
  if [ -f "$MISE_CONFIG_FILE" ] && cmp -s "$CONFIG_SOURCE" "$MISE_CONFIG_FILE"; then
    skip '部署副本与模板一致，无需改写'
  elif [ -f "$MISE_CONFIG_FILE" ]; then
    warn '检测到漂移：部署的配置与模板不一致'
    tpl_keys="$(tools_keys "$CONFIG_SOURCE")"
    dep_keys="$(tools_keys "$MISE_CONFIG_FILE")"
    missing="$(comm -23 <(printf '%s\n' "$tpl_keys") <(printf '%s\n' "$dep_keys") | grep -v '^$' || true)"
    extra="$(comm -13 <(printf '%s\n' "$tpl_keys") <(printf '%s\n' "$dep_keys") | grep -v '^$' || true)"
    [ -n "$missing" ] && printf '      模板有而部署副本没有: %s\n' "$(printf '%s' "$missing" | tr '\n' ' ')"
    [ -n "$extra" ]   && printf '      部署副本有而模板没有: %s\n' "$(printf '%s' "$extra" | tr '\n' ' ')"
    if [ -z "$missing$extra" ]; then
      printf '      [tools] 的键相同，但内容有差异（版本或注释不同）\n'
    fi

    if [ "$REFRESH_CONFIG" -eq 1 ]; then
      backup="$MISE_CONFIG_FILE.bak-$(date +%Y%m%d-%H%M%S)"
      run_action "备份到 $backup" cp "$MISE_CONFIG_FILE" "$backup"
      run_action "按模板写入 $MISE_CONFIG_FILE" cp "$CONFIG_SOURCE" "$MISE_CONFIG_FILE"
      done_msg '已按模板刷新（备份保留，可对比合并）'
    else
      skip '保持现状（要按模板覆盖请加 --refresh-config，覆盖前会自动备份）'
    fi
  elif [ "$DRY_RUN" -eq 1 ]; then
    plan "创建 $MISE_CONFIG_FILE 并写入模板内容"
  else
    mkdir -p "$(dirname "$MISE_CONFIG_FILE")"
    cp "$CONFIG_SOURCE" "$MISE_CONFIG_FILE"
    ok '机器声明已就位'
  fi
fi

# ============================================================
# 步骤：建立规范根
# ============================================================
step '建立规范根'

# 规范根是非托管运行时的落脚点。它刻意不进 PATH——PATH 里只应该有 mise 的
# shims 那一个工具链条目，加多了就会回到"多个版本争同一个名字"的老问题。
# 约定本身写在 AGENTS.md 规则 5 与 SKILL.md 里，census 的 [STRAY] 告警负责检查。
ok "规范根: $TOOLS_ROOT"

if [ -d "$TOOLS_ROOT" ]; then
  skip '目录已存在'
else
  run_action "创建 $TOOLS_ROOT" mkdir -p "$TOOLS_ROOT"
  done_msg '已创建'
fi
if [ "$DRY_RUN" -eq 0 ]; then
  warn '今后手工安装的运行时请放在 <工具>/<版本>/ 子目录下（如 node/22.23.2）'
  warn '已经装在别处的运行时不要迁移——路径可能被项目配置写死，改成登记到声明文件'
fi

# ============================================================
# 步骤 3：配置 PATH —— 全机只留一个工具链目录
# ============================================================
step '配置 PATH（核心步骤）'
printf '    原则：PATH 里只应该出现 mise 的 shims 目录这一个工具链条目，\n'
printf '    而不是每个运行时各自一条（/usr/local/opt/node、jdk/bin ...）。\n'

case ":$PATH:" in
  *":$MISE_SHIMS:"*) skip "shims 目录已在 PATH 中: $MISE_SHIMS" ;;
  *) warn "shims 目录不在当前 PATH：$MISE_SHIMS"
     warn '配置 shell 激活后（下一步）mise 会自动把它加进去，不需要手工改 PATH' ;;
esac

printf '\n    以下 PATH 条目指向具体版本，属于"该收敛掉"的候选：\n'
suspicious="$(printf '%s' "$PATH" | tr ':' '\n' | grep -E '/(node|python|jdk|jre|java|go|rust)[^/]*/(bin|versions)' || true)"
if [ -z "$suspicious" ]; then
  ok '没有发现需要收敛的条目'
else
  printf '%s\n' "$suspicious" | sed 's/^/      - /'
  warn '脚本不会自动删除它们。确认 mise 工作正常后，可以手工清理。'
fi

# ============================================================
# 步骤 4：配置 shell 激活
# ============================================================
step '配置 shell 激活'

if [ "$NO_RC" -eq 1 ]; then
  skip '按参数要求跳过（--no-rc）'
else
  # 根据当前 shell 选择激活写法。
  # 全部都要带存在性判断：否则在 mise 还不可解析的会话里（PATH 尚未刷新的新终端、
  # 用户卸载了 mise）每次启动 shell 都会报 command not found。
  # 用 if 形式而不是 && 形式，避免在某些 rc 文件设了 set -e 时中途退出。
  case "${SHELL:-}" in
    */zsh)
      RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
      ACTIVATION='if command -v mise >/dev/null 2>&1; then eval "$(mise activate zsh)"; fi'
      ;;
    */bash)
      RC_FILE="$HOME/.bashrc"
      ACTIVATION='if command -v mise >/dev/null 2>&1; then eval "$(mise activate bash)"; fi'
      ;;
    */fish)
      RC_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
      ACTIVATION='if command -q mise; mise activate fish | source; end'
      ;;
    *)
      RC_FILE="$HOME/.profile"
      ACTIVATION='if command -v mise >/dev/null 2>&1; then eval "$(mise activate bash)"; fi'
      warn "无法识别 shell ($SHELL)，将写入 $RC_FILE"
      ;;
  esac

  if [ -f "$RC_FILE" ] && grep -qF "$ACTIVATION" "$RC_FILE" 2>/dev/null; then
    skip "激活行已存在于 $RC_FILE"
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "向 $RC_FILE 追加激活行: $ACTIVATION"
    else
      mkdir -p "$(dirname "$RC_FILE")"
      {
        printf '\n# 由 runtime-census 的 bootstrap.sh 添加：让 mise 按项目声明自动切换运行时版本\n'
        printf '%s\n' "$ACTIVATION"
      } >> "$RC_FILE"
      ok "激活行已写入 $RC_FILE"
      warn '想撤销就删掉该文件里带 "runtime-census" 注释的那两行'
    fi
  fi
fi

# ============================================================
# 步骤 5：拉取声明的运行时
# ============================================================
step '拉取声明的运行时'

if [ "$SKIP_TOOLS" -eq 1 ]; then
  skip '按参数要求跳过（--skip-tools）'
elif ! command -v mise >/dev/null 2>&1; then
  warn 'mise 还不在当前 PATH 里，无法执行 mise install'
  warn '请重开终端后手工执行: mise install'
else
  run_action 'mise install（按机器声明拉取全部运行时）' mise install
  done_msg '运行时已拉取'
fi

# ============================================================
# 步骤 6：自检
# ============================================================
step '自检'
if command -v mise >/dev/null 2>&1; then
  mise doctor 2>&1 | sed 's/^/    /'
  printf '\n    当前 mise 管理的运行时：\n'
  mise ls 2>&1 | sed 's/^/      /'
else
  warn 'mise 尚未在当前会话可用，跳过自检。重开终端后执行 mise doctor。'
fi

# ============================================================
# 收尾
# ============================================================
cat <<'EOF'

======================================================================
 完成。接下来的用法：

   重开一个终端，然后：

   盘点本机所有运行时（包括未被 mise 纳管的）
     ./scripts/census.sh

   在项目里声明所需版本，然后一次性执行命令
     mise use node@22           # 写入项目 .tool-versions
     mise exec -- node -v       # 零全局状态地激活一次

   查看这台机器上所有可用版本
     mise ls                    # 已安装
     mise ls-remote node        # 可安装

======================================================================
EOF
[ "$DRY_RUN" -eq 1 ] && printf ' 这是空运行。去掉 --dry-run 才会真正执行。\n'
exit 0

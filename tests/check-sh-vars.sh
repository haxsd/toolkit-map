#!/usr/bin/env bash
#
# .sh 变量引用检查：$NAME 后面不能紧跟非 ASCII 字符，必须写成 ${NAME}。
#
# 为什么：macOS 自带的 /bin/bash 3.2 在 C/POSIX locale 下按字节解析变量名，
# 会把紧跟在 $VAR 后面的全角字符（如"（"）的字节也吞进变量名，
# 于是 $NAME 后面直接接"（说明）"时，引用的是一个不存在的变量——set -u 下直接报 unbound variable。
# 新版 bash 和 Linux 上看不出问题，CI 的 macOS job 在 C2（#14）里第一次抓到。
#
# 规则在所有平台都执行（不只 macOS），这样在 Linux 上开发也能提前发现。
# 用法: bash tests/check-sh-vars.sh   （从任意目录都可）
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# C locale 下 [:print:] 是 0x20-0x7E、[:cntrl:] 是 0x00-0x1F 与 0x7F，
# 两者之外恰好是 0x80-0xFF，即 UTF-8 多字节字符的任意字节。不用 grep -P：BSD grep 没有。
PATTERN='\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:cntrl:]]'
scan() { LC_ALL=C grep -nE "$PATTERN" "$@"; }

# 自检：先确认规则在当前平台的 grep 上真的生效，否则"没命中"毫无意义
SELF="$(mktemp "${TMPDIR:-/tmp}/check-sh-vars.XXXXXX")"
trap 'rm -f "$SELF"' EXIT
# 坏样例用八进制转义写出"（"（UTF-8 EF BC 88），免得本文件自己被这条规则命中
printf 'x="$FOO\357\274\210bar"\ny="${FOO}\357\274\210ok"\nz="$FOO ok"\n' > "$SELF"
SELF_HITS="$(scan "$SELF" | cut -d: -f1 | tr '\n' ' ')"
if [ "$SELF_HITS" != "1 " ]; then
  printf '  [失败] 自检：检测规则在本平台不生效（命中行: %s，期望: 1）\n' "${SELF_HITS:-无}"
  echo "::error::check-sh-vars.sh 自检失败：检测规则在本平台不生效"
  exit 1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  FILES="$(git ls-files '*.sh')"
else
  FILES="$(find scripts tests -name '*.sh' -type f)"
fi
COUNT=0
HITS=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  COUNT=$((COUNT + 1))
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    line="${hit%%:*}"
    printf '  [失败] %s:%s: %s\n' "$f" "$line" "${hit#*:}"
    echo "::error file=${f},line=${line}::\$VAR 后紧跟非 ASCII 字符：bash 3.2 会把它吞进变量名，改成 \${VAR}"
    HITS=$((HITS + 1))
  done <<EOT
$(scan "$f")
EOT
done <<EOT
$FILES
EOT

if [ "$HITS" -gt 0 ]; then
  printf '\n 有 %d 处 $VAR 紧跟非 ASCII 字符，请改成 ${VAR}\n\n' "$HITS"
  exit 1
fi
printf '  [通过] %d 个 .sh 文件里没有 $VAR 紧跟非 ASCII 字符\n' "$COUNT"
exit 0

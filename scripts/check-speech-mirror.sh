#!/usr/bin/env bash
# 防止 SpeechLogicCheck 里的副本与 KeyboardCore 原件漂移。
#
# 为什么要有这个检查：
# SpeechLogicCheck 为了让播报逻辑能在 Linux 上跑测试，复制了
# KeySpeech.swift / CharacterDescriptionTable.swift 两个文件。
# 只要主代码改了而副本没同步，测试就会在验证一份过期的逻辑——
# 这比不测更危险，因为它会给出「通过」的假信号。
#
# 因此逐字节比对，有任何差异就失败，并提示如何同步。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Packages/KeyboardCore/Sources/KeyboardCore"
DST="$ROOT/Packages/SpeechLogicCheck/Sources/SpeechLogicCheck"

status=0

check_pair() {
  local src="$1" dst="$2" label="$3"
  if [ ! -f "$src" ]; then
    echo "::error::源文件缺失：$src"
    status=1
    return
  fi
  if [ ! -f "$dst" ]; then
    echo "::error::副本缺失：$dst"
    status=1
    return
  fi
  if ! cmp -s "$src" "$dst"; then
    echo "::error::$label 与原件不一致"
    echo "  请执行：cp '$src' '$dst'"
    status=1
  fi
}

for f in KeySpeech.swift CharacterDescriptionTable.swift; do
  check_pair "$SRC/$f" "$DST/$f" "SpeechLogicCheck/$f"
done

# 字典资源也必须是同一份，否则测试验证的解析行为与真机不同。
for f in zh_CN.compact.txt zh_TW.compact.txt; do
  check_pair \
    "$SRC/Resources/CharDescriptions/$f" \
    "$DST/Resources/CharDescriptions/$f" \
    "SpeechLogicCheck/Resources/CharDescriptions/$f"
done

if [ "$status" -eq 0 ]; then
  echo "SpeechLogicCheck 副本与 KeyboardCore 原件一致。"
fi
exit "$status"

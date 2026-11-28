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

for f in KeySpeech.swift CharacterDescriptionTable.swift; do
  if [ ! -f "$SRC/$f" ]; then
    echo "::error::源文件缺失：$SRC/$f"
    status=1
    continue
  fi
  if [ ! -f "$DST/$f" ]; then
    echo "::error::副本缺失：$DST/$f"
    status=1
    continue
  fi
  if ! cmp -s "$SRC/$f" "$DST/$f"; then
    echo "::error file=Packages/SpeechLogicCheck/Sources/SpeechLogicCheck/$f::与 KeyboardCore 原件不一致"
    echo "  请执行：cp '$SRC/$f' '$DST/$f'"
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "SpeechLogicCheck 副本与 KeyboardCore 原件一致。"
fi
exit "$status"

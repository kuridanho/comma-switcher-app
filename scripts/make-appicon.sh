#!/bin/zsh
# 採用した案 E を描き、AppIcon.appiconset の各サイズに書き出す。
set -e
cd "$(dirname "$0")/.."
dir=CommaSwitcher/Assets.xcassets/AppIcon.appiconset
src=$(mktemp -t icon).png
swift scripts/make-icon.swift E "$src"
for s in 16 32 128 256 512; do
  sips -z $s $s "$src" --out "$dir/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$src" --out "$dir/icon_${s}x${s}@2x.png" >/dev/null
done
rm -f "$src"

#!/bin/zsh
# Renders demo/demo.mp4 (30 s, 1920x1080) from the real widget views with made-up sample data.
# Needs ffmpeg on PATH. Usage: zsh demo/make_demo.sh [--still out.png]
set -euo pipefail

cd "${0:A:h}/.."
work="${TMPDIR:-/tmp}/aquadesk-demo"
mkdir -p "$work/modules" "$work/Demo.app/Contents/MacOS"
swiftc -O -parse-as-library -D DEMO -module-cache-path "$work/modules" \
  Aquadesk.swift demo/Demo.swift -o "$work/Demo.app/Contents/MacOS/Demo"
cp AppIcon.icns "$work/AppIcon.icns"

if [[ "${1:-}" == "--still" ]]; then
  "$work/Demo.app/Contents/MacOS/Demo" --demo "${2:A}" --still
else
  "$work/Demo.app/Contents/MacOS/Demo" --demo "$PWD/demo/demo.mp4"
fi

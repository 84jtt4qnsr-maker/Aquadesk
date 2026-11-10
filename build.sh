#!/bin/zsh
# Builds Aquadesk.app next to this script, signed ad hoc for local use.
set -euo pipefail

cd "${0:A:h}"
app="Aquadesk.app"
work="${TMPDIR:-/tmp}/aquadesk-build"
mkdir -p "$work/modules"
export CLANG_MODULE_CACHE_PATH="$work/modules"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# The icon is drawn once and kept; delete AppIcon.icns to draw it again.
if [[ ! -f AppIcon.icns ]]; then
  rm -rf "$work/AppIcon.iconset"
  swift -module-cache-path "$work/modules" make_icon.swift "$work/AppIcon.iconset"
  iconutil -c icns "$work/AppIcon.iconset" -o AppIcon.icns
fi
cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

swiftc -O -parse-as-library -module-cache-path "$work/modules" \
  Aquadesk.swift -o "$app/Contents/MacOS/Aquadesk"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.aquadesk</string>
  <key>CFBundleName</key><string>Aquadesk</string>
  <key>CFBundleExecutable</key><string>Aquadesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDisplayName</key><string>Aquadesk</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>メールの未読数の表示と、SpotifyとChrome上のストリーミングサイトの再生操作に使います。</string>
  <key>NSAudioCaptureUsageDescription</key><string>再生中の音に合わせてメディア欄のビジュアライザーを動かすために使います。音は分析するだけで、保存や送信はしません。</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>これからの予定をウィジェットに表示するために使います。</string>
  <key>NSLocationUsageDescription</key><string>Wi-Fiのネットワーク名を表示するために使います。現在地は取得しません。</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Wi-Fiのネットワーク名を表示するために使います。現在地は取得しません。</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>未完了のリマインダーをウィジェットに表示するために使います。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "built $PWD/$app"

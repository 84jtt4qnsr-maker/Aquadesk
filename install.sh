#!/bin/zsh
# Builds the widget, puts it in ~/Applications, and starts it from there.
# The first start from that folder also turns on "start at login".
set -euo pipefail

cd "${0:A:h}"
zsh build.sh
dest="$HOME/Applications"
mkdir -p "$dest"
pkill -x Aquadesk || true
# The app used to be called UsageWidget; the old copy goes to the Trash so only one runs.
pkill -x UsageWidget || true
sleep 1
if [[ -d "$dest/UsageWidget.app" ]]; then
  mv "$dest/UsageWidget.app" "$HOME/.Trash/UsageWidget-$(date +%Y%m%d%H%M%S).app"
  echo "moved the old UsageWidget.app to the Trash"
fi
rm -rf "$dest/Aquadesk.app"
ditto Aquadesk.app "$dest/Aquadesk.app"
open "$dest/Aquadesk.app"
echo "installed $dest/Aquadesk.app"

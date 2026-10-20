#!/bin/bash
# Builds OE Time Log with the Command Line Tools only, assembles the .app,
# signs it ad hoc and installs it to /Applications.
#   ./build.sh            build + install + launch
#   ./build.sh --no-open  build + install only
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/OETimeLog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OETimeLog "$APP/Contents/MacOS/"
sed "s/BUILD_NUMBER/$(date +%Y%m%d%H%M)/" Support/Info.plist > "$APP/Contents/Info.plist"
cp Support/codebook.json "$APP/Contents/Resources/"

xattr -cr "$APP"
codesign --force --sign - "$APP"

# Quit a running copy so the new build replaces it.
osascript -e 'tell application id "cz.oneeighty.timelog" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/OETimeLog.app
ditto "$APP" /Applications/OETimeLog.app

if [[ "${1:-}" != "--no-open" ]]; then
  open /Applications/OETimeLog.app
fi
echo "Installed /Applications/OETimeLog.app"

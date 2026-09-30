#!/bin/bash
# Builds the Burn app with xcodebuild and opens it, without opening Xcode.
#
# Usage: scripts/run-app.sh [--demo] [--release]
#   --demo     use a simulated drive with a blank DVD+R, so no real drive is needed
#   --release  build the Release configuration instead of Debug
#
# Needs Xcode installed (xcodebuild comes with it), not running.

set -euo pipefail
cd "$(dirname "$0")/.."

configuration=Debug
app_arguments=()
for argument in "$@"; do
    case "$argument" in
        --demo) app_arguments+=(-demo) ;;
        --release) configuration=Release ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $argument (try --help)" >&2
            exit 2
            ;;
    esac
done

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "xcodebuild isn't working. Install Xcode from the App Store, then run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

derived=".build/xcode"
log="$derived/build.log"
mkdir -p "$derived"

echo "Building Burn ($configuration)…"
if ! xcodebuild build -project Burn.xcodeproj -scheme Burn -configuration "$configuration" \
    -destination 'platform=macOS' -derivedDataPath "$derived" >"$log" 2>&1; then
    grep -E "(error|warning): " "$log" | sort -u || true
    echo "The build failed. Full log: $log" >&2
    exit 1
fi

app="$derived/Build/Products/$configuration/Burn.app"

# Quit a copy that's already running from here, so the new build is the one that opens.
if pkill -f "$app/Contents/MacOS/Burn" 2>/dev/null; then
    sleep 1
fi

echo "Opening $app"
open "$app" ${app_arguments[@]+--args "${app_arguments[@]}"}

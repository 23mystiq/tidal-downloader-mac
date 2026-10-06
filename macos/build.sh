#!/bin/zsh
# Builds "TIDAL Downloader.app" (native macOS front end) into macos/build/.
# The app runs the Python engine from this checkout's .venv (python -m tidal_dl_ng.bridge).
set -euo pipefail

HERE=${0:A:h}
ROOT=${HERE:h}
PYTHON="$ROOT/.venv/bin/python"
APP="$HERE/build/TIDAL Downloader.app"
CONFIG=${CONFIG:-release}

[[ -x "$PYTHON" ]] || { echo "Missing $PYTHON — create the venv first (python3.12 -m venv .venv && .venv/bin/pip install -e .)" >&2; exit 1; }

swift build --package-path "$HERE" -c "$CONFIG"
BIN=$(swift build --package-path "$HERE" -c "$CONFIG" --show-bin-path)/TidalDL
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/pyproject.toml" | head -1)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TidalDL"
cp "$ROOT/tidal_dl_ng/ui/icon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TidalDL</string>
    <key>CFBundleIdentifier</key><string>com.github.tidal-dl-ng.mac</string>
    <key>CFBundleName</key><string>TIDAL Downloader</string>
    <key>CFBundleDisplayName</key><string>TIDAL Downloader</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>TDLRoot</key><string>$ROOT</string>
    <key>TDLPython</key><string>$PYTHON</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null
echo "Built: $APP"

# ./build.sh --install also copies it to /Applications.
if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/TIDAL Downloader.app"
    ditto "$APP" "/Applications/TIDAL Downloader.app"
    echo "Installed: /Applications/TIDAL Downloader.app"
fi

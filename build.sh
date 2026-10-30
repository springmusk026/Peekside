#!/bin/zsh
# Build Peekside.app, install it to ~/Applications and launch it.
# With --no-install, only build it into build/ (used by CI and releases).
set -euo pipefail
cd "${0:A:h}"

APP=build/Peekside.app

# Ad-hoc signature by default; set SIGN_IDENTITY="..." to sign with a certificate.
IDENTITY=${SIGN_IDENTITY:--}

# Target the minimum macOS in Info.plist, as Xcode does (swiftc otherwise
# targets the OS it runs on, so the app wouldn't launch on older systems).
# ARCHS="arm64 x86_64" builds a universal app (used for releases).
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw Info.plist)
ARCHS=(${=ARCHS:-$(uname -m)})

rm -rf build
mkdir -p "$APP/Contents/MacOS"
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos$MIN_OS" \
    Sources/*.swift -o "build/Peekside-$arch"
done
lipo -create build/Peekside-* -output "$APP/Contents/MacOS/Peekside"
rm build/Peekside-*
cp Info.plist "$APP/Contents/"

# App icon (rendered once from tools/make-icon.swift)
if [[ ! -f Resources/AppIcon.icns ]]; then
  tmp=$(mktemp -d)
  swift tools/make-icon.swift "$tmp/icon.png"
  mkdir "$tmp/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  mkdir -p Resources
  iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$tmp"
fi
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign "$IDENTITY" "$APP"

if [[ ${1:-} == --no-install ]]; then
  echo "Built $APP"
  exit 0
fi

pkill -x Peekside 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Peekside.app
ditto "$APP" ~/Applications/Peekside.app
open ~/Applications/Peekside.app
echo "Installed ~/Applications/Peekside.app"

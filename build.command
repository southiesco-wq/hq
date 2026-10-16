#!/bin/bash
# Builds "Mono Maker.app" from the Swift files in Sources/ and puts it in this folder.
# Needs Apple's free Command Line Tools (or Xcode). Nothing else is downloaded.
set -euo pipefail
cd "$(dirname "$0")"

APP="Mono Maker.app"
BIN="MonoMaker"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo ""
  echo "Mono Maker needs Apple's free developer tools to build (one-time install)."
  echo "A window will open: click Install, wait until it finishes, then run this again."
  echo ""
  xcode-select --install >/dev/null 2>&1 || true
  exit 1
fi

echo "Building Mono Maker…"
rm -rf .build "$APP"
mkdir -p .build "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# One copy for Apple silicon and one for Intel, joined into a single app.
for ARCH in arm64 x86_64; do
  echo "  compiling for $ARCH"
  xcrun swiftc -O -swift-version 5 -parse-as-library \
    -sdk "$SDK" -target "$ARCH-apple-macos13.0" \
    Sources/*.swift -o ".build/$BIN-$ARCH"
done
lipo -create ".build/$BIN-arm64" ".build/$BIN-x86_64" -output "$APP/Contents/MacOS/$BIN"

cp -X Info.plist "$APP/Contents/Info.plist"
cp -X AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1
rm -rf .build

echo ""
echo "Done. \"$APP\" is in: $(pwd)"
echo "Drag it into your Applications folder, then open it like any other app."
[ -z "${CI:-}" ] && open -R "$APP" || true

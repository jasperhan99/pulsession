#!/bin/bash
#
# Assembles Pulsession.app from the SwiftPM build.
#
# Pulsession is a fork of Pulse (github.com/qunqin24/Pulse). The Swift module
# and executable target stay named `Pulse` so upstream changes merge cleanly;
# only the bundle it is packaged into carries the fork's identity.
#
# Pulse has no Xcode project on purpose — it is a plain package, and this is
# what turns the package's bare executable into something macOS treats as an
# app. That matters for more than tidiness: without a bundle there is no
# version number to compare against (so no update check), `SMAppService` cannot
# register a login item, and there is nothing to hand anyone but a build folder.
#
#   ./Scripts/bundle.sh            → build.noindex/Pulsession.app
#   ./Scripts/bundle.sh --zip      → and build.noindex/Pulsession-<version>.zip to attach
#                                    to the release
#   ./Scripts/bundle.sh --open     → and reveal it in Finder
#
# The version comes from the VERSION file, which is the single source of truth:
# tag the release `v$(cat VERSION)` so the update check — which reads GitHub's
# latest release tag — is comparing like with like.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build.noindex/Pulsession.app"
EXECUTABLE="Pulsession"
BUNDLE_ID="io.github.jasperhan.pulsession"
# No SUFeedURL: the fork has no update feed of its own yet, and pointing at
# upstream's would offer to replace this app with Pulse. AppUpdate keeps
# Sparkle inert whenever the key is missing.

echo "Building Pulsession $VERSION (universal)…"

# macOS picks which design an app gets from the SDK version recorded in its
# binary's LC_BUILD_VERSION, not from the version it is running on. Below 26 it
# draws the pre-Tahoe controls, and no Info.plist key opts back in. Liquid
# Glass (`glassEffect`) needs the same SDK to compile at all.
#
# The stamp itself is set in Package.swift, so that every way of building this
# package agrees — including running it from Xcode, which does not come
# through here. What this script adds is the check: read the stamp back off
# every slice after linking and refuse to package anything below 26.
#
# That check is here rather than left to the flag because the failure is
# silent. SwiftPM stamped the deployment target into that field under one
# toolchain and the real SDK under the previous one, with no error either way
# — what shipped was simply an app drawn the old way, which no build log and
# no test would have caught. See Docs/decisions/sdk-stamp-and-appearance.md.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

if [ "${SDK_VERSION%%.*}" -lt 26 ]; then
    echo "Need the macOS 26 SDK or newer to build a release; found $SDK_VERSION." >&2
    echo "Point xcode-select at an Xcode that ships it." >&2
    exit 1
fi

echo "  SDK $SDK_VERSION"

# Both architectures, so the same download runs on Apple Silicon and Intel.
swift build -c release --arch arm64 --arch x86_64

BUILT="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

for arch in arm64 x86_64; do
    stamped="$(otool -arch "$arch" -l "$BUILT/Pulse" \
        | awk '/LC_BUILD_VERSION/{f=1} f&&/^ *sdk /{print $2; exit}')"
    if [ -z "$stamped" ] || [ "${stamped%%.*}" -lt 26 ]; then
        echo "The $arch slice records sdk ${stamped:-none}, so macOS would draw it the old way." >&2
        echo "Package.swift's linkerSettings are no longer taking effect." >&2
        exit 1
    fi
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Spotlight indexes an .app wherever it finds one, so a build sitting in the
# project folder turns up in Launchpad and search beside the installed copy —
# two identical Pulses, and no way to tell which is which. It is the directory's
# `.noindex` suffix that Spotlight actually honours; this marker was tried on
# its own and did not work, and is kept only as a second line. Do not rely on
# it, and do not rename the directory. See Docs/releasing.md.
touch "build.noindex/.metadata_never_index"

cp "$BUILT/Pulse" "$APP/Contents/MacOS/$EXECUTABLE"

# The package's resource bundle carries the provider marks and both .lproj
# folders. `Bundle.module` looks in the main bundle's Resources, so this is
# where it has to land — the app is silently English with no icons without it.
cp -R "$BUILT/Pulse_Pulse.bundle" "$APP/Contents/Resources/"
cp AppIcon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A ready-to-copy developer kit. Never ship local npm dependencies or build output.
mkdir -p "$APP/Contents/Resources/Integrations/raycast"
cp Integrations/pulse-status.sh Integrations/pulse-sketchybar.sh "$APP/Contents/Resources/Integrations/"
cp Integrations/raycast/package.json Integrations/raycast/package-lock.json Integrations/raycast/tsconfig.json "$APP/Contents/Resources/Integrations/raycast/"
cp -R Integrations/raycast/src Integrations/raycast/assets Integrations/raycast/tests "$APP/Contents/Resources/Integrations/raycast/"

# Sparkle has to travel inside the app. SwiftPM links the executable against
# the framework but has no app to put it in, which is why a `swift run` build
# cannot update itself and `AppUpdate` doesn't start the updater there.
FRAMEWORK="$(find .build/artifacts -maxdepth 6 -type d -name 'Sparkle.framework' | head -1)"
if [ -z "$FRAMEWORK" ]; then
    echo "Sparkle.framework not found — run 'swift build' so SwiftPM fetches it." >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$FRAMEWORK" "$APP/Contents/Frameworks/"

# The executable looks for it at @rpath; SwiftPM only ever pointed that at the
# build directory, so without this the app launches into a dyld failure.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Pulsession</string>
    <key>CFBundleDisplayName</key><string>Pulsession</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <!-- Without this the app is English on a Chinese Mac. The strings ship
         correctly inside Pulse_Pulse.bundle, but CFBundle resolves a nested
         bundle's language against the *main* bundle's declared localizations:
         with none declared, Bundle.module.preferredLocalizations comes back
         ["en"] under AppleLanguages ("zh-Hans-CN") and every lookup returns
         the English key. Declaring them here flips it to ["zh-Hans"]. Keep in
         step with Sources/Pulse/Resources/*.lproj. -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>ja</string>
        <string>ko</string>
    </array>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- A menu bar app: no Dock icon, and no flash of one at launch. The code
         also sets .accessory, but that runs after the Dock has already been
         told what to show. -->
    <key>LSUIElement</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>$BUNDLE_ID.navigation</string>
        <key>CFBundleURLSchemes</key><array><string>pulsession</string></array>
        <key>CFBundleTypeRole</key><string>Viewer</string>
    </dict></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Pulsession — based on Pulse (github.com/qunqin24/Pulse), Apache-2.0</string>
</dict>
</plist>
PLIST

# Unsigned builds are quarantined on download and refused by Gatekeeper. An
# ad-hoc signature does not fix that — only a Developer ID and notarisation do
# — but it does keep macOS from complaining about a *damaged* bundle when the
# app is moved or the binary is touched.
# Inside out: a nested bundle signed after its container invalidates the
# container's signature, and Sparkle brings several of them (XPC services and
# its own updater app).
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"

echo "→ $APP"

# `ditto`, not `zip`: an app bundle carries symlinks and resource forks that a
# plain zip quietly flattens, and the unzipped copy then refuses to launch.
if [ "${1:-}" = "--zip" ]; then
    ZIP="build.noindex/Pulsession-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "→ $ZIP"
fi

[ "${1:-}" = "--open" ] && open -R "$APP"
exit 0

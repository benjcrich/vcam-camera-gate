#!/bin/zsh
# Builds the vcam-camera-gate OBS plugin with only the Command Line Tools, against the installed OBS.
#
#   ./build.zsh            build into build/
#   ./build.zsh install    build, then copy into OBS's per-user plugin folder (quit OBS first)

set -euo pipefail

HERE=${0:A:h}
OBS_APP=${OBS_APP:-/Applications/OBS.app}
OBS_VERSION=$(plutil -extract CFBundleShortVersionString raw "$OBS_APP/Contents/Info.plist")
NAME=vcam-camera-gate
SIMDE_TAG=v0.8.2
DEPS=$HERE/.deps
OUT=$HERE/build
BUNDLE=$OUT/$NAME.plugin

# libobs headers matching the installed OBS, the SIMD shim they include, and the frontend API header.
if [[ ! -d $DEPS/obs-studio-$OBS_VERSION/libobs ]]; then
    git clone -q --depth 1 --branch "$OBS_VERSION" --filter=blob:none --sparse \
        https://github.com/obsproject/obs-studio.git "$DEPS/obs-studio-$OBS_VERSION"
    git -C "$DEPS/obs-studio-$OBS_VERSION" sparse-checkout set libobs
fi
if [[ ! -d $DEPS/simde ]]; then
    git clone -q --depth 1 --branch "$SIMDE_TAG" https://github.com/simd-everywhere/simde.git "$DEPS/simde"
fi
FRONTEND_INC=$DEPS/obs-frontend-api-$OBS_VERSION
if [[ ! -f $FRONTEND_INC/obs-frontend-api.h ]]; then
    mkdir -p "$FRONTEND_INC"
    curl -fsSL -o "$FRONTEND_INC/obs-frontend-api.h" \
        "https://raw.githubusercontent.com/obsproject/obs-studio/$OBS_VERSION/frontend/api/obs-frontend-api.h"
fi

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$BUNDLE/Contents/MacOS"
print "#pragma once\n#define OBS_RELEASE_CANDIDATE 0\n#define OBS_BETA 0" > "$OUT/gen/obsconfig.h"

clang -bundle -O2 -g -fobjc-arc -mmacosx-version-min=13.0 \
    -Wall -Wextra -Wno-unused-parameter \
    -I "$OUT/gen" -isystem "$DEPS/obs-studio-$OBS_VERSION/libobs" -isystem "$FRONTEND_INC" -isystem "$DEPS/simde" \
    -F "$OBS_APP/Contents/Frameworks" -framework libobs \
    "$OBS_APP/Contents/Frameworks/libobs-frontend-api.1.dylib" -Wl,-rpath,@executable_path/../Frameworks \
    -framework Foundation -framework CoreMediaIO \
    -o "$BUNDLE/Contents/MacOS/$NAME" "$HERE/$NAME.m"

cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$NAME</string>
	<key>CFBundleIdentifier</key><string>local.obs.$NAME</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
</dict>
</plist>
EOF
codesign --force --sign - "$BUNDLE"
print "Built $BUNDLE"

if [[ ${1:-} == install ]]; then
    if pgrep -x OBS >/dev/null; then
        print "Quit OBS first, then run: $0 install" >&2
        exit 1
    fi
    DEST="$HOME/Library/Application Support/obs-studio/plugins"
    mkdir -p "$DEST"
    rm -rf "$DEST/$NAME.plugin"
    cp -R "$BUNDLE" "$DEST/"
    print "Installed into $DEST/$NAME.plugin"
fi

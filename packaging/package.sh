#!/usr/bin/env bash
# Builds release packages from an already built binary.
#
#   packaging/package.sh <format>...
#
# Linux:  zip deb rpm appimage flatpak
# macOS:  app dmg zip   (run on a Mac)
# Windows: packaging\windows\package.ps1
#
# Environment (all optional):
#   VERSION  default: build.zig.zon's
#   ARCH     x86_64 or aarch64, default: this machine's
#   BIN      the lax binary, default: zig-out/bin/lax
#   OUT      where packages go, default: dist
#   NFPM, APPIMAGETOOL  tool paths when not on PATH
#   macOS signing, when set: MACOS_SIGN_IDENTITY ("Developer ID Application: ...");
#   notarizing, when also set: APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-$(sed -n 's/.*\.version = "\(.*\)".*/\1/p' build.zig.zon)}
ARCH=${ARCH:-$(uname -m)}
[ "$ARCH" = arm64 ] && ARCH=aarch64
BIN=${BIN:-zig-out/bin/lax}
OUT=${OUT:-dist}
case "$(uname -s)" in Darwin) OS=macos ;; *) OS=linux ;; esac
NAME="lax-$VERSION-$OS-$ARCH"
GOARCH=$([ "$ARCH" = aarch64 ] && echo arm64 || echo amd64)
mkdir -p "$OUT"

[ -f "$BIN" ] || { echo "no binary at $BIN: zig build -Doptimize=ReleaseSafe first" >&2; exit 1; }

# The metainfo with this release in it
metainfo() {
    local f="$OUT/com.gammagamma.lax.metainfo.xml"
    sed -e "s/@VERSION@/$VERSION/" -e "s/@DATE@/$(date -u +%F)/" packaging/linux/com.gammagamma.lax.metainfo.xml >"$f"
    echo "$f"
}

# A folder with the binary and the notices, zipped
do_zip() {
    local stage="$OUT/$NAME"
    rm -rf "$stage" "$OUT/$NAME.zip"
    mkdir -p "$stage"
    install -m755 "$BIN" "$stage/lax"
    cp README.md LICENSE THIRD_PARTY_NOTICES.md "$stage/"
    (cd "$OUT" && zip -qr "$NAME.zip" "$NAME")
    rm -rf "$stage"
    echo "$OUT/$NAME.zip"
}

do_nfpm() {
    local nfpm=${NFPM:-nfpm}
    command -v "$nfpm" >/dev/null || { echo "nfpm not found: https://nfpm.goreleaser.com/install" >&2; exit 1; }
    VERSION=$VERSION GOARCH=$GOARCH BIN=$BIN METAINFO=$(metainfo) "$nfpm" package -f packaging/linux/nfpm.yaml -p "$1" -t "$OUT"
}

do_appimage() {
    local tool=${APPIMAGETOOL:-appimagetool}
    if ! command -v "$tool" >/dev/null; then
        tool=".cache/appimagetool-$ARCH.AppImage"
        if [ ! -x "$tool" ]; then
            mkdir -p .cache
            curl -fsSL -o "$tool" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$(uname -m).AppImage"
            chmod +x "$tool"
        fi
    fi
    local dir="$OUT/Lax.AppDir"
    rm -rf "$dir"
    mkdir -p "$dir/usr/bin" "$dir/usr/share/metainfo"
    install -m755 "$BIN" "$dir/usr/bin/lax"
    ln -s usr/bin/lax "$dir/AppRun"
    cp packaging/linux/com.gammagamma.lax.desktop "$dir/"
    cp packaging/icon/lax-256.png "$dir/com.gammagamma.lax.png"
    cp packaging/icon/lax-256.png "$dir/.DirIcon"
    cp "$(metainfo)" "$dir/usr/share/metainfo/"
    ARCH=$ARCH "$tool" --appimage-extract-and-run "$dir" "$OUT/$NAME.AppImage"
    rm -rf "$dir"
    echo "$OUT/$NAME.AppImage"
}

do_flatpak() {
    command -v flatpak-builder >/dev/null || { echo "flatpak-builder not found" >&2; exit 1; }
    local src="$OUT/flatpak"
    rm -rf "$src"
    mkdir -p "$src"
    install -m755 "$BIN" "$src/lax"
    cp packaging/linux/com.gammagamma.lax.yml packaging/linux/com.gammagamma.lax.desktop "$src/"
    cp "$(metainfo)" "$src/"
    cp packaging/icon/lax.svg packaging/icon/lax-256.png packaging/icon/lax-512.png "$src/"
    (cd "$src" && flatpak-builder --force-clean --user --install-deps-from=flathub \
        --arch="$ARCH" --repo=repo --state-dir=.state build com.gammagamma.lax.yml \
        && flatpak build-bundle --arch="$ARCH" repo "../$NAME.flatpak" com.gammagamma.lax)
    rm -rf "$src"
    echo "$OUT/$NAME.flatpak"
}

# Lax.app: the binary, Info.plist and the icon; signed (ad hoc without an identity)
do_app() {
    [ "$OS" = macos ] || { echo "app needs macOS" >&2; exit 1; }
    local app="$OUT/Lax.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    install -m755 "$BIN" "$app/Contents/MacOS/lax"
    sed "s/@VERSION@/$VERSION/g" packaging/macos/Info.plist >"$app/Contents/Info.plist"
    local set="$OUT/lax.iconset"
    rm -rf "$set"
    mkdir -p "$set"
    for s in 16 32 128 256 512; do
        sips -z $s $s packaging/icon/lax-1024.png --out "$set/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) packaging/icon/lax-1024.png --out "$set/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$set" -o "$app/Contents/Resources/lax.icns"
    rm -rf "$set"
    if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
        codesign --force --options runtime --timestamp --entitlements packaging/macos/entitlements.plist --sign "$MACOS_SIGN_IDENTITY" "$app"
    else
        codesign --force --sign - "$app"
    fi
    echo "$app"
}

notarize() {
    [ -n "${MACOS_SIGN_IDENTITY:-}" ] && [ -n "${APPLE_ID:-}" ] || return 0
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
    xcrun stapler staple "$1"
}

do_dmg() {
    local app="$OUT/Lax.app"
    [ -d "$app" ] || do_app >/dev/null
    local stage="$OUT/dmg"
    rm -rf "$stage" "$OUT/$NAME.dmg"
    mkdir -p "$stage"
    cp -R "$app" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "Lax" -srcfolder "$stage" -ov -format UDZO "$OUT/$NAME.dmg" >/dev/null
    rm -rf "$stage"
    [ -n "${MACOS_SIGN_IDENTITY:-}" ] && codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$OUT/$NAME.dmg"
    notarize "$OUT/$NAME.dmg"
    echo "$OUT/$NAME.dmg"
}

# The .app zipped the way Finder does it (keeps the bundle's metadata)
do_app_zip() {
    local app="$OUT/Lax.app"
    [ -d "$app" ] || do_app >/dev/null
    rm -f "$OUT/$NAME.zip"
    ditto -c -k --keepParent "$app" "$OUT/$NAME.zip"
    echo "$OUT/$NAME.zip"
}

[ $# -gt 0 ] || { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
for fmt in "$@"; do
    case "$fmt" in
        zip) if [ "$OS" = macos ]; then do_app_zip; else do_zip; fi ;;
        deb | rpm) do_nfpm "$fmt" ;;
        appimage) do_appimage ;;
        flatpak) do_flatpak ;;
        app) do_app ;;
        dmg) do_dmg ;;
        *) echo "unknown format: $fmt" >&2; exit 1 ;;
    esac
done

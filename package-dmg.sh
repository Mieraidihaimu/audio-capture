#!/bin/bash
# ============================================================================
# package-dmg.sh — Create a distributable DMG for Audio Capture
# ============================================================================
#
# Usage:
#   ./package-dmg.sh [path/to/Audio Capture.app] [output.dmg]
#
# Arguments:
#   $1  Path to the built .app bundle (default: build/Audio Capture.app)
#   $2  Output DMG path            (default: build/AudioCapture-<version>.dmg)
#
# Environment variables (all optional):
#   DEVELOPER_ID_APPLICATION   Identity for codesigning the DMG
#                              (e.g. "Developer ID Application: Name (TEAMID)")
#   NOTARIZATION_APPLE_ID      Apple ID for notarization
#   NOTARIZATION_PASSWORD      App-specific password or @keychain: reference
#   NOTARIZATION_TEAM_ID       Team ID for notarization
#
# Requirements:
#   macOS with hdiutil, osascript, sips, and (for notarization) xcrun notarytool
#
# Examples:
#   # Basic — just create the DMG:
#   ./package-dmg.sh
#
#   # From a custom .app location:
#   ./package-dmg.sh /tmp/Audio\ Capture.app
#
#   # With code signing and notarization:
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Foo (XYZABC)" \
#   NOTARIZATION_APPLE_ID="dev@example.com" \
#   NOTARIZATION_PASSWORD="@keychain:AC_PASSWORD" \
#   NOTARIZATION_TEAM_ID="XYZABC" \
#     ./package-dmg.sh
# ============================================================================
set -euo pipefail

# ------------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------------
script_dir=$(cd "$(dirname "$0")" && pwd)
app_path="${1:-$script_dir/build/Audio Capture.app}"

# Make absolute
case "$app_path" in
    /*) ;;
    *)  app_path="$PWD/$app_path" ;;
esac

if [[ ! -d "$app_path" ]]; then
    printf 'Error: .app bundle not found at %s\n' "$app_path" >&2
    printf 'Build it first with ./build.sh, or pass the path as $1.\n' >&2
    exit 1
fi

# Extract version from the app's Info.plist for the output filename
app_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$app_path/Contents/Info.plist" 2>/dev/null || echo "0.0.0")

output_dmg="${2:-$script_dir/build/AudioCapture-${app_version}.dmg}"
case "$output_dmg" in
    /*) ;;
    *)  output_dmg="$PWD/$output_dmg" ;;
esac

volume_name="Audio Capture"
app_size_mb=$(du -sm "$app_path" | awk '{print $1}')
dmg_size="$((app_size_mb + 120))m"

printf '==> Packaging DMG for %s v%s\n' "$volume_name" "$app_version"
printf '    App:    %s\n' "$app_path"
printf '    Output: %s\n' "$output_dmg"

# ------------------------------------------------------------------
# Create a temporary working area
# ------------------------------------------------------------------
scratch=$(mktemp -d "${TMPDIR:-/tmp}/audiocapture-dmg.XXXXXX")
device=""
cleanup() {
    if [[ -n "${device:-}" ]]; then
        hdiutil detach "$device" -force -quiet 2>/dev/null || true
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT

rw_dmg="$scratch/rw.dmg"
bg_image="$scratch/background.png"

# ------------------------------------------------------------------
# 1. Generate a background image (600×400 solid dark-blue gradient)
# ------------------------------------------------------------------
# We create a small base color swatch and scale it. The /usr/bin/sips tool can
# only do basic operations, so we use a two-tone approach:
# - Create a 1×1 pixel PNG of #1a1a2e (dark navy) using printf + sips
# - Scale to 600×400
# This gives a clean, professional dark background.

printf '==> Creating DMG background image\n'

# Create a 600×400 image via a minimal BMP that sips can convert to PNG.
# We use Python (shipped with macOS / Xcode CLT) for exact pixel control.
/usr/bin/python3 - "$bg_image" <<'PYEOF'
import struct, sys, zlib

width, height = 600, 400
# Dark gradient from #1a1a2e (top) to #16213e (bottom)
top_r, top_g, top_b = 0x1a, 0x1a, 0x2e
bot_r, bot_g, bot_b = 0x16, 0x21, 0x3e

rows = []
for y in range(height):
    t = y / (height - 1)
    r = int(top_r + (bot_r - top_r) * t)
    g = int(top_g + (bot_g - top_g) * t)
    b = int(top_b + (bot_b - bot_b) * t)  # intentional: keep blue channel richer
    row = b'\x00' + bytes([r, g, b] * width)        # filter byte + RGB
    rows.append(row)

raw = b''.join(rows)

def chunk(tag, data):
    c = tag + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

png  = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(raw, 9))
png += chunk(b'IEND', b'')

with open(sys.argv[1], 'wb') as f:
    f.write(png)
PYEOF

printf '    Background: %s (%s bytes)\n' "$bg_image" "$(stat -f%z "$bg_image")"

# ------------------------------------------------------------------
# 2. Create a read-write DMG and populate it
# ------------------------------------------------------------------
printf '==> Creating read-write DMG\n'

hdiutil create -size "$dmg_size" -fs HFS+ -volname "$volume_name" \
    -type SPARSE -o "$rw_dmg" >/dev/null

# hdiutil create with -type SPARSE produces a .sparseimage
rw_dmg="$rw_dmg.sparseimage"

mount_info=$(hdiutil attach "$rw_dmg" -readwrite -noverify -noautoopen)
device=$(echo "$mount_info" | grep -E '/Volumes/' | awk '{print $1}')
mount_point="/Volumes/$volume_name"

printf '==> Copying app bundle to DMG\n'
cp -a "$app_path" "$mount_point/Audio Capture.app"

printf '==> Creating Applications symlink\n'
ln -s /Applications "$mount_point/Applications"

# ------------------------------------------------------------------
# 3. Add the background image inside a hidden .background folder
# ------------------------------------------------------------------
mkdir -p "$mount_point/.background"
cp "$bg_image" "$mount_point/.background/background.png"

# ------------------------------------------------------------------
# 4. Configure Finder view options via AppleScript
# ------------------------------------------------------------------
# Sets icon view, window size, icon size, positions for the app and
# Applications symlink, and the background image.
printf '==> Configuring Finder view options\n'

if osascript <<APPLESCRIPT 2>/dev/null
tell application "Finder"
    tell disk "$volume_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false

        -- Window bounds: {left, top, right, bottom}
        set the bounds of container window to {100, 100, 700, 540}

        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:background.png"

        -- Position the app icon and the Applications alias
        set position of item "Audio Capture.app" of container window to {150, 220}
        set position of item "Applications" of container window to {450, 220}

        close
        open

        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    sync
    sleep 1
else
    printf '    Note: Finder styling skipped (headless/CI environment)\n'
fi

# ------------------------------------------------------------------
# 5. Detach, convert to compressed UDZO format
# ------------------------------------------------------------------
printf '==> Detaching and compressing DMG\n'

hdiutil detach "$device" -force -quiet || true
device=""

mkdir -p "$(dirname "$output_dmg")"

# Remove any previous DMG at the output path
rm -f "$output_dmg"

hdiutil convert "$rw_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$output_dmg" >/dev/null

printf '    Compressed DMG: %s (%s bytes)\n' \
    "$output_dmg" "$(stat -f%z "$output_dmg")"

# ------------------------------------------------------------------
# 6. Optional: Code-sign the DMG
# ------------------------------------------------------------------
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    printf '==> Signing DMG with identity: %s\n' "$DEVELOPER_ID_APPLICATION"
    codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$output_dmg"
    codesign --verify "$output_dmg"
    printf '    DMG signed successfully.\n'
else
    printf '==> Skipping DMG signing (DEVELOPER_ID_APPLICATION not set)\n'
fi

# ------------------------------------------------------------------
# 7. Optional: Notarize the DMG
# ------------------------------------------------------------------
if [[ -n "${NOTARIZATION_APPLE_ID:-}" && -n "${NOTARIZATION_PASSWORD:-}" && -n "${NOTARIZATION_TEAM_ID:-}" ]]; then
    printf '==> Submitting DMG for notarization\n'
    printf '    Apple ID: %s\n' "$NOTARIZATION_APPLE_ID"
    printf '    Team ID:  %s\n' "$NOTARIZATION_TEAM_ID"

    # Submit and wait for the result
    xcrun notarytool submit "$output_dmg" \
        --apple-id "$NOTARIZATION_APPLE_ID" \
        --password "$NOTARIZATION_PASSWORD" \
        --team-id "$NOTARIZATION_TEAM_ID" \
        --wait

    # Staple the notarization ticket to the DMG
    printf '==> Stapling notarization ticket\n'
    xcrun stapler staple "$output_dmg"
    printf '    Notarization complete.\n'
else
    printf '==> Skipping notarization (NOTARIZATION_APPLE_ID / NOTARIZATION_PASSWORD / NOTARIZATION_TEAM_ID not all set)\n'
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
printf '\n==> DMG ready: %s\n' "$output_dmg"

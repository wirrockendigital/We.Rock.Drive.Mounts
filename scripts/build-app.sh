#!/usr/bin/env bash
# Build and sign the complete macOS application bundle for local or distributed use.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH="${WRDM_SCRATCH_PATH:-/tmp/we-rock-drive-mounts-release-${USER}}"
OUTPUT_DIR="${WRDM_OUTPUT_DIR:-$ROOT/build}"
APP="$SCRATCH_PATH/Bundle/We Rock Drive Mounts.app"
AGENT_HELPER_NAME="We Rock Drive Mount Agent"
AGENT_APP_NAME="$AGENT_HELPER_NAME.app"
LOCAL_ARCHIVE="$SCRATCH_PATH/We Rock Drive Mounts.app.zip"
OUTPUT_ARCHIVE="$OUTPUT_DIR/We Rock Drive Mounts.app.zip"
CONTENTS="$APP/Contents"
SPARKLE_FRAMEWORK="$ROOT/ThirdParty/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
AGENT_APP="$CONTENTS/Helpers/$AGENT_APP_NAME"
AGENT_CONTENTS="$AGENT_APP/Contents"
FINDER_EXTENSION_NAME="We Rock Transfer.appex"
FINDER_EXTENSION="$CONTENTS/PlugIns/$FINDER_EXTENSION_NAME"
FINDER_EXTENSION_CONTENTS="$FINDER_EXTENSION/Contents"
FINDER_EXTENSION_EXECUTABLE="WeRockTransferFinderExtension"
ICONSET="$SCRATCH_PATH/AppIcon.iconset"
SIGN_IDENTITY="${WRDM_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${WRDM_NOTARY_PROFILE:-}"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"

# Build both recorded architectures explicitly; local scratch storage avoids SMB compiler metadata issues.
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")"
ARCHITECTURES=(arm64 x86_64)
BIN_PATHS=()
for architecture in "${ARCHITECTURES[@]}"; do
  triple="${architecture}-apple-macosx${MINIMUM_MACOS}"
  build_options=(--package-path "$ROOT" --configuration release --scratch-path "$SCRATCH_PATH/$architecture" --triple "$triple")
  swift build "${build_options[@]}" --disable-index-store
  BIN_PATHS+=("$(swift build "${build_options[@]}" --show-bin-path)")
done

# Merge matching executable slices before signing any bundle component.
universal_executable() {
  local product="$1"
  local destination="$2"
  xcrun lipo -create "${BIN_PATHS[0]}/$product" "${BIN_PATHS[1]}/$product" -output "$destination"
  # Verify each slice separately because Xcode 27 rejects multiple verify_arch arguments.
  for architecture in "${ARCHITECTURES[@]}"; do
    xcrun lipo "$destination" -verify_arch "$architecture"
  done
}

rm -rf "$APP" "$LOCAL_ARCHIVE" "$OUTPUT_ARCHIVE" "$OUTPUT_DIR/We Rock Drive Mounts.app" "$ICONSET"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/PlugIns" "$CONTENTS/Frameworks" "$CONTENTS/Resources/Pi/Companion" "$CONTENTS/Resources/Pi/scripts" "$AGENT_CONTENTS/MacOS" "$AGENT_CONTENTS/Resources" "$FINDER_EXTENSION_CONTENTS/MacOS" "$FINDER_EXTENSION_CONTENTS/Resources" "$ICONSET"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
universal_executable "WeRockDriveMounts" "$CONTENTS/MacOS/WeRockDriveMounts"
# The packaged executable loads the vendored framework from its final bundle path.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/WeRockDriveMounts"
cp "$ROOT/Resources/AgentInfo.plist" "$AGENT_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$AGENT_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$AGENT_CONTENTS/Info.plist"
universal_executable "wrdm-agent" "$AGENT_CONTENTS/MacOS/$AGENT_HELPER_NAME"
universal_executable "wrdm" "$CONTENTS/Helpers/wrdm"
universal_executable "wrdm-mcp" "$CONTENTS/Helpers/wrdm-mcp"
cp "$ROOT/Resources/FinderExtension-Info.plist" "$FINDER_EXTENSION_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$FINDER_EXTENSION_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$FINDER_EXTENSION_CONTENTS/Info.plist"
# Build the Finder Sync extension with Apple's extension entry point and no transfer-engine linkage.
xcrun --sdk macosx clang \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min="$MINIMUM_MACOS" \
  -fobjc-arc \
  -fmodules \
  -fapplication-extension \
  -framework Cocoa \
  -framework FinderSync \
  -Xlinker -e \
  -Xlinker _NSExtensionMain \
  "$ROOT/Extensions/WRDMFinderSync.m" \
  -o "$FINDER_EXTENSION_CONTENTS/MacOS/$FINDER_EXTENSION_EXECUTABLE"
# Use the same per-slice verification for the Finder extension.
for architecture in "${ARCHITECTURES[@]}"; do
  xcrun lipo "$FINDER_EXTENSION_CONTENTS/MacOS/$FINDER_EXTENSION_EXECUTABLE" -verify_arch "$architecture"
done
cp "$ROOT/Companion/wrdm_companion.py" "$ROOT/Companion/wrdm-syslog.service" "$CONTENTS/Resources/Pi/Companion/"
cp "$ROOT/scripts/install-pi-companion.sh" "$CONTENTS/Resources/Pi/scripts/"
cp -R "$ROOT/Resources/de.lproj" "$CONTENTS/Resources/"
cp -R "$ROOT/Resources/de.lproj" "$AGENT_CONTENTS/Resources/"

# Normalize bundle permissions because SMB checkouts can mark source resources as private executables.
find "$CONTENTS" -type d -exec chmod 755 {} +
find "$CONTENTS" -type f -exec chmod 644 {} +
chmod 755 "$CONTENTS/MacOS/WeRockDriveMounts" "$AGENT_CONTENTS/MacOS/$AGENT_HELPER_NAME" "$CONTENTS/Helpers/wrdm" "$CONTENTS/Helpers/wrdm-mcp" "$FINDER_EXTENSION_CONTENTS/MacOS/$FINDER_EXTENSION_EXECUTABLE"
chmod 755 "$CONTENTS/Resources/Pi/scripts/install-pi-companion.sh" "$CONTENTS/Resources/Pi/Companion/wrdm_companion.py"

# Preserve Sparkle's framework symlinks and helper executable modes after source normalization.
rsync -a "$SPARKLE_FRAMEWORK/" "$CONTENTS/Frameworks/Sparkle.framework/"

# Generate every standard macOS icon representation from the project source image.
sips -z 16 16 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

# Remove filesystem metadata from the assembled copy before applying the code signature.
xattr -cr "$APP"

# Sign one component with explicit identifiers and, for local ad hoc builds, a stable designated requirement.
sign_component() {
  local identifier="$1"
  local target="$2"
  local entitlements="${3:-}"
  local options=(--force --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    options+=(--timestamp=none --requirements "=designated => identifier \"$identifier\"")
  else
    options+=(--options runtime --timestamp)
  fi
  if [[ -n "$entitlements" ]]; then
    options+=(--entitlements "$entitlements")
  fi
  codesign "${options[@]}" --identifier "$identifier" "$target"
}

# Sign nested executables and helper app first with explicit identifiers so local beta builds keep stable component identities.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$CONTENTS/Frameworks/Sparkle.framework"
else
  codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp "$CONTENTS/Frameworks/Sparkle.framework"
fi
sign_component "com.we-rock.drive-mounts.agent" "$AGENT_APP"
# Finder Sync extensions must be sandboxed before pluginkit accepts them as a valid extension point implementation.
sign_component "com.we-rock.drive-mounts.finder-extension" "$FINDER_EXTENSION" "$ROOT/Resources/FinderExtension.entitlements"
sign_component "com.we-rock.drive-mounts.cli" "$CONTENTS/Helpers/wrdm"
sign_component "com.we-rock.drive-mounts.mcp" "$CONTENTS/Helpers/wrdm-mcp"
sign_component "com.we-rock.drive-mounts" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize and staple only Developer ID builds with an explicitly configured Keychain profile.
if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf 'WRDM_NOTARY_PROFILE requires a Developer ID identity.\n' >&2
    exit 1
  fi
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$LOCAL_ARCHIVE"
  xcrun notarytool submit "$LOCAL_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$LOCAL_ARCHIVE"
  spctl --assess --type execute --verbose=2 "$APP"
fi

mkdir -p "$OUTPUT_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$LOCAL_ARCHIVE"
cp -X "$LOCAL_ARCHIVE" "$OUTPUT_ARCHIVE"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  printf 'Built local ad hoc signed beta artifact. Gatekeeper distribution requires WRDM_SIGN_IDENTITY and WRDM_NOTARY_PROFILE.\n'
fi
printf 'Built %s\n' "$OUTPUT_ARCHIVE"

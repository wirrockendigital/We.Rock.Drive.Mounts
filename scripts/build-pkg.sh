#!/usr/bin/env bash
# Build a local beta installer package that installs the app and registers the per-user agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
# Consume the bundle from the same scratch directory used by this invocation's app build.
APP_SOURCE="${WRDM_SCRATCH_PATH:-/tmp/we-rock-drive-mounts-release-${USER}}/Bundle/We Rock Drive Mounts.app"
AGENT_HELPER_NAME="We Rock Drive Mount Agent"
AGENT_APP_NAME="$AGENT_HELPER_NAME.app"
OUTPUT_PKG="${WRDM_OUTPUT_PKG:-$ROOT/build/We Rock Drive Mounts-${VERSION}.pkg}"
PKG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrdm-pkg-root.XXXXXX")"
PKG_SCRIPTS="$(mktemp -d "${TMPDIR:-/tmp}/wrdm-pkg-scripts.XXXXXX")"
LOCAL_PKG="$PKG_SCRIPTS/We Rock Drive Mounts-${VERSION}.pkg"
APP_TARGET="$PKG_ROOT/Applications/We Rock Drive Mounts.app"

# cleanup removes only the two private staging directories created for this packaging run.
cleanup() {
  rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
}
trap cleanup EXIT

"$ROOT/scripts/build-app.sh"

mkdir -p "$PKG_ROOT/Applications" "$(dirname "$OUTPUT_PKG")"
# Copy only bundle contents so local filesystem provenance never becomes installer payload.
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP_SOURCE" "$APP_TARGET"
find "$APP_TARGET" -name '._*' -type f -delete
xattr -rc "$APP_TARGET"
# The signed source bundle already has normalized permissions; preserve nested Sparkle executables.
codesign --verify --deep --strict "$APP_TARGET"
# Verification can attach fresh provenance on current macOS builds, so clear it again before packaging.
xattr -rc "$APP_TARGET"

cat > "$PKG_SCRIPTS/preinstall" <<'PREINSTALL'
#!/bin/bash
# Refuse to replace a running transfer worker before the package payload is installed.
set -euo pipefail

INSTALLED_CLI="/Applications/We Rock Drive Mounts.app/Contents/Helpers/wrdm"
if [[ ! -x "$INSTALLED_CLI" ]]; then exit 0; fi
CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
  echo "Cannot verify active transfers without a console user." >&2
  exit 1
fi
CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
if ! /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$INSTALLED_CLI" --json transfer monitoring | /usr/bin/python3 -c '
import json
import sys

try:
    result = json.load(sys.stdin)
    active = int(result["data"]["activeJobs"])
    if result["ok"] is not True or active < 0:
        raise ValueError("invalid transfer status")
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    sys.exit(2)
sys.exit(1 if active else 0)
'; then
  echo "Installation stopped: active transfers or an unreadable transfer status. Retry after transfers finish." >&2
  exit 1
fi
PREINSTALL
chmod 755 "$PKG_SCRIPTS/preinstall"

cat > "$PKG_SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
# Register the per-user WRDM LaunchAgent and CLI links after installing the app bundle.
set -euo pipefail

APP_TARGET="/Applications/We Rock Drive Mounts.app"
AGENT_HELPER_NAME="We Rock Drive Mount Agent"
AGENT_APP_NAME="$AGENT_HELPER_NAME.app"
LABEL="com.we-rock.we-rock-drive-mounts"
BUNDLE_ID="com.we-rock.drive-mounts"
FINDER_EXTENSION_ID="com.we-rock.drive-mounts.finder-extension"
AGENT_EXECUTABLE="$APP_TARGET/Contents/Helpers/$AGENT_APP_NAME/Contents/MacOS/$AGENT_HELPER_NAME"

CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
  echo "No active console user found for WRDM per-user registration." >&2
  exit 1
fi

CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | /usr/bin/sed 's/^NFSHomeDirectory: //')"
DOMAIN="gui/$CONSOLE_UID"
LAUNCH_AGENTS_DIR="$USER_HOME/Library/LaunchAgents"
SUPPORT_DIR="$USER_HOME/Library/Application Support/we-rock-drive-mounts"
LOG_DIR="$USER_HOME/Library/Logs/we-rock-drive-mounts"
LOCAL_BIN="$USER_HOME/.local/bin"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"

if [[ ! -x "$AGENT_EXECUTABLE" ]]; then
  echo "WRDM agent helper is missing from the installed app bundle." >&2
  exit 1
fi

/bin/mkdir -p "$LAUNCH_AGENTS_DIR" "$SUPPORT_DIR/bin" "$LOG_DIR" "$LOCAL_BIN"
/usr/sbin/chown -R "$CONSOLE_USER" "$LAUNCH_AGENTS_DIR" "$SUPPORT_DIR" "$LOG_DIR" "$LOCAL_BIN"
/bin/chmod 700 "$SUPPORT_DIR" "$SUPPORT_DIR/bin" "$LOG_DIR"
/bin/chmod 755 "$LAUNCH_AGENTS_DIR" "$LOCAL_BIN"
# Remove only stale WRDM LaunchAgent transaction files from interrupted installer runs.
/usr/bin/find "$LAUNCH_AGENTS_DIR" -maxdepth 1 -type f \( -name '.com.we-rock.we-rock-drive-mounts.plist.previous.*' -o -name '.com.we-rock.we-rock-drive-mounts.plist.incoming.*' \) -delete
/usr/bin/touch "$LOG_DIR/agent.out.log" "$LOG_DIR/agent.err.log"
/usr/sbin/chown "$CONSOLE_USER" "$LOG_DIR/agent.out.log" "$LOG_DIR/agent.err.log"
/bin/chmod 600 "$LOG_DIR/agent.out.log" "$LOG_DIR/agent.err.log"

/bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
/usr/bin/pkill -x WeRockDriveMounts >/dev/null 2>&1 || true
/usr/bin/pkill -x wrdm-agent >/dev/null 2>&1 || true
/usr/bin/pkill -x "$AGENT_HELPER_NAME" >/dev/null 2>&1 || true
# Remove only WRDM transaction directories left by an interrupted local installer run.
/usr/bin/find /Applications -maxdepth 1 -type d \( -name '.We Rock Drive Mounts.app.previous.*' -o -name '.We Rock Drive Mounts.app.incoming.*' \) -exec /bin/rm -rf {} +

/bin/cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$AGENT_EXECUTABLE</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/agent.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/agent.err.log</string>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>$BUNDLE_ID</string>
    <string>com.we-rock.drive-mounts.agent</string>
  </array>
</dict>
</plist>
PLIST

/usr/sbin/chown "$CONSOLE_USER" "$PLIST"
/bin/chmod 600 "$PLIST"
/usr/bin/plutil -lint "$PLIST" >/dev/null

/bin/ln -sfn "$APP_TARGET/Contents/Helpers/wrdm" "$LOCAL_BIN/wrdm"
/bin/ln -sfn "$APP_TARGET/Contents/Helpers/wrdm-mcp" "$LOCAL_BIN/wrdm-mcp"
/bin/rm -f "$SUPPORT_DIR/bin/wrdm-agent"
/bin/ln -sfn "$AGENT_EXECUTABLE" "$SUPPORT_DIR/bin/$AGENT_HELPER_NAME"
/usr/sbin/chown -h "$CONSOLE_USER" "$LOCAL_BIN/wrdm" "$LOCAL_BIN/wrdm-mcp" "$SUPPORT_DIR/bin/$AGENT_HELPER_NAME"

/bin/launchctl bootstrap "$DOMAIN" "$PLIST"
/bin/launchctl enable "$DOMAIN/$LABEL"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP_TARGET"
/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/pluginkit -a "$APP_TARGET/Contents/PlugIns/We Rock Transfer.appex"
/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/pluginkit -e use -i "$FINDER_EXTENSION_ID"
/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/open -a "$APP_TARGET" || true

exit 0
POSTINSTALL
chmod 755 "$PKG_SCRIPTS/postinstall"

COPYFILE_DISABLE=1 pkgbuild \
  --root "$PKG_ROOT" \
  --scripts "$PKG_SCRIPTS" \
  --identifier com.we-rock.drive-mounts.pkg \
  --version "$VERSION" \
  --install-location / \
  --filter '(^|/)\._[^/]*$' \
  --filter '(^|/)__MACOSX(/|$)' \
  "$LOCAL_PKG"

# Copy the finished package from APFS so an SMB checkout cannot inject AppleDouble payload entries.
cp -X "$LOCAL_PKG" "$OUTPUT_PKG"

printf 'Built %s\n' "$OUTPUT_PKG"

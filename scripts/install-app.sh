#!/usr/bin/env bash
# Build, verify, atomically install, and live-check the app for the current macOS user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ARCHIVE="$ROOT/build/We Rock Drive Mounts.app.zip"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/wrdm-install.XXXXXX")"
APP_SOURCE="$STAGING/We Rock Drive Mounts.app"
APPLICATIONS_DIR="/Applications"
APP_TARGET="$APPLICATIONS_DIR/We Rock Drive Mounts.app"
APP_INCOMING="$APPLICATIONS_DIR/.We Rock Drive Mounts.app.incoming.$$"
APP_BACKUP="$APPLICATIONS_DIR/.We Rock Drive Mounts.app.previous.$$"
SUPPORT_DIR="$HOME/Library/Application Support/we-rock-drive-mounts"
LOG_DIR="$HOME/Library/Logs/we-rock-drive-mounts"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS_DIR/com.we-rock.we-rock-drive-mounts.plist"
PLIST_INCOMING="$LAUNCH_AGENTS_DIR/.com.we-rock.we-rock-drive-mounts.plist.incoming.$$"
PLIST_BACKUP="$LAUNCH_AGENTS_DIR/.com.we-rock.we-rock-drive-mounts.plist.previous.$$"
LABEL="com.we-rock.we-rock-drive-mounts"
BUNDLE_ID="com.we-rock.drive-mounts"
FINDER_EXTENSION_ID="com.we-rock.drive-mounts.finder-extension"
AGENT_HELPER_NAME="We Rock Drive Mount Agent"
AGENT_APP_NAME="$AGENT_HELPER_NAME.app"
DOMAIN="gui/$(id -u)"
LOCAL_BIN="$HOME/.local/bin"
INSTALL_COMMITTED=false
SERVICE_STOPPED=false
SERVICE_WAS_LOADED=false
APP_WAS_RUNNING=false
APP_REPLACEMENT_STARTED=false
PLIST_REPLACEMENT_STARTED=false

# rollback restores the previous app and LaunchAgent when any post-swap check fails.
rollback() {
  local status=$?
  if [[ "$status" -ne 0 && "$INSTALL_COMMITTED" != true ]]; then
    if [[ "$SERVICE_STOPPED" == true ]]; then launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true; fi
    if [[ "$APP_REPLACEMENT_STARTED" == true ]]; then
      rm -rf "$APP_TARGET"
      if [[ -d "$APP_BACKUP" ]]; then mv "$APP_BACKUP" "$APP_TARGET"; fi
    fi
    if [[ "$PLIST_REPLACEMENT_STARTED" == true ]]; then
      rm -f "$PLIST"
      if [[ -f "$PLIST_BACKUP" ]]; then mv "$PLIST_BACKUP" "$PLIST"; fi
    fi
    if [[ "$SERVICE_STOPPED" == true && "$SERVICE_WAS_LOADED" == true && -f "$PLIST" ]]; then launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true; fi
    if [[ "$APP_REPLACEMENT_STARTED" == true && "$APP_WAS_RUNNING" == true && -d "$APP_TARGET" ]]; then open "$APP_TARGET" >/dev/null 2>&1 || true; fi
  fi
  rm -rf "$STAGING" "$APP_INCOMING" "$APP_BACKUP"
  rm -f "$PLIST_INCOMING" "$PLIST_BACKUP"
}
trap rollback EXIT

# Every install consumes an artifact produced in this exact invocation.
"$ROOT/scripts/build-app.sh"
ditto -x -k "$APP_ARCHIVE" "$STAGING"
codesign --verify --deep --strict "$APP_SOURCE"
if codesign -d --verbose=4 "$APP_SOURCE" 2>&1 | grep -q 'Authority=Developer ID Application'; then
  spctl --assess --type execute --verbose=2 "$APP_SOURCE"
else
  printf 'Installing a local ad hoc signed beta build; Gatekeeper distribution is not enabled.\n'
fi

# Refuse to change the ownership or mode of the system Applications directory.
if [[ ! -d "$APPLICATIONS_DIR" || ! -w "$APPLICATIONS_DIR" ]]; then
  printf '%s must exist and be writable by the current administrator account.\n' "$APPLICATIONS_DIR" >&2
  exit 1
fi

# Stage all replacement files on their destination filesystems before stopping the running version.
install -d -m 755 "$LAUNCH_AGENTS_DIR" "$LOCAL_BIN"
install -d -m 700 "$SUPPORT_DIR" "$SUPPORT_DIR/bin" "$LOG_DIR"
# Remove only stale WRDM LaunchAgent transaction files from interrupted installer runs.
find "$LAUNCH_AGENTS_DIR" -maxdepth 1 -type f \( -name '.com.we-rock.we-rock-drive-mounts.plist.previous.*' -o -name '.com.we-rock.we-rock-drive-mounts.plist.incoming.*' \) -delete
# Normalize inherited WRDM runtime data before launch so migrated diagnostics remain private.
find "$SUPPORT_DIR" "$LOG_DIR" -type d -exec chmod 700 {} +
find "$SUPPORT_DIR" "$LOG_DIR" -type f -exec chmod 600 {} +
touch "$LOG_DIR/agent.out.log" "$LOG_DIR/agent.err.log"
chmod 600 "$LOG_DIR/agent.out.log" "$LOG_DIR/agent.err.log"
rm -rf "$APP_INCOMING"
ditto "$APP_SOURCE" "$APP_INCOMING"
codesign --verify --deep --strict "$APP_INCOMING"

# Build the LaunchAgent as a private temporary plist and validate it before the swap.
rm -f "$PLIST_INCOMING"
"$ROOT/scripts/render-launch-agent.sh" "$PLIST_INCOMING" "$APP_TARGET" "$LOG_DIR" "$LABEL" "$BUNDLE_ID"

# Stop owners only after both incoming artifacts have passed structural verification.
# A running agent transfer must finish before replacing its executable.
if [[ -x "$APP_TARGET/Contents/Helpers/wrdm" ]]; then
  if ! "$APP_TARGET/Contents/Helpers/wrdm" --json transfer monitoring | /usr/bin/python3 -c '
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
    printf 'Installation stopped: active transfers or an unreadable transfer status. Retry after transfers finish.\n' >&2
    exit 1
  fi
fi
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then SERVICE_WAS_LOADED=true; fi
if pgrep -x WeRockDriveMounts >/dev/null 2>&1; then APP_WAS_RUNNING=true; fi
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
SERVICE_STOPPED=true
pkill -x WeRockDriveMounts >/dev/null 2>&1 || true
pkill -x wrdm-agent >/dev/null 2>&1 || true
pkill -x "$AGENT_HELPER_NAME" >/dev/null 2>&1 || true
if [[ -d "$APP_TARGET" ]]; then mv "$APP_TARGET" "$APP_BACKUP"; fi
APP_REPLACEMENT_STARTED=true
mv "$APP_INCOMING" "$APP_TARGET"
if [[ -f "$PLIST" ]]; then mv "$PLIST" "$PLIST_BACKUP"; fi
PLIST_REPLACEMENT_STARTED=true
mv "$PLIST_INCOMING" "$PLIST"

# Register the URL handler and Finder extension from their final stable installation path.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP_TARGET"
/usr/bin/pluginkit -a "$APP_TARGET/Contents/PlugIns/We Rock Transfer.appex"
/usr/bin/pluginkit -e use -i "$FINDER_EXTENSION_ID"

launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"
# LaunchServices can report a transient error even after it has started the UI process.
# Treat the bounded live verification below as the authoritative launch result.
open "$APP_TARGET" >/dev/null 2>&1 || true

# Confirm launchd and the shared CLI status path before deleting rollback artifacts.
# Allow slower post-build LaunchServices registration while keeping verification bounded.
for _ in {1..120}; do
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 \
      && launchctl print "$DOMAIN/$LABEL" | grep -q 'state = running' \
      && pgrep -x WeRockDriveMounts >/dev/null 2>&1 \
      && /usr/bin/pluginkit -m -i "$FINDER_EXTENSION_ID" | grep -q "$FINDER_EXTENSION_ID" \
      && "$APP_TARGET/Contents/Helpers/wrdm" --json status >/dev/null 2>&1; then
    # Publish convenience entrypoints only after both native processes pass their checks.
    ln -sfn "$APP_TARGET/Contents/Helpers/wrdm" "$LOCAL_BIN/wrdm"
    ln -sfn "$APP_TARGET/Contents/Helpers/wrdm-mcp" "$LOCAL_BIN/wrdm-mcp"
    rm -f "$SUPPORT_DIR/bin/wrdm-agent"
    ln -sfn "$APP_TARGET/Contents/Helpers/$AGENT_APP_NAME/Contents/MacOS/$AGENT_HELPER_NAME" "$SUPPORT_DIR/bin/$AGENT_HELPER_NAME"
    rm -f "$SUPPORT_DIR/we-rock-drive-mounts.sh"
    INSTALL_COMMITTED=true
    printf 'Installed %s\n' "$APP_TARGET"
    printf 'CLI: %s\n' "$LOCAL_BIN/wrdm"
    exit 0
  fi
  sleep 0.25
done
printf 'The native background agent did not pass its live check. Check %s\n' "$LOG_DIR/agent.err.log" >&2
exit 1

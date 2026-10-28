#!/usr/bin/env bash
# Remove installed executables while preserving user configuration unless --purge is supplied.
set -euo pipefail

APPLICATIONS_DIR="/Applications"
APP_TARGET="$APPLICATIONS_DIR/We Rock Drive Mounts.app"
SUPPORT_DIR="$HOME/Library/Application Support/we-rock-drive-mounts"
LOG_DIR="$HOME/Library/Logs/we-rock-drive-mounts"
PLIST="$HOME/Library/LaunchAgents/com.we-rock.we-rock-drive-mounts.plist"
APP_LOGIN_PLIST="$HOME/Library/LaunchAgents/com.we-rock.drive-mounts.app-login.plist"
APP_LOGIN_LABEL="com.we-rock.drive-mounts.app-login"
DOMAIN="gui/$(id -u)"
AGENT_HELPER_NAME="We Rock Drive Mount Agent"
AGENT_APP_NAME="$AGENT_HELPER_NAME.app"
FINDER_EXTENSION_ID="com.we-rock.drive-mounts.finder-extension"

launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
launchctl bootout "$DOMAIN/$APP_LOGIN_LABEL" >/dev/null 2>&1 || true
pkill -x WeRockDriveMounts >/dev/null 2>&1 || true
pkill -x wrdm-agent >/dev/null 2>&1 || true
pkill -x "$AGENT_HELPER_NAME" >/dev/null 2>&1 || true
# Disable and unregister only the WRDM Finder extension before removing its bundle.
/usr/bin/pluginkit -e ignore -i "$FINDER_EXTENSION_ID" >/dev/null 2>&1 || true
/usr/bin/pluginkit -r "$APP_TARGET/Contents/PlugIns/We Rock Transfer.appex" >/dev/null 2>&1 || true
# Remove native artifacts and any retired shell runtime left by pre-beta installations.
rm -f "$PLIST" "$APP_LOGIN_PLIST" "$HOME/.local/bin/wrdm" "$HOME/.local/bin/wrdm-mcp" "$SUPPORT_DIR/bin/wrdm-agent" "$SUPPORT_DIR/bin/$AGENT_HELPER_NAME" "$SUPPORT_DIR/bin/$AGENT_APP_NAME" "$SUPPORT_DIR/we-rock-drive-mounts.sh"
rm -rf "$APP_TARGET"
# Remove only WRDM transaction directories left by an interrupted local installer run.
find "$APPLICATIONS_DIR" -maxdepth 1 -type d \( -name '.We Rock Drive Mounts.app.previous.*' -o -name '.We Rock Drive Mounts.app.incoming.*' \) -exec rm -rf {} +
# Remove only WRDM LaunchAgent transaction files left by an interrupted local installer run.
find "$HOME/Library/LaunchAgents" -maxdepth 1 -type f \( -name '.com.we-rock.we-rock-drive-mounts.plist.previous.*' -o -name '.com.we-rock.we-rock-drive-mounts.plist.incoming.*' \) -delete

# Purging is explicit because configuration and diagnostic evidence belong to the user.
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$SUPPORT_DIR" "$LOG_DIR"
  printf 'Removed app, configuration, and logs.\n'
else
  printf 'Removed app. Configuration and logs were preserved.\n'
fi

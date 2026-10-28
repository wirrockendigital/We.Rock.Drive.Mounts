#!/usr/bin/env bash
# Render and validate the private per-user LaunchAgent plist used by the installer.
set -euo pipefail

if [[ "$#" -ne 5 ]]; then
  printf 'Usage: %s OUTPUT_PLIST APP_PATH LOG_DIR LABEL BUNDLE_ID\n' "$0" >&2
  exit 64
fi

OUTPUT_PLIST="$1"
APP_PATH="$2"
LOG_DIR="$3"
LABEL="$4"
BUNDLE_ID="$5"

# Create the complete plist atomically at the installer-provided staging path.
plutil -create xml1 "$OUTPUT_PLIST"
plutil -insert Label -string "$LABEL" "$OUTPUT_PLIST"
plutil -insert AssociatedBundleIdentifiers -xml '<array/>' "$OUTPUT_PLIST"
plutil -insert AssociatedBundleIdentifiers.0 -string "$BUNDLE_ID" "$OUTPUT_PLIST"
plutil -insert AssociatedBundleIdentifiers.1 -string "com.we-rock.drive-mounts.agent" "$OUTPUT_PLIST"
plutil -insert ProgramArguments -xml '<array/>' "$OUTPUT_PLIST"
plutil -insert ProgramArguments.0 -string "$APP_PATH/Contents/Helpers/We Rock Drive Mount Agent.app/Contents/MacOS/We Rock Drive Mount Agent" "$OUTPUT_PLIST"
plutil -insert KeepAlive -bool true "$OUTPUT_PLIST"
plutil -insert RunAtLoad -bool true "$OUTPUT_PLIST"
plutil -insert ProcessType -string Background "$OUTPUT_PLIST"
plutil -insert StandardOutPath -string "$LOG_DIR/agent.out.log" "$OUTPUT_PLIST"
plutil -insert StandardErrorPath -string "$LOG_DIR/agent.err.log" "$OUTPUT_PLIST"
chmod 600 "$OUTPUT_PLIST"
plutil -lint "$OUTPUT_PLIST"

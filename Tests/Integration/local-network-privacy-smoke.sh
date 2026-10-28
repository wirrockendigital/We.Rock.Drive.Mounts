#!/usr/bin/env bash
# Verify the source-level local-network privacy and stable-signing deployment contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFO_PLIST="$ROOT/Resources/Info.plist"
AGENT_INFO_PLIST="$ROOT/Resources/AgentInfo.plist"
GERMAN_INFO_PLIST_STRINGS="$ROOT/Resources/de.lproj/InfoPlist.strings"
APP_BUNDLE="${1:-}"

# The fallback and German descriptions must both be non-empty and name the product purpose.
DESCRIPTION="$(plutil -extract NSLocalNetworkUsageDescription raw "$INFO_PLIST")"
[[ -n "$DESCRIPTION" ]]
grep -q 'SMB' <<<"$DESCRIPTION"
AGENT_DESCRIPTION="$(plutil -extract NSLocalNetworkUsageDescription raw "$AGENT_INFO_PLIST")"
[[ -n "$AGENT_DESCRIPTION" ]]
grep -q 'SMB' <<<"$AGENT_DESCRIPTION"
plutil -lint "$GERMAN_INFO_PLIST_STRINGS" >/dev/null
grep -q 'NSLocalNetworkUsageDescription' "$GERMAN_INFO_PLIST_STRINGS"

# The rendered launchd helper must be attributed to the owning app bundle identifier.
LAUNCH_AGENT_PLIST="$(mktemp "${TMPDIR:-/tmp}/wrdm-launch-agent-test.XXXXXX")"
"$ROOT/scripts/render-launch-agent.sh" \
  "$LAUNCH_AGENT_PLIST" \
  "/Applications/We Rock Drive Mounts.app" \
  "$HOME/Library/Logs/we-rock-drive-mounts" \
  "com.we-rock.we-rock-drive-mounts" \
  "com.we-rock.drive-mounts" >/dev/null
[[ "$(plutil -extract AssociatedBundleIdentifiers.0 raw "$LAUNCH_AGENT_PLIST")" == "com.we-rock.drive-mounts" ]]
[[ "$(plutil -extract AssociatedBundleIdentifiers.1 raw "$LAUNCH_AGENT_PLIST")" == "com.we-rock.drive-mounts.agent" ]]
[[ "$(plutil -extract ProgramArguments.0 raw "$LAUNCH_AGENT_PLIST")" == "/Applications/We Rock Drive Mounts.app/Contents/Helpers/We Rock Drive Mount Agent.app/Contents/MacOS/We Rock Drive Mount Agent" ]]

# The UI must display the running product version without an internal build counter.
grep -q 'Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")' "$ROOT/Sources/WRDMApp/Views.swift"
! grep -q 'Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")' "$ROOT/Sources/WRDMApp/Views.swift"

# When a built or installed bundle is supplied, validate its real metadata and component identities.
if [[ -n "$APP_BUNDLE" ]]; then
  [[ "$(plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Info.plist")" == "com.we-rock.drive-mounts" ]]
  [[ "$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Info.plist")" == "$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" ]]
  [[ "$(plutil -extract CFBundleVersion raw "$APP_BUNDLE/Contents/Info.plist")" == "$(plutil -extract CFBundleVersion raw "$INFO_PLIST")" ]]
  [[ -n "$(plutil -extract NSLocalNetworkUsageDescription raw "$APP_BUNDLE/Contents/Info.plist")" ]]
  [[ "$(plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Helpers/We Rock Drive Mount Agent.app/Contents/Info.plist")" == "com.we-rock.drive-mounts.agent" ]]
  [[ "$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Helpers/We Rock Drive Mount Agent.app/Contents/Info.plist")" == "$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" ]]
  [[ -n "$(plutil -extract NSLocalNetworkUsageDescription raw "$APP_BUNDLE/Contents/Helpers/We Rock Drive Mount Agent.app/Contents/Info.plist")" ]]
  [[ -x "$APP_BUNDLE/Contents/Helpers/We Rock Drive Mount Agent.app/Contents/MacOS/We Rock Drive Mount Agent" ]]
  [[ ! -e "$APP_BUNDLE/Contents/Helpers/We Rock Drive Mount Agent" ]]
  [[ ! -e "$APP_BUNDLE/Contents/Helpers/wrdm-agent" ]]
  codesign --verify --deep --strict "$APP_BUNDLE"

  # Explicit ad hoc identifiers remain stable even though new binary content receives a new cdhash.
  declare -a SIGNED_PATHS=("$APP_BUNDLE" "$APP_BUNDLE/Contents/Helpers/We Rock Drive Mount Agent.app" "$APP_BUNDLE/Contents/Helpers/wrdm" "$APP_BUNDLE/Contents/Helpers/wrdm-mcp")
  declare -a EXPECTED_IDENTIFIERS=("com.we-rock.drive-mounts" "com.we-rock.drive-mounts.agent" "com.we-rock.drive-mounts.cli" "com.we-rock.drive-mounts.mcp")
  for signed_index in "${!SIGNED_PATHS[@]}"; do
    SIGNED_DETAILS="$(codesign -d --verbose=4 "${SIGNED_PATHS[$signed_index]}" 2>&1)"
    [[ "$(sed -n 's/^Identifier=//p' <<<"$SIGNED_DETAILS" | head -n 1)" == "${EXPECTED_IDENTIFIERS[$signed_index]}" ]]
    grep -q '^Signature=adhoc$' <<<"$SIGNED_DETAILS"
    DESIGNATED_REQUIREMENT="$(codesign -dr - "${SIGNED_PATHS[$signed_index]}" 2>&1)"
    grep -q "designated => identifier \"${EXPECTED_IDENTIFIERS[$signed_index]}\"" <<<"$DESIGNATED_REQUIREMENT"
    ! grep -q 'designated => cdhash' <<<"$DESIGNATED_REQUIREMENT"
  done
fi

# Remove only the exact generated LaunchAgent fixture when the smoke test exits.
trap 'rm -f "$LAUNCH_AGENT_PLIST"' EXIT

printf 'Local-network privacy contract smoke test passed.\n'

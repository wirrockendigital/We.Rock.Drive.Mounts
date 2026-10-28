#!/usr/bin/env bash
# Generate the signed Sparkle feed from the exact ZIP uploaded to GitHub Releases.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ARCHIVE="${1:?Pass the release ZIP as the first argument}"
SPARKLE_TOOL="${SPARKLE_GENERATE_APPCAST:?Set SPARKLE_GENERATE_APPCAST to the trusted Sparkle generate_appcast binary}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/wrdm-appcast.XXXXXX")"
trap 'rm -r "$STAGING"' EXIT

# Preserve existing entries while adding the ZIP for this release.
if [[ -f "$ROOT/docs/appcast.xml" ]]; then
  cp "$ROOT/docs/appcast.xml" "$STAGING/appcast.xml"
fi
cp "$ARCHIVE" "$STAGING/We Rock Drive Mounts-${VERSION}.zip"
cat > "$STAGING/We Rock Drive Mounts-${VERSION}.md" <<NOTES
We Rock Drive Mounts ${VERSION} mit manueller und täglicher Update-Prüfung, Hinweis auf neue Versionen und Installation auf Knopfdruck.
NOTES

# The private Ed25519 seed is read from stdin and never enters project files or command arguments.
"$SPARKLE_TOOL" --ed-key-file - --embed-release-notes \
  --download-url-prefix "https://github.com/wirrockendigital/We.Rock.Drive.Mounts/releases/download/v${VERSION}/" \
  "$STAGING"
mkdir -p "$ROOT/docs"
cp "$STAGING/appcast.xml" "$ROOT/docs/appcast.xml"

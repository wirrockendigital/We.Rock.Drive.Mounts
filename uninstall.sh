#!/usr/bin/env bash
# Uninstall the native menu-bar app for the current user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT/scripts/uninstall-app.sh" "$@"

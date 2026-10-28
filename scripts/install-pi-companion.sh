#!/usr/bin/env bash
# Install the bounded Raspberry Pi companion and its managed syslog receiver.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/we-rock-drive-mounts-companion"
STATE_DIR="/var/lib/we-rock-drive-mounts"
LOG_DIR="/var/log/we-rock-drive-mounts"
SERVICE_NAME="wrdm-syslog.service"
SYSLOG_PORT="5514"

# Parse the one managed installer setting and reject unknown arguments.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --syslog-port)
      SYSLOG_PORT="${2:-}"
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
if [[ ! "$SYSLOG_PORT" =~ ^[0-9]+$ ]] || (( SYSLOG_PORT < 1 || SYSLOG_PORT > 65535 )); then
  printf 'Invalid syslog port.\n' >&2
  exit 2
fi

install -d -m 0755 "$INSTALL_DIR"
install -d -m 2775 "$STATE_DIR" "$STATE_DIR/captures" "$LOG_DIR"
install -m 0755 "$SOURCE_DIR/wrdm_companion.py" "$INSTALL_DIR/wrdm-companion"
install -m 0644 "$SOURCE_DIR/wrdm-syslog.service" "/etc/systemd/system/$SERVICE_NAME"
install -d -m 0755 "/etc/systemd/system/$SERVICE_NAME.d"
printf '[Service]\nEnvironment=WRDM_SYSLOG_PORT=%s\n' "$SYSLOG_PORT" \
  > "/etc/systemd/system/$SERVICE_NAME.d/port.conf"

# Grant the invoking SSH user capture-directory access without granting shell sudo rights.
if getent group wireshark >/dev/null 2>&1; then
  chgrp -R wireshark "$STATE_DIR" "$LOG_DIR"
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    usermod -a -G wireshark "$SUDO_USER"
  fi
fi

# Preserve Wireshark's least-privilege dumpcap model when capability tools are available.
if command -v dumpcap >/dev/null 2>&1 && command -v setcap >/dev/null 2>&1; then
  setcap cap_net_raw,cap_net_admin=eip "$(command -v dumpcap)"
fi

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
"$INSTALL_DIR/wrdm-companion" health

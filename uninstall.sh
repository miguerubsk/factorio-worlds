#!/bin/bash
# factorio-worlds uninstaller. Worlds and settings are kept unless --purge.
#
#   sudo ./uninstall.sh [--purge]
set -euo pipefail

CONF=/etc/factorio-worlds.conf
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

[ "$EUID" -eq 0 ] || { echo "Run it as root: sudo $0" >&2; exit 1; }
FW_ROOT=/opt/factorio; FW_USER=factorio; FW_LIBDIR=/usr/local/lib/factorio-worlds
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

echo "==> Stopping services"
systemctl stop 'factorio@*.service' 'factorio-render@*.service' 2>/dev/null || true
systemctl disable --now factorio.service factorio-render.timer \
                        factorio-update.timer 2>/dev/null || true

echo "==> Removing units, polkit rule, code and commands"
rm -f /etc/systemd/system/factorio@.service \
      /etc/systemd/system/factorio-notifier@.service \
      /etc/systemd/system/factorio-render@.service \
      /etc/systemd/system/factorio.service \
      /etc/systemd/system/factorio-render.service \
      /etc/systemd/system/factorio-render.timer \
      /etc/systemd/system/factorio-update.service \
      /etc/systemd/system/factorio-update.timer \
      /etc/polkit-1/rules.d/50-factorio-worlds.rules
systemctl daemon-reload
for l in /usr/local/bin/factorio-worlds /usr/local/bin/factorio; do
    [ -L "$l" ] && [ "$(readlink -f "$l")" = "$FW_LIBDIR/bin/factorio-worlds" ] && rm -f "$l"
done
rm -rf "$FW_LIBDIR" "$CONF"

if [ "$PURGE" = 1 ]; then
    read -r -p "Delete $FW_ROOT with ALL worlds and saves, and the user '$FW_USER'? Type 'purge': " ans
    if [ "$ans" = purge ]; then
        rm -rf "$FW_ROOT"
        userdel "$FW_USER" 2>/dev/null || true
        groupdel "$FW_USER" 2>/dev/null || true
        echo "Purged."
    else
        echo "Data kept in $FW_ROOT."
    fi
else
    echo "Worlds and settings kept in $FW_ROOT (use --purge to delete them)."
fi

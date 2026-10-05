#!/bin/bash
# Updates the headless server of every world (or one) to the latest stable.
# Usage (root): update.sh [world|all]
# Only the running world is stopped and restarted; the others are updated cold.
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

[ "$EUID" -eq 0 ] || { echo "ERROR: run as root (sudo factorio-worlds update)"; exit 1; }

TARGET="${1:-all}"
log() { echo "$(date +'%F %T') - $*"; }

if [ "$TARGET" = "all" ]; then
    WORLDS=$(list_instances)
else
    instance_exists "$TARGET" || { echo "ERROR: world '$TARGET' does not exist"; exit 1; }
    WORLDS="$TARGET"
fi

REMOTE=$(resolve_version stable)
[ -n "$REMOTE" ] || { log "ERROR: could not get the latest stable version"; exit 1; }
log "Latest stable: $REMOTE"
RUNNING=$(running_instance)
rc=0

for w in $WORLDS; do
    ( # subshell: each world with its own environment
    load_instance "$w" || exit 1
    [ "$UPDATE" = "1" ] || { log "[$INSTANCE] UPDATE=0, skipped."; exit 0; }
    [ -f "$FACTORIO_BIN" ] && chmod +x "$FACTORIO_BIN"
    LOCAL=$(factorio_version "$FACTORIO_BIN" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    log "[$INSTANCE] Installed: ${LOCAL:-none}"

    HIGHEST=$(printf '%s\n%s\n' "$LOCAL" "$REMOTE" | sort -V | tail -n 1)
    if [ "$LOCAL" = "$REMOTE" ] || [ "$HIGHEST" = "$LOCAL" ]; then
        log "[$INSTANCE] Up to date."; exit 0
    fi

    notify "$(msg "$MSG_UPDATE_START" name "$DISPLAY_NAME" world "$WORLD_NAME" old "${LOCAL:-?}" new "$REMOTE")"
    TARBALL=$(fetch_headless "$REMOTE") || {
        notify "$(msg "$MSG_UPDATE_FAIL" name "$DISPLAY_NAME" world "$WORLD_NAME" new "$REMOTE")"
        log "[$INSTANCE] ERROR: download failed"; exit 1; }

    WAS_RUNNING=0
    [ "$RUNNING" = "$INSTANCE" ] && { WAS_RUNNING=1; systemctl stop "$UNIT"; }

    # Light backup: world config, main save and mod list (keeps the last 5)
    mkdir -p "$BACKUP_DIR/$INSTANCE"
    # shellcheck disable=SC2046  # optional files, word splitting intended
    tar -czf "$BACKUP_DIR/$INSTANCE/pre-update_${LOCAL:-unknown}_$(date +%Y%m%d%H%M).tar.gz" -C "$INSTANCE_DIR" \
        .env $(cd "$INSTANCE_DIR" && ls "saves/$SAVE_NAME.zip" mods/mod-list.json mods/mod-settings.dat server-settings.override.json 2>/dev/null)
    find "$BACKUP_DIR/$INSTANCE" -maxdepth 1 -name 'pre-update_*.tar.gz' -printf '%T@ %p\n' \
        | sort -rn | tail -n +6 | cut -d' ' -f2- | xargs -r rm -f

    tar -xf "$TARBALL" -C "$INSTANCE_DIR" --strip-components=1
    chown -R "$FW_USER:$FW_USER" "$INSTANCE_DIR"
    [ "$WAS_RUNNING" = "1" ] && systemctl start "$UNIT"

    NEW=$(factorio_version "$FACTORIO_BIN")
    log "[$INSTANCE] Updated to $NEW"
    notify "$(msg "$MSG_UPDATE_DONE" name "$DISPLAY_NAME" world "$WORLD_NAME" new "$NEW")"
    ) || rc=1
done
exit $rc

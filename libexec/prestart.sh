#!/bin/bash
# ExecStartPre of factorio@<name>: sanity checks, crash recovery of the
# save and generation of server-settings from the shared configuration.
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
load_instance "$1" || exit 1

log() { echo "[$INSTANCE] $*"; }

# 1. One world at a time: they share the game and RCON ports
for other in $(running_instances); do
    if [ "$other" != "$INSTANCE" ]; then
        log "ERROR: world '$other' is already running. Use: factorio-worlds switch $INSTANCE"
        exit 1
    fi
done

[ -x "$FACTORIO_BIN" ] || { log "ERROR: $FACTORIO_BIN is missing or not executable"; exit 1; }

# 2. Crash recovery: an autosave newer than the main save means the server did
#    not shut down cleanly -> it replaces the main save (old one kept aside).
sleep 2
LATEST=""
for f in "$INSTANCE_DIR"/saves/*.zip; do
    [ -f "$f" ] || continue
    [[ "$f" == *.tmp.zip ]] && continue
    { [ -z "$LATEST" ] || [ "$f" -nt "$LATEST" ]; } && LATEST="$f"
done
if [ -n "$LATEST" ] && [ "$LATEST" != "$SAVE_PATH" ] && [ -s "$LATEST" ] \
   && { [ ! -f "$SAVE_PATH" ] || [ "$LATEST" -nt "$SAVE_PATH" ]; }; then
    log "[RECOVERY] Unclean shutdown detected. Newest save is $LATEST; copying it over $SAVE_PATH"
    [ -f "$SAVE_PATH" ] && cp -p "$SAVE_PATH" "$SAVE_PATH.pre-recovery"
    cp -p "$LATEST" "$SAVE_PATH"
fi
[ -f "$SAVE_PATH" ] || { log "ERROR: save $SAVE_PATH does not exist"; exit 1; }

# 3. Shared base settings, created from the game's example on first use
BASE="$FW_COMMON/server-settings.base.json"
if [ ! -f "$BASE" ]; then
    EXAMPLE="$INSTANCE_DIR/data/server-settings.example.json"
    [ -f "$EXAMPLE" ] || { log "ERROR: no $BASE and no $EXAMPLE to create it from"; exit 1; }
    # Public visibility needs factorio.com credentials: start as LAN-only
    jq '.visibility.public = false' "$EXAMPLE" > "$BASE" || exit 1
    chmod 640 "$BASE"
    log "Created $BASE from the game's example (LAN only)"
fi

# 4. server-settings = base * world override * {name}
OVERRIDE='{}'
[ -f "$SETTINGS_OVERRIDE" ] && OVERRIDE=$(cat "$SETTINGS_OVERRIDE")
umask 027
if ! jq --argjson ov "$OVERRIDE" --arg name "$DISPLAY_NAME" \
        '. * $ov * {name: $name}' "$BASE" > "$SETTINGS_GENERATED.tmp"; then
    log "ERROR generating $SETTINGS_GENERATED (is $SETTINGS_OVERRIDE valid JSON?)"; exit 1
fi
mv "$SETTINGS_GENERATED.tmp" "$SETTINGS_GENERATED"

# 5. Clean state and a bounded console log (rotated past 50 MB)
echo 0 > "$PLAYER_COUNT_FILE"
if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -gt 52428800 ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.old"
fi

echo "$INSTANCE" > "$ACTIVE_FILE"
log "Ready: save=$SAVE_NAME version=$(factorio_version "$FACTORIO_BIN")"

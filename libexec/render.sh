#!/bin/bash
# Map render with mapshot (optional module: MAPSHOT_ENABLED=1, per world RENDER=1).
#
# Renders a world only if someone played since the last render and nobody is
# online right now. Usage: render.sh <daily|after-leave> [world]
#   daily        the daily timer; without a world it goes through every world
#                with RENDER=1. If players are online it leaves the render pending.
#   after-leave  started by the watcher when the last player leaves; renders
#                only if the daily run left it pending.
#
# Flags in each world directory:
#   .had_activity    created by the watcher on every join, removed after a render
#   .render_pending  created here when the daily render had to wait
set -o pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

MODE="${1:-daily}"
case "$MODE" in daily|after-leave) ;; *) echo "Usage: $0 <daily|after-leave> [world]" >&2; exit 2 ;; esac

log() { logger -t factorio-worlds-render "$*" 2>/dev/null; echo "$(date '+%F %T') [render] $*"; }

# Daily run without a world: every world with RENDER=1, one after another
if [ "$MODE" = "daily" ] && [ -z "$2" ]; then
    rc=0
    for w in $(list_instances); do
        ( load_instance "$w" >/dev/null 2>&1 && [ "$RENDER" = "1" ] ) || continue
        "$0" daily "$w" || rc=1
    done
    exit $rc
fi

WORLD="${2:-$(running_instance)}"
load_instance "$WORLD" || exit 1

if [ "$MAPSHOT_ENABLED" != "1" ] || [ "$RENDER" != "1" ]; then
    log "[$INSTANCE] Map render disabled (MAPSHOT_ENABLED=$MAPSHOT_ENABLED, RENDER=$RENDER)."
    exit 0
fi

MAPSHOT_BIN="${MAPSHOT_BIN:-/usr/local/bin/mapshot}"
CLIENT_DIR="${MAPSHOT_FACTORIO_DIR:?MAPSHOT_FACTORIO_DIR is not set}"
CLIENT_BIN="$CLIENT_DIR/bin/x64/factorio"
OUTPUT_DIR="${MAPSHOT_OUTPUT_DIR:?MAPSHOT_OUTPUT_DIR is not set}/$SAVE_NAME"
SCRIPT_OUTPUT="$CLIENT_DIR/script-output/mapshot/$SAVE_NAME"

# 1. One render per world at a time
exec 9>"$RENDER_LOCK" || { log "[$INSTANCE] Cannot create $RENDER_LOCK"; exit 1; }
flock -n 9 || { log "[$INSTANCE] A render is already running."; exit 0; }

# 2. Nobody played since the last render -> nothing to do
if [ ! -f "$FLAG_ACTIVITY" ]; then
    log "[$INSTANCE] No activity since the last render ($MODE)."
    rm -f "$FLAG_PENDING"
    exit 0
fi

# 3. Players online now. RCON is shared: if this world is not the running one,
#    RCON would answer for ANOTHER world, so it is not asked (save is static).
if [ "$(running_instance)" = "$INSTANCE" ]; then
    n=$(players_online)
else
    n=0
fi

if [ "$MODE" = "daily" ]; then
    if [ "$n" = "-1" ]; then
        log "[$INSTANCE] RCON not answering; leaving the render pending to be safe."
        touch "$FLAG_PENDING"; exit 0
    elif [ "$n" -gt 0 ] 2>/dev/null; then
        log "[$INSTANCE] $n player(s) online; render pending until the last one leaves."
        touch "$FLAG_PENDING"; exit 0
    fi
else
    [ -f "$FLAG_PENDING" ] || { log "[$INSTANCE] Last player left, no render pending."; exit 0; }
    [ "$n" -gt 0 ] 2>/dev/null && { log "[$INSTANCE] Still $n player(s) online."; exit 0; }
fi

# ==============================================================================
# RENDER
# ==============================================================================
[ -f "$SAVE_PATH" ]   || { log "[$INSTANCE] ERROR: $SAVE_PATH not found"; exit 1; }
[ -x "$MAPSHOT_BIN" ] || { log "[$INSTANCE] ERROR: $MAPSHOT_BIN not executable"; exit 1; }
[ -x "$CLIENT_BIN" ]  || { log "[$INSTANCE] ERROR: $CLIENT_BIN not executable"; exit 1; }
mkdir -p "$OUTPUT_DIR" || { log "[$INSTANCE] ERROR: cannot create $OUTPUT_DIR"; exit 1; }

WORKDIR=$(mktemp -d /tmp/fw-render.XXXXXX)
cleanup() { rm -rf "$WORKDIR" "$SCRIPT_OUTPUT"; rmdir "$CLIENT_DIR/script-output/mapshot" 2>/dev/null; }
trap cleanup EXIT

# Render a copy: the server may be writing the original
cp "$SAVE_PATH" "$WORKDIR/$SAVE_NAME.zip" || { log "[$INSTANCE] ERROR copying the save"; exit 1; }
log "[$INSTANCE] Rendering..."
notify "$(msg "$MSG_RENDER_START" world "$WORLD_NAME" name "$DISPLAY_NAME")"

start=$(date +%s)
XVFB=(); command -v xvfb-run >/dev/null 2>&1 && XVFB=(xvfb-run -a)
if ! "${XVFB[@]}" "$MAPSHOT_BIN" render "$WORKDIR/$SAVE_NAME.zip" \
        --factorio_binary "$CLIENT_BIN" --factorio_datadir "$CLIENT_DIR" \
        >>"$WORKDIR/render.log" 2>&1; then
    cp "$WORKDIR/render.log" "$INSTANCE_DIR/last-render-error.log" 2>/dev/null
    log "[$INSTANCE] ERROR: mapshot failed, see $INSTANCE_DIR/last-render-error.log"
    notify "$(msg "$MSG_RENDER_FAIL" world "$WORLD_NAME" name "$DISPLAY_NAME")"
    exit 1
fi
secs=$(( $(date +%s) - start ))

NEW_DIR=$(find "$SCRIPT_OUTPUT" -maxdepth 1 -type d -name 'd-*' 2>/dev/null | sort | tail -1)
# The name is a hash of the save: an unchanged save gives the same directory,
# which then just replaces the previous identical render
[ -n "$NEW_DIR" ] && rm -rf "${OUTPUT_DIR:?}/$(basename "$NEW_DIR")"
if [ -z "$NEW_DIR" ] || ! mv "$NEW_DIR" "$OUTPUT_DIR/"; then
    log "[$INSTANCE] ERROR: render output not found or could not be moved"
    notify "$(msg "$MSG_RENDER_FAIL" world "$WORLD_NAME" name "$DISPLAY_NAME")"
    exit 1
fi

rm -f "$FLAG_ACTIVITY" "$FLAG_PENDING"
took="$((secs / 60))m $((secs % 60))s"
log "[$INSTANCE] Done in $took: $OUTPUT_DIR/$(basename "$NEW_DIR")"
notify "$(msg "$MSG_RENDER_DONE" world "$WORLD_NAME" name "$DISPLAY_NAME" time "$took")"

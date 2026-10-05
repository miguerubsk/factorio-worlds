#!/bin/bash
# ExecStart of factorio@<name>: starts the server inside screen.
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
load_instance "$1" || exit 1

ARGS=(
    --start-server "$SAVE_PATH"
    --server-settings "$SETTINGS_GENERATED"
    --port "$GAME_PORT"
    --rcon-password "$RCON_PASSWORD"
    --server-adminlist "$FW_COMMON/server-adminlist.json"
    --server-banlist "$FW_COMMON/server-banlist.json"
)
# RCON_BIND=IP restricts where RCON listens (e.g. 127.0.0.1 or the LAN address)
if [ -n "$RCON_BIND" ]; then ARGS+=(--rcon-bind "$RCON_BIND:$RCON_PORT"); else ARGS+=(--rcon-port "$RCON_PORT"); fi
# Factorio refuses --server-whitelist without --use-server-whitelist: both or none
[ "$USE_WHITELIST" = "1" ] && ARGS+=(--use-server-whitelist --server-whitelist "$FW_COMMON/server-whitelist.json")
# shellcheck disable=SC2206  # word splitting is intended
[ -n "$EXTRA_ARGS" ] && ARGS+=($EXTRA_ARGS)

exec /usr/bin/screen -L -Logfile "$LOG_FILE" -dmS "$SESSION" "$FACTORIO_BIN" "${ARGS[@]}"

#!/bin/bash
# Follows the console log of factorio@<name>: Telegram notifications,
# player count and activity flags for the map render. systemd starts and
# stops it together with the world (factorio-notifier@<name>).
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
load_instance "$1" || exit 1

[ -f "$PLAYER_COUNT_FILE" ] || echo "0" > "$PLAYER_COUNT_FILE"
get_count() { cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0"; }
set_count() { echo "$1" > "$PLAYER_COUNT_FILE"; }

LAST_IP=""
LAST_TIME=0
echo "Watching $DISPLAY_NAME: $LOG_FILE"

tail -n 0 -F "$LOG_FILE" 2>/dev/null | while read -r line; do

    # 1. Connection attempt
    if [[ "$line" == *ConnectionRequestReplyConfirm* ]]; then
        IP=$(echo "$line" | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
        NOW=$(date +%s)
        # Debounce: the same IP within 10 s is the same attempt
        if [ "$IP" = "$LAST_IP" ] && [ $((NOW - LAST_TIME)) -lt 10 ]; then
            continue
        fi
        LAST_IP="$IP"; LAST_TIME=$NOW
        notify "$(msg "$MSG_CONNECTING" ip "${IP:-unknown}" world "$WORLD_NAME" name "$DISPLAY_NAME")"
    fi

    # 2. Player joined
    if [[ "$line" == *"[JOIN]"* ]]; then
        PLAYER=$(echo "$line" | sed -n 's/.*\[JOIN\] \(.*\) joined the game.*/\1/p')
        if [ -n "$PLAYER" ]; then
            notify "$(msg "$MSG_JOIN" player "$PLAYER" world "$WORLD_NAME" name "$DISPLAY_NAME")"
            set_count $(( $(get_count) + 1 ))
            touch "$FLAG_ACTIVITY"
        fi
    fi

    # 3. Player left
    if [[ "$line" == *"[LEAVE]"* ]]; then
        PLAYER=$(echo "$line" | sed -n 's/.*\[LEAVE\] \(.*\) left the game.*/\1/p')
        if [ -n "$PLAYER" ]; then
            notify "$(msg "$MSG_LEAVE" player "$PLAYER" world "$WORLD_NAME" name "$DISPLAY_NAME")"
            count=$(( $(get_count) - 1 ))
            [ "$count" -lt 0 ] && count=0
            set_count "$count"
            # Last one out: run the pending map render, if any. Through systemd
            # so the render survives a restart of this watcher.
            if [ "$count" -eq 0 ] && [ "$RENDER" = "1" ] && [ "$MAPSHOT_ENABLED" = "1" ]; then
                systemctl --no-ask-password start --no-block "factorio-render@$INSTANCE.service" \
                    || echo "Could not start factorio-render@$INSTANCE (polkit rule missing?)"
            fi
        fi
    fi
done

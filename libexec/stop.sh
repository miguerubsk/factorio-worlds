#!/bin/bash
# ExecStop of factorio@<name>: /quit (saves the game) and waits for it.
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
load_instance "$1" || exit 1

session_alive() { /usr/bin/screen -ls "$SESSION" 2>/dev/null | grep -q "\.${SESSION}[[:space:]]"; }

session_alive || exit 0
/usr/bin/screen -S "$SESSION" -X stuff $'/quit\r'
for _ in $(seq 1 150); do
    session_alive || exit 0
    sleep 1
done
echo "[$INSTANCE] The server did not exit 150 s after /quit; systemd will kill it."

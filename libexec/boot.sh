#!/bin/bash
# factorio.service: at boot, starts the last world chosen.
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
w=$(selected_instance)
[ -n "$w" ] || { echo "No world selected yet."; exit 0; }
instance_exists "$w" || { echo "Selected world '$w' no longer exists."; exit 0; }
exec systemctl start --no-block "$(world_unit "$w")"

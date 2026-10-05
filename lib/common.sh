#!/bin/bash
# factorio-worlds — shared library, sourced by every script.
#
# A world (instance) is a directory $FW_ROOT/<name> containing a .env file.
# $FW_ROOT/common holds what all worlds share (it has a .env too, but it is
# reserved and never treated as a world).
# shellcheck disable=SC2034  # many variables here are consumed by the callers

FW_CONF="${FW_CONF:-/etc/factorio-worlds.conf}"
# System config written by install.sh (root-owned): FW_ROOT, FW_USER, FW_LIBDIR
# shellcheck source=/dev/null
[ -r "$FW_CONF" ] && . "$FW_CONF"

FW_ROOT="${FW_ROOT:-/opt/factorio}"
FW_USER="${FW_USER:-factorio}"
FW_LIBDIR="${FW_LIBDIR:-/usr/local/lib/factorio-worlds}"
FW_COMMON="$FW_ROOT/common"
FW_CACHE="$FW_ROOT/cache"
COMMON_ENV="$FW_COMMON/.env"
ACTIVE_FILE="$FW_COMMON/active"
FW_RESERVED=" common cache backups all "

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Reads KEY=VALUE lines without `source`, so passwords may contain $ % & # * ...
load_env_file() {
    local file="$1" line key val
    [ -r "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ ]] || [[ "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        printf -v "$key" '%s' "$val"
        export "${key?}"
    done < "$file"
}

valid_name()      { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]] && [[ "$FW_RESERVED" != *" $1 "* ]]; }
instance_dir()    { echo "$FW_ROOT/$1"; }
instance_exists() { valid_name "$1" && [ -f "$(instance_dir "$1")/.env" ]; }
world_unit()      { echo "factorio@$1.service"; }

list_instances() {
    local f d
    for f in "$FW_ROOT"/*/.env; do
        [ -f "$f" ] || continue
        d=$(basename "$(dirname "$f")")
        valid_name "$d" && echo "$d"
    done
}

# Loads common/.env and then <world>/.env on top (a world may override any
# common key) and derives every per-world variable.
load_instance() {
    local name="$1"
    instance_exists "$name" || { echo "ERROR: world '$name' does not exist (missing $(instance_dir "$name")/.env)" >&2; return 1; }

    unset DISPLAY_NAME WORLD_NAME SAVE_NAME FACTORIO_BIN RENDER UPDATE \
          USE_WHITELIST EXTRA_ARGS RCON_BIND
    load_env_file "$COMMON_ENV" || { echo "ERROR: cannot read $COMMON_ENV" >&2; return 1; }
    load_env_file "$(instance_dir "$name")/.env"

    INSTANCE="$name"
    INSTANCE_DIR="$(instance_dir "$name")"
    SESSION="fw-$name"
    UNIT="$(world_unit "$name")"
    SAVE_NAME="${SAVE_NAME:-$name}"
    DISPLAY_NAME="${DISPLAY_NAME:-$name}"
    WORLD_NAME="${WORLD_NAME:-$SAVE_NAME}"
    FACTORIO_BIN="${FACTORIO_BIN:-$INSTANCE_DIR/bin/x64/factorio}"
    SAVE_PATH="$INSTANCE_DIR/saves/$SAVE_NAME.zip"
    LOG_FILE="$INSTANCE_DIR/console.log"
    SETTINGS_OVERRIDE="$INSTANCE_DIR/server-settings.override.json"
    SETTINGS_GENERATED="$INSTANCE_DIR/server-settings.generated.json"
    PLAYER_COUNT_FILE="$INSTANCE_DIR/.player_count"
    FLAG_ACTIVITY="$INSTANCE_DIR/.had_activity"
    FLAG_PENDING="$INSTANCE_DIR/.render_pending"
    RENDER_LOCK="$INSTANCE_DIR/.render.lock"
    RENDER="${RENDER:-0}"
    UPDATE="${UPDATE:-1}"
    USE_WHITELIST="${USE_WHITELIST:-0}"
    GAME_PORT="${GAME_PORT:-34197}"
    RCON_PORT="${RCON_PORT:-27015}"
    BACKUP_DIR="${BACKUP_DIR:-$FW_ROOT/backups}"
    MAPSHOT_ENABLED="${MAPSHOT_ENABLED:-0}"
    load_default_messages
}

# ==============================================================================
# STATE
# ==============================================================================

# Worlds whose service is up (normally at most one)
running_instances() {
    systemctl list-units --plain --no-legend --state=active,activating,deactivating,reloading \
        'factorio@*.service' 2>/dev/null \
        | awk '{print $1}' | sed -E 's/^factorio@//; s/\.service$//'
}
running_instance() { running_instances | head -1; }

# Last world chosen (the one started at boot)
selected_instance() { cat "$ACTIVE_FILE" 2>/dev/null; }

factorio_version() {
    local bin="$1"
    [ -x "$bin" ] || { echo "?"; return; }
    "$bin" --version 2>/dev/null | awk '/^Version:/{print $2; exit}'
}

# ==============================================================================
# RCON
# ==============================================================================

# Requires a loaded world. All arguments form ONE command.
rcon_cmd() {
    local host="127.0.0.1"
    [ -n "$RCON_BIND" ] && [ "$RCON_BIND" != "0.0.0.0" ] && host="$RCON_BIND"
    [ -n "$RCON_PORT" ] || return 1
    [ -n "$RCON_PASSWORD" ] || return 1
    # Password through the environment, not argv (visible in ps)
    FW_RCON_PASSWORD="$RCON_PASSWORD" python3 "$FW_LIBDIR/libexec/fw-rcon" "$host" "$RCON_PORT" "$*" 2>/dev/null
}

# Number of players online, -1 when it cannot be queried
players_online() {
    local out n
    out=$(rcon_cmd "/players online") || { echo "-1"; return; }
    [ -z "$out" ] && { echo "-1"; return; }
    n=$(printf '%s' "$out" | grep -oiE "online players \(([0-9]+)\)" | grep -oE "[0-9]+" | head -1)
    [ -z "$n" ] && n=$(printf '%s' "$out" | grep -ciE "\(online\)")
    echo "${n:-0}"
}

# ==============================================================================
# NOTIFICATIONS (Telegram, optional: disabled while TELEGRAM_TOKEN is empty)
# ==============================================================================

# Default texts; any MSG_* in .env overrides them. Telegram HTML formatting.
load_default_messages() {
    [ -n "$MSG_CONNECTING" ] || MSG_CONNECTING='🔌 Someone from <code>{ip}</code> is connecting to <b>{world}</b>...'
    [ -n "$MSG_JOIN" ] || MSG_JOIN='🚀 <b>{player}</b> joined <b>{world}</b>'
    [ -n "$MSG_LEAVE" ] || MSG_LEAVE='💤 <b>{player}</b> left <b>{world}</b>'
    [ -n "$MSG_SWITCH" ] || MSG_SWITCH='🔀 Server switched to <b>{name}</b> ({world})'
    [ -n "$MSG_UPDATE_START" ] || MSG_UPDATE_START='🛠 Updating <b>{name}</b>: v{old} → v{new}...'
    [ -n "$MSG_UPDATE_DONE" ] || MSG_UPDATE_DONE='✅ <b>{name}</b> updated to v{new}'
    [ -n "$MSG_UPDATE_FAIL" ] || MSG_UPDATE_FAIL='❌ Update of <b>{name}</b> to v{new} failed'
    [ -n "$MSG_RENDER_START" ] || MSG_RENDER_START='🗺️ Rendering the map of <b>{world}</b>...'
    [ -n "$MSG_RENDER_DONE" ] || MSG_RENDER_DONE='✅ Map of <b>{world}</b> updated in {time}'
    [ -n "$MSG_RENDER_FAIL" ] || MSG_RENDER_FAIL='❌ Map render of <b>{world}</b> failed'
}

# Replacements are quoted: since bash 5.2 an unquoted & means "the matched text"
html_escape() { local s="${1//&/"&amp;"}"; s="${s//</"&lt;"}"; printf '%s' "${s//>/"&gt;"}"; }

# msg TEMPLATE key value [key value...] -> replaces {key} with the escaped value
msg() {
    local tpl="$1" val; shift
    while [ $# -ge 2 ]; do
        val=$(html_escape "$2")
        tpl="${tpl//"{$1}"/"$val"}"
        shift 2
    done
    printf '%s' "$tpl"
}

notify() {
    local text="$1" cid
    [ -n "$TELEGRAM_TOKEN" ] || return 0
    [ -n "$TELEGRAM_CHAT_IDS" ] || return 0
    for cid in $(printf '%s' "$TELEGRAM_CHAT_IDS" | tr ',"' '  '); do
        curl -s -m 15 -o /dev/null -X POST \
            "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            --data-urlencode chat_id="$cid" \
            --data-urlencode parse_mode="HTML" \
            --data-urlencode text="$text" 2>/dev/null
    done
}

# ==============================================================================
# GAME DOWNLOADS
# ==============================================================================

HEADLESS_URL="https://factorio.com/get-download/%s/headless/linux64"

# Resolves "stable"/"latest" to a version number (prints it)
resolve_version() {
    local v="${1:-stable}"
    if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$v"; return; fi
    # shellcheck disable=SC2059
    curl -sI "$(printf "$HEADLESS_URL" "$v")" | grep -i '^location:' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Downloads the headless tarball once into the cache; prints its path
fetch_headless() {
    local version="$1" file
    file="$FW_CACHE/factorio-headless_${version}.tar.xz"
    if [ ! -s "$file" ]; then
        mkdir -p "$FW_CACHE" || return 1
        # shellcheck disable=SC2059
        if ! curl -fsSL "$(printf "$HEADLESS_URL" "$version")" -o "$file.part"; then
            rm -f "$file.part"; return 1
        fi
        mv "$file.part" "$file"
    fi
    echo "$file"
}

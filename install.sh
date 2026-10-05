#!/bin/bash
# factorio-worlds installer. Run it again to upgrade: config and worlds are kept.
#
#   sudo ./install.sh [--root DIR] [--user NAME] [--render-user NAME]
#                     [--libdir DIR] [--no-alias] [--enable-auto-update]
set -euo pipefail

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CONF=/etc/factorio-worlds.conf
BINDIR=/usr/local/bin
ALIAS=1
AUTO_UPDATE=0

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[ "$EUID" -eq 0 ] || die "run it as root: sudo $0"
[ "${BASH_VERSINFO[0]}" -ge 5 ] || die "bash 5 or newer is required"

# An existing installation keeps its settings unless overridden
FW_ROOT=/opt/factorio; FW_USER=factorio; FW_LIBDIR=/usr/local/lib/factorio-worlds; FW_RENDER_USER=""
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

while [ $# -gt 0 ]; do
    case "$1" in
        --root)               FW_ROOT="$2"; shift ;;
        --user)               FW_USER="$2"; shift ;;
        --render-user)        FW_RENDER_USER="$2"; shift ;;
        --libdir)             FW_LIBDIR="$2"; shift ;;
        --no-alias)           ALIAS=0 ;;
        --enable-auto-update) AUTO_UPDATE=1 ;;
        -h|--help)            sed -n '2,6p' "$0"; exit 0 ;;
        *)                    die "unknown option: $1" ;;
    esac
    shift
done
[[ "$FW_ROOT" == /* && "$FW_LIBDIR" == /* ]] || die "--root and --libdir must be absolute paths"
# The map render runs as the service user unless another one is given (it needs
# write access to the mapshot client and output directories)
FW_RENDER_USER="${FW_RENDER_USER:-$FW_USER}"

step "Checking dependencies"
missing=()
for c in screen jq curl tar xz python3 unzip flock systemctl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing: ${missing[*]}"
    echo "  Debian/Ubuntu: apt install screen jq curl xz-utils python3 unzip util-linux"
    echo "  Fedora:        dnf install screen jq curl xz python3 unzip util-linux"
    echo "  Arch:          pacman -S screen jq curl xz python unzip util-linux"
    exit 1
fi

step "Service user '$FW_USER'"
getent group "$FW_USER" >/dev/null || groupadd --system "$FW_USER"
if ! id "$FW_USER" >/dev/null 2>&1; then
    useradd --system --gid "$FW_USER" --home-dir "$FW_ROOT" --no-create-home \
            --shell "$(command -v nologin || echo /bin/false)" "$FW_USER"
fi
id "$FW_RENDER_USER" >/dev/null 2>&1 || die "render user '$FW_RENDER_USER' does not exist"

step "Data directory $FW_ROOT"
# Group-writable + setgid: members of the group can create worlds
install -d -o root -g "$FW_USER" -m 2775 "$FW_ROOT" "$FW_ROOT/common" "$FW_ROOT/cache" "$FW_ROOT/backups"
C="$FW_ROOT/common"
if [ ! -f "$C/.env" ]; then
    install -o root -g "$FW_USER" -m 660 "$SRC/examples/common.env.example" "$C/.env"
    echo "    Created $C/.env: review it (RCON_PASSWORD has been randomised)"
    pw=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40 || true)
    sed -i "s/^RCON_PASSWORD=.*/RCON_PASSWORD=$pw/" "$C/.env"
fi
for f in server-adminlist.json server-whitelist.json server-banlist.json; do
    [ -f "$C/$f" ] || { echo '[]' > "$C/$f"; chown "$FW_USER:$FW_USER" "$C/$f"; chmod 664 "$C/$f"; }
done
[ -f "$C/active" ] || { : > "$C/active"; chown "$FW_USER:$FW_USER" "$C/active"; chmod 664 "$C/active"; }

step "Code in $FW_LIBDIR"
# Root-owned: root runs update.sh, so the service user must not be able to edit it
rm -rf "$FW_LIBDIR"
install -d -m 755 "$FW_LIBDIR"
cp -r "$SRC/bin" "$SRC/lib" "$SRC/libexec" "$FW_LIBDIR/"
chown -R root:root "$FW_LIBDIR"
chmod -R u=rwX,go=rX "$FW_LIBDIR"
chmod 755 "$FW_LIBDIR"/bin/* "$FW_LIBDIR"/libexec/*

cat > "$CONF" <<EOF
# factorio-worlds system configuration (written by install.sh)
FW_ROOT="$FW_ROOT"
FW_USER="$FW_USER"
FW_LIBDIR="$FW_LIBDIR"
FW_RENDER_USER="$FW_RENDER_USER"
EOF
chmod 644 "$CONF"

ln -sfn "$FW_LIBDIR/bin/factorio-worlds" "$BINDIR/factorio-worlds"
if [ "$ALIAS" = 1 ]; then
    existing=$(command -v factorio 2>/dev/null || true)
    if [ -z "$existing" ] || [ "$(readlink -f "$existing")" = "$FW_LIBDIR/bin/factorio-worlds" ]; then
        ln -sfn "$FW_LIBDIR/bin/factorio-worlds" "$BINDIR/factorio"
        echo "    Command alias: factorio"
    else
        echo "    Not creating the 'factorio' alias: $existing already exists"
    fi
fi

step "systemd units"
subst() {
    sed -e "s#@FW_ROOT@#$FW_ROOT#g" -e "s#@FW_USER@#$FW_USER#g" -e "s#@FW_LIBDIR@#$FW_LIBDIR#g" \
        -e "s#@FW_RENDER_USER@#$FW_RENDER_USER#g" "$1"
}
for f in "$SRC"/systemd/*; do
    name=$(basename "$f" .in)
    subst "$f" > "/etc/systemd/system/$name"
    chmod 644 "/etc/systemd/system/$name"
done
systemctl daemon-reload
systemctl enable factorio.service >/dev/null
systemctl enable --now factorio-render.timer >/dev/null
[ "$AUTO_UPDATE" = 1 ] && systemctl enable --now factorio-update.timer >/dev/null

step "polkit rule"
if [ -d /etc/polkit-1/rules.d ]; then
    subst "$SRC/polkit/50-factorio-worlds.rules.in" > /etc/polkit-1/rules.d/50-factorio-worlds.rules
    chmod 644 /etc/polkit-1/rules.d/50-factorio-worlds.rules
else
    echo "    polkit not found: switching worlds will ask for sudo"
fi

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && ! id -nG "$SUDO_USER" | grep -qw "$FW_USER"; then
    usermod -aG "$FW_USER" "$SUDO_USER"
    echo "    Added $SUDO_USER to the '$FW_USER' group: log out and back in to use it"
fi

cat <<EOF

factorio-worlds is installed.
  Shared settings: $C/.env
  Create a world:  factorio-worlds new myworld --create
  Start it:        factorio-worlds switch myworld
EOF

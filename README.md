# factorio-worlds

Run several Factorio worlds on one headless server and switch between them with
one command. Plain bash + systemd, no Docker, Space Age ready.

```console
$ factorio-worlds
    WORLD          NAME                         VERSION    SAVE                   STATE
●   vanilla        Friday night factory         2.0.77     nauvis                 running · 2 player(s)
    modded         Krastorio weekend            2.0.77     k2                     stopped
    creative       Sandbox                      2.0.77     sandbox                stopped

$ factorio-worlds switch modded
==> Stopping 'vanilla' (saving)...
==> Starting 'modded' (Krastorio weekend)...
Waiting for modded........ ready (9s)
```

It is meant for a group of friends with a home server and more than one map:
one world runs at a time on the usual port, and switching saves the current
one cleanly before starting the next.

## Features

- **Worlds as directories.** Each world is `/opt/factorio/<name>` with its own
  game version, mods and saves. Create one with a new map, an imported save or
  a copy of another world (mods are hard-linked, so they take no extra space).
- **Shared settings.** Ports, RCON, admins, bans, whitelist and server settings
  live once in `/opt/factorio/common`; a world only overrides what differs.
- **Safe switching.** `switch` asks before kicking online players, saves with
  `/quit` and waits for the save to finish before starting the next world.
- **Crash recovery.** After a power cut the newest autosave is promoted to the
  main save (the old one is kept aside).
- **Starts at boot** with the last world you chose.
- **Updates** the headless server of every world, with a backup first.
- **No sudo for daily use.** A polkit rule lets members of the `factorio` group
  start, stop and switch worlds.
- **Optional modules:** Telegram notifications (joins, leaves, switches,
  updates) and daily map renders with [mapshot](https://github.com/Palats/mapshot)
  that only run when someone played and nobody is online.

## Requirements

- Linux with systemd (tested on Debian 13)
- bash 5+, screen, jq, curl, xz, python3, unzip, flock
- polkit (optional, to avoid sudo when switching)

## Install

```sh
git clone https://github.com/miguerubsk/factorio-worlds.git
cd factorio-worlds
sudo ./install.sh
```

The installer creates the `factorio` system user and group, `/opt/factorio`,
the systemd units and the polkit rule, and adds you to the `factorio` group
(log out and back in afterwards). Options: `--root DIR`, `--user NAME`,
`--render-user NAME` (user that runs mapshot), `--libdir DIR`, `--no-alias`,
`--enable-auto-update`. Run it again to upgrade;
your worlds and settings are kept.

Then:

```sh
sudoedit /opt/factorio/common/.env              # review the shared settings
factorio-worlds new nauvis --create --name "My server"
factorio-worlds switch nauvis
```

## Commands

| Command | What it does |
| --- | --- |
| `factorio-worlds` / `status` | Every world: running or not, version, save, players |
| `list` | World names |
| `switch <world> [-f]` | Save and stop the running world, start another one |
| `start [world]` / `stop` / `restart` | Control the running world |
| `attach` | Server console (detach with Ctrl+A, D) |
| `logs [-f] [world]` | Console log |
| `cmd <command>` / `players` | RCON command / players online |
| `update [world\|all]` | Update the headless server (sudo) |
| `new <world> [options]` | Create a world (see below) |
| `remove <world>` | Delete a stopped world, backing up its save first |

`factorio` is installed as a short alias unless that command already exists.

### Creating worlds

```sh
factorio-worlds new nauvis --create                      # new map, latest stable server
factorio-worlds new old --save ~/old-world.zip           # import a save
factorio-worlds new k2 --from vanilla --save k2.zip      # copy game and mods from a world
factorio-worlds new classic --no-space-age --create      # base game only
factorio-worlds new custom --create --map-gen mg.json --version 2.0.76
```

Downloads are cached in `/opt/factorio/cache`.

## Configuration

```
/opt/factorio/
├── common/
│   ├── .env                        shared settings and secrets
│   ├── server-settings.base.json   created from the game's example on first start
│   ├── server-adminlist.json  server-banlist.json  server-whitelist.json
│   └── active                      world started at boot
├── <world>/
│   ├── .env                        this world's settings
│   ├── server-settings.override.json   optional, only the keys that differ
│   └── bin/ data/ mods/ saves/ console.log
├── cache/                          downloaded server tarballs
└── backups/
```

- `common/.env`: see [`examples/common.env.example`](examples/common.env.example).
- `<world>/.env`: see [`examples/world.env.example`](examples/world.env.example).
  Any common key can be overridden per world.
- Server settings are generated on every start as
  `base * override * {"name": DISPLAY_NAME}`; edit the base or the override,
  never the generated file.

Notification texts are templates (`MSG_JOIN`, `MSG_LEAVE`, ...) you can
translate in `common/.env`.

## How it works

| Unit | Role |
| --- | --- |
| `factorio@<world>` | The server, inside `screen` (session `fw-<world>`) |
| `factorio-notifier@<world>` | Follows the console log: notifications, player count, activity. Starts and stops with its world |
| `factorio.service` | At boot, starts the last world chosen |
| `factorio-render.timer` | Daily map render of the worlds with `RENDER=1` |
| `factorio-render@<world>` | Pending render, run when the last player leaves |
| `factorio-update.timer` | Daily update check (disabled unless `--enable-auto-update`) |

Starting a world runs `prestart.sh` (refuses if another world is running, crash
recovery, settings generation), then `launch.sh`. Stopping runs `stop.sh`, which
sends `/quit` and waits up to 150 s for the save. The code lives in
`/usr/local/lib/factorio-worlds` and is owned by root.

## Uninstall

```sh
sudo ./uninstall.sh            # keeps /opt/factorio
sudo ./uninstall.sh --purge    # deletes every world too
```

## Why another tool?

Other options exist, but none fits "a few worlds, switch between them, no
Docker" today: [factorio-init](https://github.com/Bisa/factorio-init) and
[Factorio Server Manager](https://github.com/OpenFactorioServerManager/factorio-server-manager)
have not been updated since before Space Age,
[factorio-docker](https://github.com/factoriotools/factorio-docker) needs
Docker, and [Clusterio](https://github.com/clusterio/clusterio) solves a much
bigger problem.

## Roadmap

Planned work is tracked in
[milestones](https://github.com/miguerubsk/factorio-worlds/milestones):

- **0.1.1 Fixes:** testing on a real systemd + polkit machine, per-command help
- **0.2.0 Map creation:** seed, map generation preset, scenario, per-world map
  generation files, map preview
- **0.3.0 Saves:** list, back up and restore saves, bash completion
- **0.4.0 Mods:** download and update mods from the mod portal
- **1.0.0 Stable:** automated tests, more distributions, translatable
  messages, several worlds at once

## License

[MIT](LICENSE)

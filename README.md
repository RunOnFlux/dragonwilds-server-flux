# dragonwilds-server-flux

The RuneScape: Dragonwilds dedicated server image for [Flux](https://runonflux.io/):
`runonflux/dragonwilds-server-flux`.

It is a thin layer on the community image the marketplace has always deployed
(`indifferentbroccoli/runescape-dragonwilds-server-docker`), pinned **by digest**, with its own
PID 1 that supervises the game instead of becoming it.

## Credit and licence

The game launcher inside this image (installing with DepotDownloader, writing `DedicatedServer.ini`,
the healthcheck) is the work of [indifferentbroccoli](https://github.com/indifferentbroccoli/runescape-dragonwilds-server-docker),
published under the GNU GPL v3. This repository adds the supervisor, and the image start-up banner
and image labels are ours, so logs and `docker inspect` name this image and not the launcher's
author. The attribution stays here, in the README. The repository is licensed under the GNU GPL v3 (see
`LICENSE`), the same licence as the launcher it builds on.

## Why a layer and not a rewrite

The upstream image is maintained, installs the game with DepotDownloader and already fixes the
problems that used to make us want our own (values with quotes, the SIGTERM pid bug, a persistent
`ServerGuid`). What it cannot do is look after a running server. The digest is pinned because
upstream publishes `:latest` from a moving branch, and a server that restarts in place must not
change its launcher under a customer. Bump the digest on purpose, after reading the diff.

## What it adds

| | Upstream | This image |
|---|---|---|
| Scheduled restart | None | `FLUX_RESTART_TIME`, in place, after the next autosave |
| New public build | Picked up only on a manual restart | Polled from Steam, restart after the next autosave |
| Hung or unregistered server | Runs on, invisible in search | Watchdog restarts the game in place |
| Game crash | The container ends | Restarted in place, container ends only after 5 in an hour (exit 42) |

Everything the hub reads is unchanged: the volume `/home/steam/server-files`, `PUID`/`PGID`,
`DedicatedServer.ini` written from the same variables, the log
`RSDragonwilds/Saved/Logs/RSDragonwilds.log`, the process `RSDragonwildsServer-Linux-Shipping`,
the world `Saved/SaveGames/<DEFAULT_WORLD_NAME>.sav`, the healthcheck.

## Configuration

Every upstream variable keeps its name and default: `PUID`, `PGID`, `UPDATE_ON_START`, `OWNER_ID`,
`SERVER_NAME`, `DEFAULT_WORLD_NAME`, `ADMIN_PASSWORD`, `WORLD_PASSWORD`, `DEFAULT_PORT`,
`BEACON_PORT`, `MAX_PLAYERS`, `PLATFORM_POLICY`, `MULTIHOME`.

New, and the only ones a marketplace spec needs to declare (FluxOS allows 20 per app):

| Variable | Default | |
|---|---|---|
| `FLUX_RESTART_TIME` | empty (off) | Daily restart, `HH:MM`, 24 hour, in `TZ`. Also when the server takes a patch |
| `FLUX_WATCHDOG` | `true` | Restart the game in place when its world is not registered, or its log goes silent |
| `TZ` | `UTC` | Timezone of `FLUX_RESTART_TIME` |

Tuning that is not meant for a spec (tests shorten these): `FLUX_START_TIMEOUT`,
`FLUX_SILENCE_TIMEOUT`, `FLUX_BUILD_POLL`, `FLUX_AUTOSAVE_WAIT`, `FLUX_STOP_GRACE`,
`FLUX_RESTART_GRACE`, `FLUX_RESTART_MAX`, `FLUX_RESTART_WINDOW`, `FLUX_TICK`.

## Measured behaviour

Taken on a live server, 2026-11-08, build manifest 1991230221118269239.

- **`docker stop`**: SIGTERM ends the game cleanly in about 2 s (exit 143), well inside the 10 s
  Flux allows. The game logs `BeginWorldTeardown: Draining save requests`, which flushes saves
  already queued, but it does **not** write a new save: no `Save to slot` line and the `.sav`
  file keeps its old time. Whatever was played since the last autosave is lost on every stop.
  That is why scheduled and patch restarts wait for an autosave first.
- **Healthy log**: an EOS `Heartbeat` request is logged every 30 s, so a live server never goes
  more than about 30 s without a line. A silent log is therefore a hung process, and the watchdog gives it 300 s (ten missed heartbeats).
- **World registration**: `LogDomMatcherSession: START SESSION - Success` appears about 8 s after
  launch on a warm start.
- **Patch poll**: `DepotDownloader -app 4019830 -os linux -manifest-only -dir <empty temp dir>`
  answers anonymously in about 3 s, prints the public manifest id, and touches nothing in the
  install. The installed id is the name of `.DepotDownloader/<depot>_<manifest>.manifest`.

## Versions

- 1.0.1: start-up banner and image labels name FluxCloud instead of the launcher author; credit moved to the README.
- 1.0.2: bans and admin rights survive a restart. The ini is still rebuilt from the environment at every start, but the lines the game keeps in its settings section (`KnownPlayerList`, which holds who is admin and who is banned, plus anything added by hand) are read first and written back. Upstream drops them.
- 1.0.0: first version.

## Tests

```bash
./tests/test-flux.sh             # decisions in scripts/flux-lib.sh, no Docker
docker build -t dragonwilds-server-flux:local .
./tests/test-image.sh            # boots the image against a volume that already holds the game
```

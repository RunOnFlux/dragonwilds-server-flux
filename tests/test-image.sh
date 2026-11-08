#!/bin/bash
# Live boot tests of the built image. Needs Docker and a COPY of a volume that already holds the
# game (DW_VOLUME), so no test downloads 3.6 GB. Build first:
#   docker build -t dragonwilds-server-flux:local .
#   DW_VOLUME=/path/to/server-files ./tests/test-image.sh
# Each case copies the volume, so the original is never touched.
set -uo pipefail
IMG="${IMG:-dragonwilds-server-flux:local}"
: "${DW_VOLUME:?set DW_VOLUME to a server-files folder that holds the installed game}"
work="$(mktemp -d)"
trap 'docker rm -f dwt-case >/dev/null 2>&1; rm -rf "${work}"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
run() { # extra docker args...
  docker rm -f dwt-case >/dev/null 2>&1
  rm -rf "${work}/v"; cp -r "${DW_VOLUME}" "${work}/v"
  docker run -d --name dwt-case -e PUID="$(id -u)" -e PGID="$(id -g)" -e UPDATE_ON_START=false \
    -e DEFAULT_PORT=27777 -e OWNER_ID=owner1 -e ADMIN_PASSWORD=adm -e FLUX_TICK=2 \
    -v "${work}/v:/home/steam/server-files" "$@" "${IMG}" >/dev/null
}
waitlog() { # pattern, seconds
  local i; for ((i = 0; i < $2; i++)); do docker logs dwt-case 2>&1 | grep -aq "$1" && return 0; sleep 1; done; return 1
}

# 1. Values with an apostrophe and spaces reach the ini and the world registers.
run -e SERVER_NAME="Mac's Server" -e DEFAULT_WORLD_NAME="Mac's World"
if waitlog "START SESSION - Success" 120; then ok "world registers with apostrophes in the values"; else bad "world did not register"; fi
grep -q "^ServerName=Mac's Server" "${work}/v/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini" && ok "ini keeps the apostrophe" || bad "ini lost the apostrophe"
[ -f "${work}/v/RSDragonwilds/Saved/SaveGames/Mac's World.sav" ] && ok "world file is <DEFAULT_WORLD_NAME>.sav" || bad "world file name"

# 2. docker stop ends inside Flux's 10 s with exit 0.
s=$(date +%s); docker stop -t 10 dwt-case >/dev/null; e=$(date +%s)
[ $((e - s)) -lt 10 ] && [ "$(docker inspect dwt-case --format '{{.State.ExitCode}}')" = 0 ] && ok "docker stop is clean and fast ($((e - s))s)" || bad "docker stop"

# 3. A world that never registers is restarted in place, then the container gives up (exit 42).
run -e SERVER_NAME=s -e DEFAULT_WORLD_NAME=W -e FLUX_START_TIMEOUT=3 -e FLUX_RESTART_MAX=2
for ((i = 0; i < 90; i++)); do [ "$(docker inspect dwt-case --format '{{.State.Running}}')" = false ] && break; sleep 2; done
[ "$(docker inspect dwt-case --format '{{.State.ExitCode}}')" = 42 ] && ok "start watchdog restarts, then exits 42" || bad "restart cap"

# 4. A missing OWNER_ID is refused with a message.
docker rm -f dwt-case >/dev/null 2>&1
rm -rf "${work}/v"; cp -r "${DW_VOLUME}" "${work}/v"
docker run -d --name dwt-case -e PUID="$(id -u)" -e PGID="$(id -g)" -e UPDATE_ON_START=false -v "${work}/v:/home/steam/server-files" "${IMG}" >/dev/null
waitlog "OWNER_ID is not set" 30 && ok "missing OWNER_ID is explained" || bad "missing OWNER_ID"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]

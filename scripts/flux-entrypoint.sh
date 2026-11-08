#!/bin/bash
# PID 1 of the Dragonwilds image. It supervises the game instead of becoming it, so a stop, a
# schedule, a patch or a hang is handled INSIDE the container and the container itself stays up.
#
# Everything the hub depends on is the upstream image's layout, kept as it is: the volume at
# /home/steam/server-files, PUID/PGID, DedicatedServer.ini written from the same variables, the
# game launched by upstream's own start.sh, the log at Saved/Logs/RSDragonwilds.log.
#
# Per generation: update (when UPDATE_ON_START=true), ini, launch, then watch. A generation ends on
# a schedule (FLUX_RESTART_TIME), a new public build, a hang (FLUX_WATCHDOG) or a crash. The first
# two wait for the next autosave so almost nothing is lost.

export UE4SS_ENABLED=false # the Windows/Wine build is upstream's :ue4ss tag, not this image

# shellcheck source=/dev/null
source /home/steam/server/functions.sh # upstream: Log*, install, server_pid
# shellcheck source=scripts/flux-lib.sh
source "${FLUX_LIB:-/home/steam/flux/flux-lib.sh}"

# Tunables that are not part of the marketplace spec (tests shorten them; the defaults are measured,
# see the README).
TICK="${FLUX_TICK:-5}"
START_TIMEOUT="${FLUX_START_TIMEOUT:-600}"
SILENCE_TIMEOUT="${FLUX_SILENCE_TIMEOUT:-300}"
BUILD_POLL="${FLUX_BUILD_POLL:-1800}"
AUTOSAVE_WAIT="${FLUX_AUTOSAVE_WAIT:-420}"
STOP_GRACE="${FLUX_STOP_GRACE:-8}"           # docker stop: Flux allows 10 s in total
RESTART_GRACE="${FLUX_RESTART_GRACE:-25}"    # in-place restarts have no docker deadline
RESTART_MAX="${FLUX_RESTART_MAX:-5}"
RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"

STOPPING=0
LAUNCH_PID=""
RESTARTS=()

on_term() { STOPPING=1; }
trap on_term SIGTERM SIGINT

# Interruptible sleep: a SIGTERM wakes it at once.
nap() { sleep "$1" & wait $! 2>/dev/null; }

prepare_user() {
  if [ -z "${PUID}" ] || [ -z "${PGID}" ]; then
    flux_log "PUID and PGID are not set. Set them in the environment."
    exit 1
  fi
  usermod -o -u "${PUID}" steam
  groupmod -o -g "${PGID}" steam
  find /home/steam \( ! -user steam -o ! -group steam \) -exec chown -h steam:steam {} +
}

write_config() {
  local root="${FLUX_SERVER_FILES}/RSDragonwilds/Saved/Config"
  local dir="${root}/${SERVER_PLATFORM}" file
  file="${dir}/DedicatedServer.ini"
  mkdir -p "${dir}"
  # Keep the GUID across restarts and when the platform folder changes.
  SERVER_GUID=$(sed -n 's/^ServerGuid=\([0-9A-Fa-f]\+\).*/\1/p' "${file}" "${root}/${OTHER_SERVER_PLATFORM}/DedicatedServer.ini" 2>/dev/null | head -n1)
  export SERVER_GUID
  flux_log "Writing DedicatedServer.ini"
  envsubst >"${file}" <<'TEMPLATE'
[SectionsToSave]
bCanSaveAllSections=true

[/Script/Dominion.DedicatedServerSettings]
AdminPassword=${ADMIN_PASSWORD}
OwnerId=${OWNER_ID}
WorldPassword=${WORLD_PASSWORD}
ServerName=${SERVER_NAME}
DefaultWorldName=${DEFAULT_WORLD_NAME}
PlatformPolicy=${PLATFORM_POLICY}
ServerGuid=${SERVER_GUID}
TEMPLATE
  chown -R steam:steam "${FLUX_SERVER_FILES}"
}

# Stops the game and waits up to $1 seconds, then kills it.
stop_game() {
  local pid i
  pid="$(server_pid)"
  [ -n "${pid}" ] || return 0
  flux_log "Stopping the game (SIGTERM, up to ${1}s)"
  kill -TERM "${pid}" 2>/dev/null
  for ((i = 0; i < $1; i++)); do
    kill -0 "${pid}" 2>/dev/null || { flux_log "Game stopped after ${i}s"; return 0; }
    sleep 1
  done
  flux_log "Game did not stop in ${1}s, killing it"
  kill -KILL "${pid}" 2>/dev/null
}

# Asks Steam for the public manifest without downloading anything: a throwaway -dir, 3 s.
public_manifest() {
  local tmp out
  tmp="$(mktemp -d)"
  if [ -n "${FLUX_MANIFEST_CMD:-}" ]; then # test hook: a command that prints DepotDownloader's line
    out="$(sh -c "${FLUX_MANIFEST_CMD}" 2>&1)"
  else
    out="$(timeout 90 /depotdownloader/DepotDownloader -app "${FLUX_STEAM_APP}" -os linux -manifest-only -dir "${tmp}" 2>&1)"
  fi
  rm -rf "${tmp}"
  printf '%s\n' "${out}" | flux_parse_manifest
}

# One generation. Returns the reason it ended in $REASON.
run_generation() {
  local launched now i seen_session=0 pending="" pending_deadline=0 pending_offset=0
  local due="" next_poll installed

  if flux_is_on "${UPDATE_ON_START}" true; then
    install
  else
    flux_log "UPDATE_ON_START is not true, skipping the game update"
  fi
  installed="$(flux_installed_manifest "${FLUX_DEPOT_META}")"

  chmod +x "${FLUX_SERVER_FILES}/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping" 2>/dev/null || true
  chmod +x "${FLUX_SERVER_FILES}/RSDragonwilds/Plugins/Developer/Sentry/Binaries/Linux/crashpad_handler" 2>/dev/null || true

  if [ -z "${OWNER_ID}" ]; then
    flux_log "OWNER_ID is not set. The server cannot start without your RuneScape: DragonWilds Player ID."
    exit 1
  fi
  write_config

  su -m steam -c "cd /home/steam/server && ./start.sh" &
  LAUNCH_PID=$!
  launched="$(date +%s)"
  for ((i = 0; i < 30; i++)); do [ -n "$(server_pid)" ] && break; sleep 1; done
  flux_log "Game launched (build manifest ${installed:-unknown})"

  if [ -n "${FLUX_RESTART_TIME}" ]; then
    if due="$(flux_next_restart_epoch "${FLUX_RESTART_TIME}")"; then
      flux_log "Scheduled restart ${FLUX_RESTART_TIME} ${TZ}, next at $(date -d "@${due}" '+%Y-%m-%d %H:%M:%S %Z')"
    else
      flux_log "FLUX_RESTART_TIME '${FLUX_RESTART_TIME}' is not HH:MM, the schedule is off"
      due=""
    fi
  fi
  next_poll=$((launched + BUILD_POLL))

  while true; do
    nap "${TICK}"
    now="$(date +%s)"
    if [ "${STOPPING}" = 1 ]; then REASON=stop; return; fi
    if [ -z "$(server_pid)" ]; then
      wait "${LAUNCH_PID}" 2>/dev/null
      flux_log "The game exited on its own (code $?)"
      REASON=crash; return
    fi

    if [ -z "${pending}" ]; then
      if [ -n "${due}" ] && [ "${now}" -ge "${due}" ]; then
        pending=schedule
      elif flux_is_on "${UPDATE_ON_START}" true && [ -n "${installed}" ] && [ "${now}" -ge "${next_poll}" ]; then
        local latest
        latest="$(public_manifest)"
        next_poll=$((now + BUILD_POLL))
        if [ -n "${latest}" ] && [ "${latest}" != "${installed}" ]; then
          flux_log "Steam has a new public build (${latest}, installed ${installed})"
          pending=update
        fi
      fi
      if [ -n "${pending}" ]; then
        pending_offset="$(flux_log_lines "${FLUX_GAME_LOG}")"
        pending_deadline=$((now + AUTOSAVE_WAIT))
        flux_log "Restart for ${pending} is due, waiting for the next autosave (at most ${AUTOSAVE_WAIT}s)"
      fi
    fi

    if [ -n "${pending}" ]; then
      if flux_autosave_after "${FLUX_GAME_LOG}" "${pending_offset}"; then
        flux_log "Autosave finished, restarting for ${pending}"
        REASON="${pending}"; return
      elif [ "${now}" -ge "${pending_deadline}" ]; then
        flux_log "No autosave seen in ${AUTOSAVE_WAIT}s, restarting for ${pending} anyway"
        REASON="${pending}"; return
      fi
    fi

    if flux_is_on "${FLUX_WATCHDOG}" true; then
      if [ "${seen_session}" = 0 ]; then
        if flux_session_up "${FLUX_GAME_LOG}"; then
          seen_session=1
        elif [ $((now - launched)) -gt "${START_TIMEOUT}" ]; then
          flux_log "Watchdog: the world was not registered within ${START_TIMEOUT}s"
          REASON=watchdog-start; return
        fi
      elif [ $((now - launched)) -gt "${SILENCE_TIMEOUT}" ] && [ "$(flux_file_age "${FLUX_GAME_LOG}")" -gt "${SILENCE_TIMEOUT}" ]; then
        flux_log "Watchdog: the game log has been silent for over ${SILENCE_TIMEOUT}s"
        REASON=watchdog-silent; return
      fi
    fi
  done
}

flux_log "dragonwilds-server-flux ${FLUX_IMAGE_VERSION:-dev}"
cat /branding 2>/dev/null
prepare_user

while true; do
  REASON=""
  run_generation
  case "${REASON}" in
    stop)
      stop_game "${STOP_GRACE}"
      flux_log "Container stopping"
      exit 0
      ;;
    crash) ;;
    # A hung or unregistered game will not save anything: do not wait for it.
    watchdog-*) stop_game 3 ;;
    *) stop_game "${RESTART_GRACE}" ;;
  esac
  now="$(date +%s)"
  if ! flux_restart_budget_ok "${RESTART_MAX}" "${RESTART_WINDOW}" "${now}" "${RESTARTS[@]}"; then
    flux_log "More than ${RESTART_MAX} in-place restarts in ${RESTART_WINDOW}s, giving up so Flux sees the failure"
    exit 42
  fi
  RESTARTS+=("${now}")
  flux_log "Restarting in place (reason: ${REASON})"
done

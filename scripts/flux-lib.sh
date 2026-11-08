#!/bin/bash
# Shared helpers for the Dragonwilds image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it and calls the
# functions with made-up inputs. Anything that decides something takes its inputs as arguments.

FLUX_SERVER_FILES="${FLUX_SERVER_FILES:-/home/steam/server-files}"
FLUX_GAME_LOG="${FLUX_GAME_LOG:-${FLUX_SERVER_FILES}/RSDragonwilds/Saved/Logs/RSDragonwilds.log}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-4019830}"
FLUX_DEPOT_META="${FLUX_DEPOT_META:-${FLUX_SERVER_FILES}/.DepotDownloader}"

flux_log() {
  printf '%s [flux] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# "true"/"1"/"yes" (any case) is on, everything else off. $1 = value, $2 = default when empty.
flux_is_on() {
  local v="${1:-$2}"
  case "${v,,}" in true | 1 | yes | on) return 0 ;; *) return 1 ;; esac
}

# HH:MM (24 hour, a leading zero optional) to minute of day. Fails on anything else.
flux_restart_minute_of_day() {
  local h m
  [[ "$1" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  [ "$h" -le 23 ] && [ "$m" -le 59 ] || return 1
  echo $((h * 60 + m))
}

# The next epoch second at which HH:MM happens in TZ, strictly after $2 (default now).
flux_next_restart_epoch() {
  local min h m now cand
  min="$(flux_restart_minute_of_day "$1")" || return 1
  h=$((min / 60))
  m=$((min % 60))
  now="${2:-$(date +%s)}"
  cand="$(date -d "@${now} " +%Y-%m-%d)" || return 1
  cand="$(date -d "${cand} $(printf '%02d:%02d' "$h" "$m")" +%s)" || return 1
  if [ "$cand" -le "$now" ]; then
    cand="$(date -d "@$((cand + 90000))" +%Y-%m-%d)"
    cand="$(date -d "${cand} $(printf '%02d:%02d' "$h" "$m")" +%s)"
  fi
  echo "$cand"
}

# The manifest id DepotDownloader printed ("... manifest 1991230221118269239, result: ..."), read
# from its output on stdin. Empty when there is none.
flux_parse_manifest() {
  sed -n 's/.*from app [0-9]*, manifest \([0-9]\{6,\}\), result.*/\1/p' | tail -n 1
}

# The manifest id installed under $1 (the .DepotDownloader folder): the name of its
# <depot>_<manifest>.manifest file. Empty when the game has not been installed.
flux_installed_manifest() {
  local f
  f="$(ls -t "$1"/*_*.manifest 2>/dev/null | head -n 1)" || return 0
  [ -n "$f" ] || return 0
  f="${f##*/}"
  f="${f#*_}"
  echo "${f%.manifest}"
}

# Number of lines in a file (0 when missing).
flux_log_lines() {
  wc -l <"$1" 2>/dev/null || echo 0
}

# 0 when the game log has a finished autosave after line $2. The line is the game's own:
#   LogSpudSubsystem: Save to slot <world>: Success
flux_autosave_after() {
  tail -n +"$(($2 + 1))" "$1" 2>/dev/null | grep -aq 'LogSpudSubsystem: Save to slot .*: Success'
}

# 0 when the world is registered (the server's own statement that players can find it).
flux_session_up() {
  grep -aq 'LogDomMatcherSession: START SESSION - Success' "$1" 2>/dev/null
}

# Seconds since the file was last written; a large number when it is missing.
flux_file_age() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)" || { echo 999999; return; }
  echo $(($(date +%s) - m))
}

# In-place restart budget. $1 = max, $2 = window seconds, $3 = now, rest = past restart epochs.
# Exit 0 when one more restart is allowed.
flux_restart_budget_ok() {
  local max="$1" win="$2" now="$3" n=0 t
  shift 3
  for t in "$@"; do
    [ $((now - t)) -lt "$win" ] && n=$((n + 1))
  done
  [ "$n" -lt "$max" ]
}

#!/bin/bash
# Unit tests for the decisions in scripts/flux-lib.sh. No Docker, no Steam, no game.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source scripts/flux-lib.sh

pass=0; fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT

check "05:00 is minute 300" 300 "$(flux_restart_minute_of_day 05:00)"
check "5:07 is minute 307" 307 "$(flux_restart_minute_of_day 5:07)"
check "23:59 is the last minute" 1439 "$(flux_restart_minute_of_day 23:59)"
check "24:00 is refused" 1 "$(status flux_restart_minute_of_day 24:00)"
check "12:60 is refused" 1 "$(status flux_restart_minute_of_day 12:60)"
check "text is refused" 1 "$(status flux_restart_minute_of_day soon)"
check "empty is refused" 1 "$(status flux_restart_minute_of_day '')"

export TZ=UTC
now="$(date -u -d '2026-11-08 10:00:00' +%s)"
check "later today" "$(date -u -d '2026-11-08 12:30:00' +%s)" "$(flux_next_restart_epoch 12:30 "${now}")"
check "already past today means tomorrow" "$(date -u -d '2026-11-09 05:00:00' +%s)" "$(flux_next_restart_epoch 05:00 "${now}")"
check "exactly now means tomorrow" "$(date -u -d '2026-11-09 10:00:00' +%s)" "$(flux_next_restart_epoch 10:00 "${now}")"
export TZ=Europe/Lisbon
check "the zone decides the day (Lisbon winter = UTC)" "$(date -u -d '2026-11-09 05:00:00' +%s)" "$(flux_next_restart_epoch 05:00 "${now}")"
export TZ=America/New_York
check "New York 05:00 is 10:00 UTC, so tomorrow when it is already 10:00" "$(date -u -d '2026-11-09 10:00:00' +%s)" "$(flux_next_restart_epoch 05:00 "${now}")"
export TZ=UTC

out='Got manifest request code for depot 3501791 from app 4019830, manifest 1991230221118269239, result: 3720901489978965837'
check "manifest from DepotDownloader output" 1991230221118269239 "$(printf 'x\n%s\ny\n' "${out}" | flux_parse_manifest)"
check "no manifest line" "" "$(printf 'nothing\n' | flux_parse_manifest)"

mkdir -p "${tmp}/dd"
check "no install yet" "" "$(flux_installed_manifest "${tmp}/dd")"
touch "${tmp}/dd/3501791_1991230221118269239.manifest" "${tmp}/dd/3501791_1991230221118269239.manifest.sha"
check "installed manifest from the file name" 1991230221118269239 "$(flux_installed_manifest "${tmp}/dd")"

log="${tmp}/game.log"
printf 'a\nLogSpudSubsystem: Save to slot W: Success\nb\n' >"${log}"
check "an autosave before the offset does not count" 1 "$(status flux_autosave_after "${log}" 3)"
printf 'c\nLogSpudSubsystem: Save to slot My World: Success\n' >>"${log}"
check "an autosave after the offset counts" 0 "$(status flux_autosave_after "${log}" 3)"
check "a failed save does not count" 1 "$(printf 'LogSpudSubsystem: Save to slot W: Failed\n' >"${log}"; status flux_autosave_after "${log}" 0)"
check "missing log is not an autosave" 1 "$(status flux_autosave_after "${tmp}/none" 0)"

check "session not up" 1 "$(printf 'LogDomMatcherSession: START SESSION - \n' >"${log}"; status flux_session_up "${log}")"
check "session up" 0 "$(printf 'LogDomMatcherSession: START SESSION - Success\n' >"${log}"; status flux_session_up "${log}")"
check "age of a fresh file" 0 "$(touch "${log}"; flux_file_age "${log}")"
check "age of a missing file is large" 999999 "$(flux_file_age "${tmp}/none")"

check "budget: none yet" 0 "$(status flux_restart_budget_ok 5 3600 1000)"
check "budget: 4 recent, 1 left" 0 "$(status flux_restart_budget_ok 5 3600 5000 4000 4100 4200 4300)"
check "budget: 5 recent, none left" 1 "$(status flux_restart_budget_ok 5 3600 5000 4000 4100 4200 4300 4400)"
check "budget: old ones fall out of the window" 0 "$(status flux_restart_budget_ok 5 3600 9000 4000 4100 4200 4300 4400)"

check "flux_is_on true" 0 "$(status flux_is_on TRUE)"
check "flux_is_on false" 1 "$(status flux_is_on false)"
check "flux_is_on default" 0 "$(status flux_is_on '' true)"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]

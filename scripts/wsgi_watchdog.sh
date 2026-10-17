#!/usr/bin/env bash
# wsgi_watchdog.sh — two-layer saturation watchdog for panda-compose panda-server.
#
# WHY: the dev stack's upload_cache_file handler makes an HTTP self-call
# (register_cache_file) back into the same httpd/WSGI pool it occupies.
# When the pool is saturated the self-call queues behind itself and the
# whole server wedges silently for TimeOut=600s (AH03490 -> WSGI0145).
# is_alive (app layer) and /cache (static) starve together with it, so a
# naive "is the server up" check cannot tell you WHY.
#
# This watchdog probes the two layers independently, OUT-OF-BAND (docker
# exec — no httpd involvement, works during a full wedge):
#   layer 1  MPM      GET /server-status?auto   (served by the MPM, no WSGI)
#   layer 2  app      GET /api/v1/system/is_alive  (served by WSGI daemon)
# and classifies:
#   HEALTHY            both fast
#   WSGI_SATURATED     MPM fine, app slow/dead  -> daemon pool exhausted
#   FULL_WEDGE         both dead                -> scoreboard full (AH03490)
#   HTTPD_DOWN         server-status refuses connections
#
# Usage:  wsgi_watchdog.sh [-i interval] [-n max_loops] [-c container]
#         -i seconds between polls (default 10)
#         -n stop after N loops (default: forever)
#         -c container name (default panda-compose-panda-server-1)
# Exit code (single-shot mode -n1): 0 healthy, 2 saturated, 3 wedge, 4 down.

set -u
CONTAINER="panda-compose-panda-server-1"
INTERVAL=10
MAX_LOOPS=0
while getopts "i:n:c:" o; do
  case $o in
    i) INTERVAL=$OPTARG ;;
    n) MAX_LOOPS=$OPTARG ;;
    c) CONTAINER=$OPTARG ;;
    *) echo "usage: $0 [-i sec] [-n loops] [-c container]" >&2; exit 64 ;;
  esac
done

LOGDIR=${WSGI_WATCHDOG_LOGDIR:-/tmp/wsgi_watchdog}
LOG=$LOGDIR/events.log
STATE=$LOGDIR/state
mkdir -p "$LOGDIR"

probe() {  # probe <url> -> "code latency curlexit" ; latency=-1 on no response
  local url=$1 out code lat rc
  out=$(docker exec "$CONTAINER" curl -s -m "$PROBE_TIMEOUT" -o /dev/null \
        -w '%{http_code} %{time_total}' "$url" 2>/dev/null); rc=$?
  read -r code lat <<< "$out"
  # curl exit 7 = connection refused (httpd down), 28 = connected but timed
  # out (wedged). Both report http_code 000; the exit code tells them apart.
  [ "$code" = "000" ] && [ "$rc" != "7" ] && lat="wedge"
  echo "$code $lat $rc"
}

PROBE_TIMEOUT=3
MPM_URL="http://localhost:80/server-status?auto"
APP_URL="http://localhost:80/api/v1/system/is_alive"
prev=""
loop=0
while :; do
  loop=$((loop+1))
  ts=$(date -u +%FT%TZ)
  read -r mpm_code mpm_t _ <<< "$(probe "$MPM_URL")"
  read -r app_code app_t _ <<< "$(probe "$APP_URL")"

  if [ "$mpm_code" = "000" ] && [ "$mpm_t" = "-1" ]; then
    verdict=HTTPD_DOWN; rc=4
  elif { [ "$app_code" = "000" ] || [ "$app_t" = "wedge" ]; } && { [ "$mpm_code" = "000" ] || [ "$mpm_t" = "wedge" ]; }; then
    verdict=FULL_WEDGE; rc=3
  elif [ "$app_code" = "000" ] || [ "$app_t" = "wedge" ]; then
    verdict=WSGI_SATURATED; rc=2
  elif [ "$mpm_code" = "000" ] || [ "$mpm_t" = "wedge" ]; then
    verdict=MPM_SLOW; rc=2
  else
    verdict=HEALTHY; rc=0
  fi

  # enrich with worker counts (cheap; server-status is alive)
  extra=""
  if [ "$verdict" = "WSGI_SATURATED" ] || [ "$verdict" = "HEALTHY" ]; then
    ss=$(docker exec "$CONTAINER" curl -s -m "$PROBE_TIMEOUT" "$MPM_URL" 2>/dev/null)
    busy=$(echo "$ss" | awk -F: '/^BusyWorkers:/{gsub(/ /,"",$2);print $2}')
    idle=$(echo "$ss" | awk -F: '/^IdleWorkers:/{gsub(/ /,"",$2);print $2}')
    extra="busy=$busy idle=$idle"
    [ "$verdict" = "WSGI_SATURATED" ] && extra="$extra (app threads exhausted; check for register_cache_file self-calls / AH03490 in error_log)"
  fi
  [ "$verdict" = "FULL_WEDGE" ] && extra="(scoreboard full: AH03490 in error_log; all endpoints incl. server-status starved)"

  echo "$ts $verdict mpm=${mpm_code}/${mpm_t}s app=${app_code}/${app_t}s $extra" >> "$LOG"
  echo "$verdict" > "$STATE"
  if [ "$verdict" != "$prev" ] && [ "$prev" != "" ]; then
    echo "$ts TRANSITION $prev -> $verdict" | tee -a "$LOG" >&2
  fi
  prev=$verdict

  [ "$MAX_LOOPS" -gt 0 ] && [ "$loop" -ge "$MAX_LOOPS" ] && exit $rc
  sleep "$INTERVAL"
done

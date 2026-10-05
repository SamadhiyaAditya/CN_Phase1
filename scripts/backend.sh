#!/usr/bin/env bash
# Task C - run a backend.  Backend A on Mac 3, Backend B on Mac 4.
#
#   scripts/backend.sh run A      foreground (best for demo: you SEE requests arrive)
#   scripts/backend.sh start A    background, log in runtime/backend-A.log
#   scripts/backend.sh stop A
#   scripts/backend.sh status A
#   scripts/backend.sh logs A
set -euo pipefail
source "$(dirname "$0")/common.sh"

cmd="${1:-}"; name="$(echo "${2:-}" | tr a-z A-Z)"
case "$name" in
  A) port="$BACKEND_A_PORT"; ip="$MAC3_IP" ;;
  B) port="$BACKEND_B_PORT"; ip="$MAC4_IP" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
PIDF="$RUNTIME/backend-$name.pid"; LOG="$RUNTIME/backend-$name.log"
SRV=(python3 "$ROOT/backend/server.py" --name "$name" --port "$port" --team "$TEAM_NAME")
running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

case "$cmd" in
  run)    exec "${SRV[@]}" ;;
  start)  running && { ok "Backend $name already running"; exit 0; }
          nohup "${SRV[@]}" >>"$LOG" 2>&1 & echo $! > "$PIDF"; sleep 0.5
          running && ok "Backend $name started on 0.0.0.0:$port (pid $(cat "$PIDF"))" || die "failed - see $LOG" ;;
  stop)   if running; then kill "$(cat "$PIDF")"; ok "Backend $name stopped"; else ok "Backend $name not running"; fi; rm -f "$PIDF" ;;
  status) running && ok "Backend $name running (pid $(cat "$PIDF"))" || warn "Backend $name NOT running (as background job)"
          run curl -s --noproxy "*" -i "http://127.0.0.1:$port/api/status" || true
          echo; echo "Reachable from the LAN at http://$ip:$port (test from Mac 2: curl http://$ip:$port/api/status)" ;;
  logs)   tail -n 30 -f "$LOG" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac

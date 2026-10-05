#!/usr/bin/env bash
# Tasks D + E - nginx edge (reverse proxy, load balancer, TLS).  Run on Mac 2.
#
#   scripts/edge.sh certs     create CA + server cert (tls/make-certs.sh)
#   scripts/edge.sh start     render edge/out/nginx.conf, test it, start nginx
#   scripts/edge.sh reload    re-render + graceful reload (no dropped requests)
#   scripts/edge.sh stop
#   scripts/edge.sh status
#   scripts/edge.sh logs      follow access log - shows upstream=A/B per request
set -euo pipefail
source "$(dirname "$0")/common.sh"

OUT="$ROOT/edge/out"; CONF="$OUT/nginx.conf"; PIDF="$RUNTIME/nginx.pid"
mkdir -p "$OUT" "$RUNTIME/tmp"

NGINX="$(find_bin nginx || true)"
need_nginx() {
  if [ -z "$NGINX" ]; then
    if is_mac && command -v brew >/dev/null; then run brew install nginx; NGINX="$(find_bin nginx)"
    else die "nginx not installed (macOS: brew install nginx)"; fi
  fi
}

# "http2 on;" exists from nginx 1.25.1; older builds use "listen ... ssl http2"
listen_line() {
  local v; v="$("$NGINX" -v 2>&1 | sed -E 's|.*nginx/([0-9.]+).*|\1|')"
  if printf '%s\n1.25.1\n' "$v" | sort -V -C 2>/dev/null && [ "$v" != "1.25.1" ]; then
    echo "listen ${HTTPS_PORT} ssl http2;"
  else
    echo "listen ${HTTPS_PORT} ssl;  http2 on;"
  fi
}

do_render() {
  need_nginx
  [ -f "$TLS_DIR/server-chain.crt" ] || bash "$ROOT/tls/make-certs.sh"
  render "$ROOT/edge/nginx.conf.template" "$CONF" -e "s|{{LISTEN_HTTPS}}|$(listen_line)|"
  run sudo "$NGINX" -t -p "$RUNTIME" -c "$CONF"
}
running() { [ -f "$PIDF" ] && sudo kill -0 "$(cat "$PIDF")" 2>/dev/null; }

case "${1:-}" in
  certs)  bash "$ROOT/tls/make-certs.sh" "${2:-}" ;;
  start)  do_render
          if running; then run sudo "$NGINX" -p "$RUNTIME" -c "$CONF" -s reload
          else run sudo "$NGINX" -p "$RUNTIME" -c "$CONF"; fi
          sleep 0.5; running && ok "nginx running - $APP_URL -> ${MAC3_IP}:${BACKEND_A_PORT} / ${MAC4_IP}:${BACKEND_B_PORT}" ;;
  reload) do_render; run sudo "$NGINX" -p "$RUNTIME" -c "$CONF" -s reload; ok "reloaded" ;;
  stop)   if running; then run sudo "$NGINX" -p "$RUNTIME" -c "$CONF" -s quit; ok "nginx stopped"; else ok "nginx not running"; fi ;;
  status) running && ok "nginx running (pid $(cat "$PIDF"))" || warn "nginx NOT running"
          if is_mac; then run sudo lsof -nP -iTCP -sTCP:LISTEN | grep -E "nginx" || true
          else run sudo ss -ltnp | grep nginx || true; fi
          for b in "${MAC3_IP}:${BACKEND_A_PORT}" "${MAC4_IP}:${BACKEND_B_PORT}"; do
            if curl -s --noproxy "*" --max-time 2 "http://$b/healthz" >/dev/null; then ok "backend $b reachable from edge"; else warn "backend $b NOT reachable from edge"; fi
          done ;;
  logs)   tail -n 30 -f "$RUNTIME/logs/nginx-access.log" ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac

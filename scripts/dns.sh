#!/usr/bin/env bash
# Task B - private DNS server.  Run on Mac 1.
#
#   scripts/dns.sh start          render dns/out/dnsmasq.conf and start dnsmasq
#   scripts/dns.sh stop
#   scripts/dns.sh restart
#   scripts/dns.sh status         is it running + test queries against it
#   scripts/dns.sh logs           follow the query log (great for the demo)
#   scripts/dns.sh wrong-record   failure demo: app.<domain> -> WRONG_IP
#   scripts/dns.sh fix            undo wrong-record (same as restart)
set -euo pipefail
source "$(dirname "$0")/common.sh"

CONF_DIR="$ROOT/dns/out"; CONF="$CONF_DIR/dnsmasq.conf"
PIDF="$RUNTIME/dnsmasq.pid"
mkdir -p "$CONF_DIR"

DNSMASQ="$(find_bin dnsmasq || true)"
need_dnsmasq() {
  if [ -z "$DNSMASQ" ]; then
    if is_mac && command -v brew >/dev/null; then run brew install dnsmasq; DNSMASQ="$(find_bin dnsmasq)"
    else die "dnsmasq not installed (macOS: brew install dnsmasq)"; fi
  fi
}

running() { [ -f "$PIDF" ] && sudo kill -0 "$(cat "$PIDF")" 2>/dev/null; }

do_stop() {
  if running; then run sudo kill "$(cat "$PIDF")"; sleep 0.5; ok "dnsmasq stopped"; else ok "dnsmasq not running"; fi
  sudo rm -f "$PIDF"
}

do_start() {
  local app_ip="${1:-$MAC2_IP}"
  need_dnsmasq
  render "$ROOT/dns/dnsmasq.conf.template" "$CONF" -e "s|{{APP_IP}}|${app_ip}|g"
  touch "$RUNTIME/dnsmasq.log"
  run "$DNSMASQ" --test -C "$CONF"
  do_stop >/dev/null
  run sudo "$DNSMASQ" -C "$CONF"
  sleep 0.5
  running && ok "dnsmasq running (pid $(cat "$PIDF")) - app.${DOMAIN} -> ${app_ip}" || die "dnsmasq failed to start - see $RUNTIME/dnsmasq.log"
}

do_status() {
  running && ok "dnsmasq running (pid $(cat "$PIDF"))" || warn "dnsmasq NOT running"
  for n in app api; do run dig +noall +answer +stats "@${MAC1_IP}" "$n.${DOMAIN}" A | grep -E "IN|SERVER|Query time" || true; done
}

case "${1:-}" in
  start)        do_start ;;
  stop)         do_stop ;;
  restart|fix)  do_start ;;
  status)       do_status ;;
  logs)         tail -n 30 -f "$RUNTIME/dnsmasq.log" ;;
  wrong-record) warn "FAILURE DEMO: app/api.${DOMAIN} will now resolve to ${WRONG_IP} (not the edge)"
                do_start "$WRONG_IP" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac

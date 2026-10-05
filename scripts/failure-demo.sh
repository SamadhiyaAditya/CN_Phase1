#!/usr/bin/env bash
# Section 6.3 - the five required failure demonstrations.
# Run on the CLIENT Mac. Some steps ask you to do something on
# another Mac first; the script waits for Enter.  Output of every scenario is
# saved in evidence/failures/.
#
#   scripts/failure-demo.sh            menu
#   scripts/failure-demo.sh 1..5       one scenario
#   scripts/failure-demo.sh all        all five in order (≈ 1 minute for the video)
set -uo pipefail
source "$(dirname "$0")/common.sh"
curl_tls_args

pause() { printf '\n%s>>> %s%s\n' "$c_yel" "$*" "$c_off"; read -r -p "    press Enter when done... " _; }
probe() {   # the same 3 checks every time: DNS, IP reachability, the service
  echo "--- DNS:     dig +short app.${DOMAIN}"
  dig +short +time=2 +tries=1 "app.${DOMAIN}" 2>&1 | sed 's/^/    /'
  echo "--- IP:      ping -c 2 ${MAC2_IP}  (the edge, by address)"
  ping -c 2 "${MAC2_IP}" 2>&1 | tail -1 | sed 's/^/    /'
  echo "--- SERVICE: curl $APP_URL/api/status"
  curl -sS "${CURL_TLS[@]}" --max-time 6 -o /dev/null -w '    HTTP %{http_code}  X-remote=%{remote_ip}:%{remote_port}\n' "$APP_URL/api/status" 2>&1 | sed 's/^/    /'
}
tcpcheck() { if is_mac; then nc -vz -G 3 "$1" "$2"; else nc -vz -w 3 "$1" "$2"; fi 2>&1 | sed 's/^/    /'; }
record() { local f="$EVID/failures/$1-$(host_tag)-$(stamp).txt"; { echo "# $1 - on $(host_tag) - $(date)"; "$2"; } 2>&1 | tee "$f"; ok "saved $f"; }

f1() {  # wrong DNS server on the client
  say "F1  Wrong DNS server configured on this client"
  echo "Before:"; probe
  bash "$ROOT/scripts/client-dns.sh" set "$WRONG_IP" >/dev/null
  echo; echo "After pointing DNS at $WRONG_IP (a machine with no DNS server):"; probe
  echo; echo "But the edge is still reachable by IP over TCP 443:"
  tcpcheck "$MAC2_IP" "$HTTPS_PORT"
  bash "$ROOT/scripts/client-dns.sh" restore >/dev/null 2>&1; bash "$ROOT/scripts/client-dns.sh" use >/dev/null
  echo; echo "Restored DNS -> ${MAC1_IP}:"; probe
  echo "WHY: name lookup fails, IP connectivity is fine -> DNS and IP are independent layers."
}

f2() {  # DNS record points at the wrong IP
  say "F2  DNS record points to a wrong IP"
  pause "On ${DNS_MAC} run:   scripts/dns.sh wrong-record      (app.${DOMAIN} -> ${WRONG_IP})"
  flush_dns_cache
  probe
  echo "--- verbose: where does curl actually go?"
  curl -sv "${CURL_TLS[@]}" --max-time 5 "$APP_URL/" 2>&1 | grep -E "Trying|Connected|connect to|Failed|refused" | sed 's/^/    /'
  echo "WHY: resolution SUCCEEDS, but returns ${WRONG_IP}, which has nothing on :${HTTPS_PORT}."
  echo "     DNS is just a directory - it hands out an address, it does not make a connection."
  pause "On ${DNS_MAC} run:   scripts/dns.sh fix"
  flush_dns_cache; probe
}

f3() {  # one backend stopped
  say "F3  One backend stopped"
  pause "On ${A_MAC} stop Backend A   (Ctrl+C in its window, or scripts/backend.sh stop A)"
  for i in $(seq 1 6); do
    curl -sS "${CURL_TLS[@]}" -o /dev/null -D - -w '' "$APP_URL/api/status" \
      | awk -v i="$i" -F': ' '/^HTTP/{s=$0} tolower($1)=="x-backend"{gsub("\r","");printf "request %d -> %s  X-Backend: %s\n", i, s, $2}' | tr -d '\r'
  done
  echo "WHY: nginx gets 'connection refused' from A, retries on B (proxy_next_upstream) and marks A"
  echo "     down for fail_timeout=10s. The client never notices - every request is 200 from B."
}

f4() {  # both backends stopped
  say "F4  Both backends stopped"
  pause "On ${B_MAC} stop Backend B too   (Ctrl+C in its window; Backend A stays stopped)"
  probe
  echo "--- verbose: TLS works, the error comes from nginx itself"
  curl -sv "${CURL_TLS[@]}" "$APP_URL/api/status" 2>&1 | grep -E "SSL connection|verify ok|subject:|^< HTTP|<h1>" | sed 's/^/    /'
  echo "WHY: DNS ok, TCP ok, TLS ok (handled by the edge) - only the upstream is gone, so nginx"
  echo "     answers 502 Bad Gateway. That is exactly where the edge ends and the backend begins."
  pause "Start both backends again (${A_MAC}: scripts/backend.sh run A, ${B_MAC}: scripts/backend.sh run B)"
  echo "    waiting 10 s - nginx keeps a failed backend out of the pool for fail_timeout=10s"; sleep 10
  probe
}

f5() {  # wrong port
  local bad=$((HTTPS_PORT + 1))
  say "F5  Wrong destination port on the client"
  echo "--- ping ${MAC2_IP} (host is up)"; ping -c 2 "$MAC2_IP" 2>&1 | tail -1 | sed 's/^/    /'
  echo "--- TCP to the RIGHT port ${HTTPS_PORT}"; tcpcheck "$MAC2_IP" "$HTTPS_PORT"
  echo "--- TCP to the WRONG port ${bad}";        tcpcheck "$MAC2_IP" "$bad"
  echo "--- curl https://app.${DOMAIN}:${bad}/"
  curl -sS "${CURL_TLS[@]}" --max-time 5 "https://app.${DOMAIN}:${bad}/" 2>&1 | sed 's/^/    /'
  echo "WHY: same IP, same host - but nothing listens on :${bad}, so the OS answers the SYN with a"
  echo "     RST ('connection refused'). IP picks the machine, the port picks the program."
}

case "${1:-menu}" in
  1) record F1-wrong-dns-server f1 ;;
  2) record F2-wrong-dns-record f2 ;;
  3) record F3-one-backend-down f3 ;;
  4) record F4-both-backends-down f4 ;;
  5) record F5-wrong-port f5 ;;
  all) for n in 1 5 2 3 4; do "$0" "$n"; done ;;
  *) echo "1) wrong DNS server   2) wrong DNS record   3) one backend down"
     echo "4) both backends down   5) wrong port   all) everything"
     read -r -p "choose: " n; exec "$0" "$n" ;;
esac

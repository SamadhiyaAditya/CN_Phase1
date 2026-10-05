#!/usr/bin/env bash
# Tasks B, D, E, F, G - one command that produces all the text evidence for a
# client (run on Mac 1 and Mac 4).  Everything is also saved to
# evidence/text/verify-<host>-<time>.txt
#
#   scripts/verify.sh            all sections
#   scripts/verify.sh dns|https|lb|cache|http2|ports|tls     one section
set -uo pipefail
source "$(dirname "$0")/common.sh"

SECTION="${1:-all}"
OUT="$EVID/text/verify-$(host_tag)-$(stamp)-${SECTION}.txt"
curl_tls_args
hdr() { printf '\n%s================ %s ================%s\n' "$c_bold" "$*" "$c_off"; }

sec_dns() {
  hdr "B. DNS - who answers for app.${DOMAIN}?"
  echo "Expect: ANSWER = ${MAC2_IP} (the edge), SERVER = ${MAC1_IP}#53 (our DNS)"
  run dig "app.${DOMAIN}"
  run dig +short "api.${DOMAIN}"
  run nslookup "app.${DOMAIN}"
  if is_mac; then run dscacheutil -q host -a name "app.${DOMAIN}"; fi
}

sec_https() {
  hdr "E. HTTPS by NAME, certificate verified (no -k)"
  run curl -v "${CURL_TLS[@]}" "$APP_URL/api/status" 2>&1 | grep -vE '^\{|^\}|^  "' | sed -n '1,60p'
  run curl -sS "${CURL_TLS[@]}" "$APP_URL/api/status"
}

sec_lb() {
  hdr "D. Load balancing - 10 requests to the same name"
  local a=0 b=0 i bk
  for i in $(seq 1 10); do
    bk="$(curl -s "${CURL_TLS[@]}" -o /dev/null -D - "$APP_URL/api/status" | awk -F': ' 'tolower($1)=="x-backend"{gsub("\r","",$2); print $2}')"
    printf 'request %2d -> X-Backend: %s\n' "$i" "${bk:-<none>}"
    [ "$bk" = "A" ] && a=$((a+1)); [ "$bk" = "B" ] && b=$((b+1))
  done
  echo "summary: A=$a  B=$b  (round robin => roughly half each)"
}

sec_cache() {
  hdr "F. HTTP caching - Cache-Control + ETag + 304"
  echo "--- 1) full request: server sends the body + caching headers"
  run curl -sS -I "${CURL_TLS[@]}" "$APP_URL/api/info"
  local etag
  etag="$(curl -sS -I "${CURL_TLS[@]}" "$APP_URL/api/info" | awk -F': ' 'tolower($1)=="etag"{gsub("\r","",$2); print $2}')"
  echo "--- 2) conditional request: 'I already have version $etag - has it changed?'"
  run curl -sS -I "${CURL_TLS[@]}" -H "If-None-Match: $etag" "$APP_URL/api/info"
  echo "--- 3) same conditional request again (probably the OTHER backend this time):"
  curl -sS -I "${CURL_TLS[@]}" -H "If-None-Match: $etag" "$APP_URL/api/info" | grep -iE "^HTTP|x-backend|etag"
  echo "=> 304 Not Modified + no body. Both backends hash the same content, so either can say 304."
  echo "--- 4) /api/status is live data, so it is marked no-store:"
  curl -sS -I "${CURL_TLS[@]}" "$APP_URL/api/status" | grep -iE "^HTTP|cache-control|x-backend"
}

sec_http2() {
  hdr "HTTP/1.1 vs HTTP/2 (negotiated with ALPN inside the TLS handshake)"
  local w='negotiated: HTTP/%{http_version}  status %{http_code}\n'
  run curl -sS -o /dev/null --http1.1 "${CURL_TLS[@]}" -w "$w" "$APP_URL/"
  if curl -V | grep -q HTTP2; then run curl -sS -o /dev/null --http2 "${CURL_TLS[@]}" -w "$w" "$APP_URL/"
  else echo "(this curl build has no HTTP/2 - use the browser: DevTools > Network > Protocol column shows h2)"; fi
}

sec_ports() {
  hdr "G. Ports / socket pair for one HTTPS request"
  run curl -sS "${CURL_TLS[@]}" -o /dev/null -w 'client %{local_ip}:%{local_port}  ->  server %{remote_ip}:%{remote_port}   (HTTP %{http_code}, %{http_version})\ntimings: dns=%{time_namelookup}s tcp=%{time_connect}s tls=%{time_appconnect}s first-byte=%{time_starttransfer}s total=%{time_total}s\n' "$APP_URL/api/status"
  echo "DNS uses UDP ${MAC1_IP}:53, HTTPS uses TCP ${MAC2_IP}:${HTTPS_PORT}; the client side is a random ephemeral port."
}

sec_tls() {
  hdr "E. TLS handshake details from openssl s_client"
  local ca=(); [ -f "$TLS_DIR/ca.crt" ] && ca=(-CAfile "$TLS_DIR/ca.crt")
  echo | run openssl s_client -connect "app.${DOMAIN}:${HTTPS_PORT}" -servername "app.${DOMAIN}" -alpn h2,http/1.1 "${ca[@]}" -showcerts 2>&1 \
    | grep -E "depth|s:|i:|Protocol|Cipher|Verify return|Server certificate|subject=|issuer=|ALPN" | head -30
}

{
  echo "# verify.sh on $(host_tag) - $(date) - URL $APP_URL"
  [[ " ${CURL_TLS[*]} " == *" --cacert "* ]] && echo "(curl uses --cacert tls/out/ca.crt = full verification against our CA, NOT -k)"
  case "$SECTION" in
    all) sec_dns; sec_https; sec_lb; sec_cache; sec_http2; sec_ports; sec_tls ;;
    dns|https|lb|cache|http2|ports|tls) "sec_$SECTION" ;;
    *) sed -n '2,8p' "$0"; exit 1 ;;
  esac
} 2>&1 | tee "$OUT"
echo; ok "saved $OUT"

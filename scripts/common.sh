#!/usr/bin/env bash
# Shared helpers - sourced by every other script. Not meant to be run directly.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ENV="${TEAM_ENV:-$ROOT/team.env}"
[ -f "$TEAM_ENV" ] || { echo "team.env not found at $TEAM_ENV" >&2; exit 1; }
# shellcheck disable=SC1090
source "$TEAM_ENV"

RUNTIME="${RUNTIME:-$ROOT/runtime}"
TLS_DIR="$ROOT/tls/out"
EVID="$ROOT/evidence"
mkdir -p "$RUNTIME/logs" "$RUNTIME/tmp" "$EVID"/{inventory,pcap,screenshots,text,failures}

# The user that owns the repo - daemons drop to it so they can read/write here
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "$RUN_USER")"

if [ "${HTTPS_PORT}" = "443" ]; then HTTPS_SUFFIX=""; else HTTPS_SUFFIX=":${HTTPS_PORT}"; fi
APP_URL="https://app.${DOMAIN}${HTTPS_SUFFIX}"
API_URL="https://api.${DOMAIN}${HTTPS_SUFFIX}"

is_mac() { [ "$(uname -s)" = "Darwin" ]; }
c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
say()  { printf '%s==> %s%s\n' "$c_bold" "$*" "$c_off"; }
ok()   { printf '%s  ok  %s%s\n' "$c_grn" "$*" "$c_off"; }
warn() { printf '%s  !!  %s%s\n' "$c_yel" "$*" "$c_off"; }
die()  { printf '%s  xx  %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
# Print a command, then run it (so recordings/evidence show exactly what ran)
run()  { printf '%s$ %s%s\n' "$c_dim" "$*" "$c_off"; "$@"; }
stamp() { date +%Y%m%d-%H%M%S; }
host_tag() { hostname -s 2>/dev/null || hostname; }

# render <template> <output> [extra sed expressions...]
render() {
  local tpl="$1" out="$2"; shift 2
  sed -e "s|{{TEAM_NAME}}|${TEAM_NAME}|g" \
      -e "s|{{DOMAIN}}|${DOMAIN}|g" \
      -e "s|{{MAC1_IP}}|${MAC1_IP}|g" \
      -e "s|{{MAC2_IP}}|${MAC2_IP}|g" \
      -e "s|{{MAC3_IP}}|${MAC3_IP}|g" \
      -e "s|{{MAC4_IP}}|${MAC4_IP}|g" \
      -e "s|{{BACKEND_A_PORT}}|${BACKEND_A_PORT}|g" \
      -e "s|{{BACKEND_B_PORT}}|${BACKEND_B_PORT}|g" \
      -e "s|{{HTTP_PORT}}|${HTTP_PORT}|g" \
      -e "s|{{HTTPS_PORT}}|${HTTPS_PORT}|g" \
      -e "s|{{HTTPS_SUFFIX}}|${HTTPS_SUFFIX}|g" \
      -e "s|{{UPSTREAM_DNS}}|${UPSTREAM_DNS}|g" \
      -e "s|{{DNS_TTL}}|${DNS_TTL}|g" \
      -e "s|{{RUNTIME}}|${RUNTIME}|g" \
      -e "s|{{TLS_DIR}}|${TLS_DIR}|g" \
      -e "s|{{RUN_USER}}|${RUN_USER}|g" \
      -e "s|{{RUN_GROUP}}|${RUN_GROUP}|g" \
      "$@" "$tpl" > "$out"
}

# Find a binary even if Homebrew's sbin isn't on PATH
find_bin() {
  local b="$1" p
  command -v "$b" 2>/dev/null && return 0
  for p in /opt/homebrew/sbin /opt/homebrew/bin /usr/local/sbin /usr/local/bin /usr/sbin; do
    [ -x "$p/$b" ] && { echo "$p/$b"; return 0; }
  done
  return 1
}

# Default network interface + macOS "network service" name (e.g. en0 -> Wi-Fi)
default_iface() {
  if is_mac; then route -n get default 2>/dev/null | awk '/interface:/{print $2}'
  else ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'; fi
}
mac_service_for_iface() {
  networksetup -listnetworkserviceorder | awk -v dev="$1" '
    /^\([0-9*]+\)/ { name=$0; sub(/^\([0-9*]+\) /, "", name) }
    /Device: / { if (index($0, "Device: " dev ")")) { print name; exit } }'
}

# curl options that make TLS verification work WITHOUT -k:
# if the CA is already in the system trust store, nothing extra is needed;
# otherwise point curl at the team CA file (still full verification).
# --noproxy '*' : talk to our LAN directly even if an HTTP(S)_PROXY is set.
curl_tls_args() {
  if curl -s --noproxy '*' -o /dev/null --max-time 5 "$APP_URL/healthz" 2>/dev/null; then
    CURL_TLS=(--noproxy '*')
  elif [ -f "$TLS_DIR/ca.crt" ]; then
    CURL_TLS=(--noproxy '*' --cacert "$TLS_DIR/ca.crt")
  else
    CURL_TLS=(--noproxy '*')
    warn "CA not trusted yet and tls/out/ca.crt missing - run scripts/trust-ca.sh first"
  fi
}

flush_dns_cache() {
  if is_mac; then sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null || true
  else command -v resolvectl >/dev/null && sudo resolvectl flush-caches 2>/dev/null || true; fi
}

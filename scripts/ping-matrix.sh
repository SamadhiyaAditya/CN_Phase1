#!/usr/bin/env bash
# Task A - prove every machine can reach every other one.  Run on EVERY Mac.
# Saves evidence/inventory/ping-<hostname>.txt
set -uo pipefail
source "$(dirname "$0")/common.sh"

OUT="$EVID/inventory/ping-$(host_tag).txt"
{
  echo "# Ping matrix from $(host_tag) - $(date)"
  # one line per physical machine (on a 2-Mac team several roles share an IP)
  IPS=(); NAMES=()
  for pair in "Mac1-DNS:$MAC1_IP" "Mac2-Edge:$MAC2_IP" "Mac3-BackendA:$MAC3_IP" "Mac4-BackendB:$MAC4_IP"; do
    n="${pair%%:*}"; ip="${pair#*:}"; found=""
    for i in "${!IPS[@]}"; do [ "${IPS[$i]}" = "$ip" ] && { NAMES[$i]="${NAMES[$i]}+$n"; found=1; }; done
    [ -n "$found" ] || { IPS+=("$ip"); NAMES+=("$n"); }
  done
  for i in "${!IPS[@]}"; do
    name="${NAMES[$i]}"; ip="${IPS[$i]}"
    echo; echo "## $name ($ip)"
    if is_mac; then W=1000; else W=1; fi      # -W is ms on macOS, seconds on Linux
    if ping -c 3 -W "$W" "$ip" >/tmp/ping.$$ 2>&1; then
      tail -2 /tmp/ping.$$; echo "RESULT: $name reachable"
    else
      tail -3 /tmp/ping.$$; echo "RESULT: $name UNREACHABLE"
    fi
  done
  rm -f /tmp/ping.$$
} | tee "$OUT"
echo; ok "saved $OUT"

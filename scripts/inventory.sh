#!/usr/bin/env bash
# Task A - record this Mac's network identity.  Run on EVERY Mac.
#   scripts/inventory.sh "Mac 2 - Edge"
# Writes evidence/inventory/<hostname>.txt and prints a table row you can
# paste into docs/ARCHITECTURE.md.
set -euo pipefail
source "$(dirname "$0")/common.sh"

ROLE="${1:-unknown role}"
IFACE="$(default_iface)"; [ -n "$IFACE" ] || die "no default route - are you on the LAN?"
OUT="$EVID/inventory/$(host_tag).txt"

hexmask_to_dotted() { local h="${1#0x}"; printf '%d.%d.%d.%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}" "0x${h:6:2}"; }
mask_to_prefix() { local IFS=. n=0 o; for o in $1; do while [ "$o" -gt 0 ]; do n=$((n + (o & 1))); o=$((o >> 1)); done; done; echo "$n"; }

if is_mac; then
  IP="$(ipconfig getifaddr "$IFACE")"
  MASK="$(hexmask_to_dotted "$(ifconfig "$IFACE" | awk '/inet /{print $4; exit}')")"
  GW="$(route -n get default | awk '/gateway:/{print $2}')"
  MAC="$(ifconfig "$IFACE" | awk '/ether/{print $2; exit}')"
  SVC="$(mac_service_for_iface "$IFACE")"
  DNS="$(networksetup -getdnsservers "$SVC" 2>/dev/null | tr '\n' ' ')"
else
  CIDR="$(ip -4 -o addr show "$IFACE" | awk '{print $4; exit}')"; IP="${CIDR%/*}"; PFX="${CIDR#*/}"
  MASK="$(python3 -c "import ipaddress;print(ipaddress.ip_network('0.0.0.0/$PFX').netmask)")"
  GW="$(ip route show default | awk '{print $3; exit}')"
  MAC="$(cat /sys/class/net/"$IFACE"/address)"; SVC="$IFACE"
  DNS="$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)"
fi
PREFIX="$(mask_to_prefix "$MASK")"

{
  echo "# Inventory - $(host_tag) - $ROLE"
  echo "collected: $(date)"
  echo
  printf '%-18s %s\n' "Hostname" "$(hostname)" "Role" "$ROLE" "Interface" "$IFACE ($SVC)" \
    "IPv4 address" "$IP" "Subnet mask" "$MASK (/$PREFIX)" "Default gateway" "$GW" \
    "MAC address" "$MAC" "DNS servers" "${DNS:-<none>}"
  echo
  echo "## raw: interface"
  if is_mac; then ifconfig "$IFACE"; else ip addr show "$IFACE"; fi
  echo
  echo "## raw: routing table (IPv4)"
  if is_mac; then netstat -rn -f inet | head -20; else ip route; fi
  echo
  echo "## listening TCP sockets"
  if is_mac; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | head -30; else ss -ltn; fi
} | tee "$OUT"

echo
say "Markdown row for docs/ARCHITECTURE.md:"
echo "| $ROLE | $(hostname -s 2>/dev/null || hostname) | $IFACE | $IP | $MASK (/$PREFIX) | $GW | $MAC |"
ok "saved $OUT"

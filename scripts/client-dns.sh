#!/usr/bin/env bash
# Task B - point a client at the team DNS server (Mac 1).
# macOS: same thing as System Settings -> Network -> <Wi-Fi> -> Details -> DNS.
# Linux / virtual hosts: rewrites this host's /etc/resolv.conf.
#
#   scripts/client-dns.sh use        DNS = Mac 1   (saves your old setting first)
#   scripts/client-dns.sh set <ip>   DNS = any IP  (used by the failure demo)
#   scripts/client-dns.sh restore    put back what you had before
#   scripts/client-dns.sh show
set -euo pipefail
source "$(dirname "$0")/common.sh"

if is_mac; then
  IFACE="$(default_iface)"; SVC="$(mac_service_for_iface "$IFACE")"
  [ -n "$SVC" ] || die "could not find the network service for $IFACE"
  BACKUP="$RUNTIME/dns-backup-$(echo "$SVC" | tr ' /' '__').txt"
  current() { networksetup -getdnsservers "$SVC" | grep -E '^[0-9a-fA-F:.]+$' || true; }
  setdns()  { run sudo networksetup -setdnsservers "$SVC" "$@"; }
  show() {
    say "DNS servers for \"$SVC\" ($IFACE):"; networksetup -getdnsservers "$SVC"
    say "What the resolver is actually using:"; scutil --dns | awk '/resolver #1/,/^$/' | grep -E "nameserver|search" || true
  }
else
  BACKUP="$RUNTIME/dns-backup-$(host_tag).txt"
  current() { awk '/^nameserver/{print $2}' /etc/resolv.conf; }
  setdns()  { if [ "$1" = "empty" ]; then : > /etc/resolv.conf; else printf 'nameserver %s\n' "$@" > /etc/resolv.conf; fi
              printf '%s$ (resolv.conf) nameserver %s%s\n' "$c_dim" "$*" "$c_off"; }
  show()    { say "DNS servers on $(host_tag) (/etc/resolv.conf):"; grep nameserver /etc/resolv.conf || echo "(none)"; }
fi

apply() {
  [ -f "$BACKUP" ] || { current > "$BACKUP"; ok "saved previous DNS ($(tr '\n' ' ' < "$BACKUP")) to $BACKUP"; }
  setdns "$@"; flush_dns_cache; show
}

case "${1:-}" in
  use)     apply "$MAC1_IP" ;;
  set)     [ -n "${2:-}" ] || die "usage: $0 set <ip>"; apply "$2" ;;
  restore) if [ -s "$BACKUP" ]; then setdns $(cat "$BACKUP"); else setdns empty; fi
           rm -f "$BACKUP"; flush_dns_cache; show ;;
  show)    show ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac

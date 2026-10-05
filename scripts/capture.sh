#!/usr/bin/env bash
# Task G - capture ONE complete request (DNS -> TCP -> TLS -> HTTP) on a client.
# Run on the client Mac.  Needs sudo (tcpdump).
#
#   scripts/capture.sh            TLS 1.2 (default) - every handshake message
#                                 incl. the Certificate is visible in clear text
#   TLS=1.3 scripts/capture.sh    TLS 1.3 - Certificate is encrypted (shows up as
#                                 "Application Data"); load the key log to see it
#
# Produces:
#   evidence/pcap/full-flow-<host>-<time>.pcap      open this in Wireshark
#   evidence/pcap/sslkeys-<host>-<time>.log         TLS secrets (only if curl
#        supports SSLKEYLOGFILE) - Wireshark > Settings > Protocols > TLS >
#        (Pre)-Master-Secret log filename  => decrypts the HTTP inside TLS
#   evidence/text/capture-<host>-<time>.txt         text decode of the packets
set -uo pipefail
source "$(dirname "$0")/common.sh"

IFACE="${IFACE:-$(default_iface)}"
T="$(stamp)"; H="$(host_tag)"
PCAP="$EVID/pcap/full-flow-tls${TLS:-1.2}-$H-$T.pcap"
KEYS="$EVID/pcap/sslkeys-$H-$T.log"
TXT="$EVID/text/capture-$H-$T.txt"
FILTER="(udp port 53 and host ${MAC1_IP}) or (tcp port ${HTTPS_PORT} and host ${MAC2_IP})"
curl_tls_args
TLSV="${TLS:-1.2}"; TLSARG=(--tls-max "$TLSV"); [ "$TLSV" = "1.3" ] && TLSARG=(--tlsv1.3)

say "1) Flushing the DNS cache so the capture includes a real DNS query"
flush_dns_cache

sudo -v   # ask for the password now, not while tcpdump is in the background
say "2) Starting tcpdump on $IFACE  filter: $FILTER"
sudo tcpdump -i "$IFACE" -s 0 -U -w "$PCAP" "$FILTER" >/dev/null 2>&1 &
TCPDUMP_PID=$!
sleep 2

say "3) One request by name (TLS $TLSV)"
SSLKEYLOGFILE="$KEYS" run curl -sS "${CURL_TLS[@]}" "${TLSARG[@]}" -D - -o /dev/null \
  -w 'client %{local_ip}:%{local_port} -> server %{remote_ip}:%{remote_port}\n' "$APP_URL/api/status" | tee "$EVID/text/capture-curl-$H-$T.txt"
sleep 2

say "4) Stopping capture"
sudo pkill -INT -x tcpdump; wait "$TCPDUMP_PID" 2>/dev/null
sudo chown "$RUN_USER" "$PCAP" 2>/dev/null || true
[ -s "$KEYS" ] || rm -f "$KEYS"

{
  echo "# Capture on $H ($IFACE) - $(date)"
  echo "# filter: $FILTER"
  echo
  echo "## Every packet (tcpdump -nn -S: numeric ports, absolute seq/ack numbers)"
  tcpdump -nn -S -r "$PCAP" 2>/dev/null
  TSHARK="$(command -v tshark || ls /Applications/Wireshark.app/Contents/MacOS/tshark 2>/dev/null || true)"
  if [ -n "$TSHARK" ]; then tshark() { "$TSHARK" "$@"; }
    echo; echo "## DNS query/response"
    tshark -r "$PCAP" -Y dns -T fields -e frame.number -e ip.src -e udp.srcport -e ip.dst -e udp.dstport -e dns.qry.name -e dns.a -e dns.resp.ttl 2>/dev/null
    echo; echo "## TCP three-way handshake (SYN / SYN-ACK / ACK) with relative seq/ack"
    tshark -r "$PCAP" -Y "tcp.port==${HTTPS_PORT} && (tcp.flags.syn==1 || (tcp.seq==1 && tcp.ack==1 && tcp.len==0))" -T fields \
      -e frame.number -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.flags.str -e tcp.seq -e tcp.ack 2>/dev/null | head -6
    echo; echo "## TLS handshake messages"
    tshark -r "$PCAP" -Y "tls.handshake or tls.change_cipher_spec or tls.app_data" -T fields \
      -e frame.number -e ip.src -e _ws.col.Info 2>/dev/null | head -20
  else
    echo; echo "(install Wireshark for a decoded DNS/TCP/TLS summary: brew install --cask wireshark)"
  fi
} > "$TXT"

ok "pcap:  $PCAP"
ok "text:  $TXT"
[ -f "$KEYS" ] && ok "keys:  $KEYS  (load into Wireshark to decrypt)"
cat <<EOF

Open the pcap in Wireshark and use these display filters for screenshots:
  dns                                      -> query + response with ${MAC2_IP}
  tcp.flags.syn==1                         -> SYN and SYN-ACK
  tcp.stream eq 0                          -> the whole TCP conversation
  tls.handshake                            -> ClientHello / ServerHello / Certificate ...
  tls.handshake.type == 1                  -> ClientHello (look at SNI + ALPN)
  tls.app_data                             -> encrypted HTTP ("Application Data")
EOF

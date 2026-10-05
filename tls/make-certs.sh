#!/usr/bin/env bash
# Task E - build a tiny local Certificate Authority and a server certificate
# for app.<domain> / api.<domain>.  Run on Mac 2 (the edge).
#
#   tls/make-certs.sh          # create CA (once) + server cert
#   tls/make-certs.sh --force  # throw everything away and start again
#
# Output in tls/out/:
#   ca.key           CA private key        (SECRET - never commit, never copy)
#   ca.crt           CA certificate        (public - every client trusts this)
#   server.key       server private key    (SECRET - stays on Mac 2)
#   server.crt       server cert signed by our CA
#   server-chain.crt server.crt + ca.crt  (what nginx sends in the handshake)
set -euo pipefail
source "$(dirname "$0")/../scripts/common.sh"

# Prefer Homebrew OpenSSL 3 over macOS' LibreSSL if it exists (both work)
OPENSSL="$(ls /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl 2>/dev/null | head -1 || true)"
OPENSSL="${OPENSSL:-openssl}"

mkdir -p "$TLS_DIR"; cd "$TLS_DIR"
if [ "${1:-}" = "--force" ]; then rm -f ca.* server.* *.srl *.ext; fi

if [ ! -f ca.key ]; then
  say "Creating team root CA"
  "$OPENSSL" genrsa -out ca.key 2048
  cat > ca.ext <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = ${TEAM_NAME} Local Root CA
O  = ${TEAM_NAME}
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  "$OPENSSL" req -x509 -new -key ca.key -sha256 -days 825 -out ca.crt -config ca.ext
  chmod 600 ca.key
else
  ok "CA already exists - reusing it (use --force to recreate)"
fi

say "Creating server certificate for app.${DOMAIN}, api.${DOMAIN}"
"$OPENSSL" genrsa -out server.key 2048
chmod 600 server.key
"$OPENSSL" req -new -key server.key -subj "/CN=app.${DOMAIN}/O=${TEAM_NAME}" -out server.csr
# macOS only trusts TLS server certs that have a SAN, serverAuth EKU and a
# validity of <= 825 days, so all three are set explicitly.
cat > server.ext <<EOF
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:app.${DOMAIN}, DNS:api.${DOMAIN}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid, issuer
EOF
"$OPENSSL" x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 397 -sha256 -extfile server.ext
cat server.crt ca.crt > server-chain.crt

say "Verifying the chain"
"$OPENSSL" verify -CAfile ca.crt server.crt
"$OPENSSL" x509 -in server.crt -noout -subject -issuer -dates
"$OPENSSL" x509 -in server.crt -noout -text | grep -A1 "Subject Alternative Name"
echo
say "CA fingerprint - read this out loud / compare on every client after download:"
"$OPENSSL" x509 -in ca.crt -noout -fingerprint -sha256

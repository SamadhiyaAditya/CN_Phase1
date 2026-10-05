# TLS Certificate Setup Notes (Task E)

## What we built

A tiny **private certificate authority (CA)** of our own, plus one **server certificate** for `app.teamx.test` and `api.teamx.test` that the CA signed. nginx on the edge (Mac 2) presents that certificate. Every client Mac adds our CA to its trust store once. After that, the browser and curl accept the server **with full validation, and no `-k` anywhere**.

```
 teamX Local Root CA   (ca.crt / ca.key)      ← trusted by every client Mac
          │ signs
          ▼
 app.teamx.test         (server.crt / server.key)  ← nginx sends this in the handshake
   SAN: DNS:app.teamx.test, DNS:api.teamx.test
```

## Commands (all wrapped in `tls/make-certs.sh`)

```bash
# 1. CA key + self-signed CA certificate (CA:TRUE, can sign certs)
openssl genrsa -out ca.key 2048
openssl req -x509 -new -key ca.key -sha256 -days 825 -out ca.crt -config ca.ext

# 2. Server key + certificate signing request
openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "/CN=app.teamx.test" -out server.csr

# 3. CA signs the CSR, adding SAN + serverAuth
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 397 -sha256 -extfile server.ext

# 4. Check
openssl verify -CAfile ca.crt server.crt      # → server.crt: OK
```

Why these exact options? Modern macOS (and Chrome) refuse a server certificate that:
- has no **Subject Alternative Name**. The CN alone is ignored nowadays.
- lacks **Extended Key Usage = serverAuth**
- is valid for **more than 825 days** (we use 397)

## nginx side

```nginx
listen 443 ssl;  http2 on;
ssl_certificate     tls/out/server-chain.crt;   # server cert + CA cert
ssl_certificate_key tls/out/server.key;
ssl_protocols       TLSv1.2 TLSv1.3;
```

## Client side (trust the CA)

```bash
scripts/trust-ca.sh
# = curl http://app.teamx.test/ca.crt -o tls/out/ca.crt
#   compare SHA-256 fingerprint with the one the edge (Mac 2) printed   ← stops a fake CA
#   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain tls/out/ca.crt
```

Safari and Chrome use the macOS keychain, so they trust it right away (restart the browser). Firefox has its own store: Settings → Privacy & Security → Certificates → Import.
If a curl build doesn't read the keychain, our scripts pass `--cacert tls/out/ca.crt`. That is still **complete** verification against our CA. It's the opposite of `-k`, which turns verification off.

**Undo after the project:** `scripts/trust-ca.sh remove`

## What "certificate validation" actually checks

1. The server's certificate chain leads up to a CA that is in **my** trust store (our root CA).
2. Each signature in the chain is valid, so nobody altered the certificate.
3. The name I typed (`app.teamx.test`) appears in the certificate's SAN list.
4. Today's date is inside the validity period.
5. The server proves it owns the matching **private key** by signing the handshake (CertificateVerify in TLS 1.3, ServerKeyExchange in TLS 1.2). Copying `server.crt` alone is useless without `server.key`.

If you type the IP (`https://<Mac 2 IP>`), check 3 fails because the IP isn't in the SAN. That's one more reason the demo always uses the name.

## The handshake (what we point at in Wireshark)

TLS 1.2 (what `scripts/capture.sh` uses by default, because every step is visible):

| # | Direction | Message | Meaning |
|---|---|---|---|
| 1 | C → S | **ClientHello** | TLS versions, cipher suites, random, **SNI = app.teamx.test**, ALPN = h2,http/1.1 |
| 2 | S → C | **ServerHello** | Picked version + cipher + ALPN, server random |
| 3 | S → C | **Certificate** | server.crt + ca.crt. The client validates it now. |
| 4 | S → C | ServerKeyExchange | ECDHE public key, **signed** with server.key |
| 5 | S → C | ServerHelloDone | |
| 6 | C → S | ClientKeyExchange | Client's ECDHE public key. Both sides now compute the same secret. |
| 7 | C → S | **ChangeCipherSpec** + Finished | "Everything I send from now on is encrypted" |
| 8 | S → C | **ChangeCipherSpec** + Finished | Same from the server. Handshake complete. |
| 9 | both | **Application Data** | The HTTP request/response, encrypted |

TLS 1.3 (what browsers use normally) has 1 round trip instead of 2. Everything after ServerHello, **including the Certificate**, is already encrypted, so Wireshark shows it as "Application Data" unless you load the key log file (`evidence/pcap/sslkeys-*.log`).

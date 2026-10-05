# Private Network Service Platform: CN Project, Phase 1

A client types `https://app.teamx.test`. **Our own DNS server** resolves the name, the connection goes over **HTTPS to our own nginx edge**, and the edge **load-balances** the request across **two backend servers**. Every step is captured with dig, curl, Wireshark and the browser, on three real MacBooks on one Wi-Fi.

> The application stays simple. The network is the project.

## Team

**Team name:** `teamx` · **Section:** `D` · **Infrastructure:** three physical MacBooks on the same Wi-Fi, four roles (PDF section 3: *"Teams of 2–3 may combine machine roles"*)

| Enrollment no. | Name | Mac | Roles |
|---|---|---|---|
| 2401010514 | Yash Raj | Mac 1, 10.7.26.168 | DNS server (dnsmasq), test client |
| 2401010515 | Yash Yadav | Mac 2, 10.7.25.181 | Edge (nginx reverse proxy, TLS, load balancer), Backend A |
| 2401010037 | Aditya Samadhiya | Mac 3, 10.7.23.23 | Backend B, test client, Wireshark capture |

## Topology

```
                 Same Wi-Fi  (255.255.224.0, gateway 10.7.0.1)
  Mac 1 10.7.26.168            Mac 2 10.7.25.181                 Mac 3 10.7.23.23
  ┌───────────────┐            ┌───────────────────────────┐     ┌──────────────────┐
  │ dnsmasq :53   │◀── DNS ────│                           │     │ client: browser, │
  │ client        │            │ nginx :80/:443  (edge)    │◀────│ curl, Wireshark  │
  └───────────────┘◀───────────┼───────── DNS ─────────────┼─────│                  │
                               │  ├─ HTTP ▶ Backend A :3001│     │                  │
                               │  └─ HTTP ─────────────────┼────▶│ Backend B :3002  │
                               └───────────────────────────┘     └──────────────────┘
```

1. **DNS:** a client asks Mac 1 (`10.7.26.168:53/UDP`) for `app.teamx.test` → answer: Mac 2's IP, TTL 60.
2. **HTTPS:** the client connects to Mac 2 `:443`; the certificate is signed by our own CA.
3. **Load balancing:** nginx decrypts and forwards plain HTTP in round robin to Backend A (Mac 2 `:3001`) or Backend B (Mac 3 `:3002`).

Diagrams, the IP table and the layer-by-layer flow: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repository layout

```
team.env           ← the ONLY config file: team id, the 3 IPs, ports
backend/server.py  ← the REST backend (stdlib Python, no installs)
dns/               ← dnsmasq template (+ the exact config we ran: dnsmasq.conf.example)
edge/              ← nginx template (+ the exact config we ran: nginx.conf.example)
tls/make-certs.sh  ← local CA + server certificate (OpenSSL)
scripts/           ← one script per job (DNS, edge, backends, client setup, verify, capture, failures)
docs/              ← architecture, TLS, caching, failure demos
evidence/          ← inventory, text output, failure runs, pcap, screenshots
```

## How to run it (three Macs)

All 3 Macs on the **same Wi-Fi**, macOS firewall **off**, Homebrew installed. `brew install dnsmasq` on Mac 1, `brew install nginx` on Mac 2, Wireshark on Mac 3. Put the 3 IPs in `team.env` (identical on all Macs). Run everything inside `cn-phase1`.

```bash
# all Macs (Task A)
scripts/inventory.sh "Mac N - role" && scripts/ping-matrix.sh

# Task C - backends, each in its own terminal, left running
scripts/backend.sh run A          # Mac 2, port 3001
scripts/backend.sh run B          # Mac 3, port 3002
#   same thing without the script:  python3 backend/server.py --name A --port 3001

# Mac 2 - certificate + nginx edge (Tasks D, E)
scripts/edge.sh certs && scripts/edge.sh start && scripts/edge.sh status

# Mac 1 - DNS server (Task B)
scripts/dns.sh start

# Mac 1, Mac 2, Mac 3 - use our DNS;  Mac 1 + Mac 3 - trust our CA and verify
scripts/client-dns.sh use
scripts/trust-ca.sh
scripts/verify.sh
scripts/capture.sh                # Mac 3: one full DNS→TCP→TLS→HTTP request into a pcap
scripts/failure-demo.sh 1         # … 5  (Mac 3)

# when finished (every Mac that ran them)
scripts/client-dns.sh restore && scripts/trust-ca.sh remove
```

## Backend API

| Endpoint | Response | Caching |
|---|---|---|
| `GET /` | HTML page saying which backend answered (A = blue, B = green) | `no-store` |
| `GET /api/status` | `{"backend":"A","status":"ok", ...}` | `no-store` |
| `GET /api/info` | Same JSON on both backends | `Cache-Control: public, max-age=60` + `ETag`, `If-None-Match` → **304** |
| `GET /healthz` | `ok` | `no-store` |

Every response carries **`X-Backend: A`** or **`X-Backend: B`**.

## Phase 1 checklist → where the proof is (`evidence/screenshots/`)

| Task | Evidence |
|---|---|
| A: Private LAN | `01`–`06` (each Mac: IP, mask, gateway, MAC, ping matrix), `evidence/inventory/` |
| B: Private DNS | `12` (DNS server answer), `13`, `14` (Mac 3 and Mac 2 resolve through Mac 1), `23` (Wireshark) |
| C: Two backends | `07`, `08` |
| D: Reverse proxy + LB | `10`, `11`, `17`, `18`, `19` |
| E: HTTPS / TLS | `09`, `15`, `16`, `20`, `26`–`28` |
| F: HTTP caching | `21`, `22` |
| G: Full protocol flow | `evidence/pcap/`, `23`–`30` |
| 6.3: Failure demos | `31`–`35`, `evidence/failures/` |

# Failure Demonstrations (PDF section 6.3)

We ran every scenario from the **client (Mac 3)** with `scripts/failure-demo.sh 1 … 5`. When the script pauses, you break something on the other Mac. Screenshots 31–35 show each run, and the full text output is in `evidence/failures/`.

Every scenario uses the same three probes, so you can see exactly **which layer** broke:
`dig app.teamx.test` (DNS) → `ping 10.7.25.181` (IP) → `curl https://app.teamx.test/api/status` (TCP + TLS + HTTP).

| # | What we break | How | DNS | IP ping | Service | What it proves |
|---|---|---|---|---|---|---|
| F1 | Wrong DNS server on the client | `client-dns.sh set 10.7.23.23` (a machine with no DNS server) | ✗ times out | ✓ | ✗ `Could not resolve host` / resolving timed out | DNS and IP are independent. The network is fine, only the name lookup is broken. |
| F2 | DNS record points to a wrong IP | on Mac 1 `dns.sh wrong-record` (app → 10.7.23.23) | ✓ but **wrong IP** | ✓ | ✗ `Connection refused` on 10.7.23.23:443 | DNS is only a directory. It gives an address and has no idea if anything is listening there. |
| F3 | One backend stopped | Ctrl+C Backend A on Mac 2 | ✓ | ✓ | ✓ 200, every reply `X-Backend: B` | The edge hides backend failure: nginx retries on B (`proxy_next_upstream`) and skips A for 10 s. |
| F4 | Both backends stopped | Ctrl+C Backend B on Mac 3 too | ✓ | ✓ | TLS handshake ✓ (`certificate verify ok`), then **502 Bad Gateway** | DNS, TCP and TLS all end at the edge, so they still work. The 502 comes from nginx itself: "I'm fine, my upstream isn't." That's the line between edge and backend. |
| F5 | Wrong destination port | `curl https://app.teamx.test:444` | ✓ | ✓ | ✗ `Connection refused` (TCP RST) | The IP picks the machine and the port picks the program. Nothing listens on 444, so the OS rejects the SYN. |

## Explanations in plain words

**F1: Wrong DNS server.** The client sends its DNS question to 10.7.23.23, a machine with no DNS server running. Nobody answers, so the lookup times out. But `ping 10.7.25.181` and `nc -vz 10.7.25.181 443` still work, because they skip DNS completely. So the Wi-Fi, IP and TCP are all fine. Only the "phone book" is missing.

**F2: Record points to a wrong IP.** `dig` happily returns an answer. It's just the wrong one (10.7.23.23). curl then opens a TCP connection to that address, and that Mac has nothing on port 443, so it replies with a TCP RST ("connection refused"). If that machine *did* run a web server, you'd reach the wrong service, or get a certificate name mismatch. DNS never checks whether the address actually works.

**F3: One backend down.** nginx tries Backend A, gets "connection refused" within milliseconds, and since `proxy_next_upstream error` is set, it sends the **same request** to B. The client just sees a normal 200. A is marked failed for `fail_timeout=10s`, so the next requests go straight to B. After A comes back, round robin resumes on its own once the 10 s are up.

**F4: Both backends down.** The client still resolves the name, still completes the TCP handshake, and still gets a valid certificate (`SSL certificate verify ok`). All of that is the edge's job, and the edge is healthy. Only when nginx tries to forward the request does it find nobody behind it, so it answers **502 Bad Gateway**. After restarting the backends, wait about 10 s (fail_timeout) before traffic flows again.

**F5: Wrong port.** Same host, same IP, and ping works. But TCP connections are addressed to IP **and** port. The kernel on Mac 2 has no socket listening on 444, so it answers the SYN with RST. Port 443 on the same IP connects fine.

## Observed results (our run, client = Mac 3)

| # | Observed | Evidence |
|---|---|---|
| F1 | DNS timed out, ping and IP connectivity worked, curl "Resolving timed out", then restored to HTTP 200 | `screenshots/31-failure-F1-wrong-dns.png` |
| F2 | DNS returned wrong IP (10.7.23.23), curl "Connection refused" on port 443, then fixed to HTTP 200 | `screenshots/32-failure-F2-wrong-record.png` |
| F3 | All 6 requests returned HTTP 200 with X-Backend: B (nginx retried on B after A failed) | `screenshots/33-failure-F3-one-backend-down.png` |
| F4 | DNS OK, ping OK, TLS handshake OK, then HTTP 502 Bad Gateway from nginx | `screenshots/34-failure-F4-both-down-502.png` |
| F5 | Port 443 succeeded, port 444 "Connection refused" | `screenshots/35-failure-F5-wrong-port.png` |

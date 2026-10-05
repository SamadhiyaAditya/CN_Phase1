#!/usr/bin/env python3
"""
Tiny REST backend for the CN Phase 1 project.

Same file runs as Backend A (Mac 3, port 3001) and Backend B (Mac 4, port 3002):

    python3 backend/server.py --name A --port 3001
    python3 backend/server.py --name B --port 3002

Only the Python standard library is used - nothing to install.

Endpoints
    GET /            small HTML page that says which backend answered
    GET /api/status  JSON  {"backend": "A", "status": "ok", ...}   (never cached)
    GET /api/info    JSON that is IDENTICAL on A and B, sent with
                     Cache-Control: public, max-age=60 and an ETag, and answers
                     "If-None-Match" with 304 Not Modified   (Task F caching)
    GET /healthz     plain "ok" (handy for health checks)

Every response carries   X-Backend: A   (or B)   so the load balancing is
visible from curl / browser dev tools.
"""

import argparse
import datetime
import hashlib
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Content of /api/info. It must be byte-for-byte the same on both backends so
# that both compute the same ETag - otherwise a 304 from A would turn into a
# full 200 whenever the load balancer sends the next request to B.
INFO_DOC = {
    "service": "private-network-service-platform",
    "version": "1.0.0",
    "message": "This document is cacheable. Ask again with If-None-Match to get a 304.",
    "max_age_seconds": 60,
}
INFO_BODY = (json.dumps(INFO_DOC, indent=2) + "\n").encode()
INFO_ETAG = '"' + hashlib.sha256(INFO_BODY).hexdigest()[:16] + '"'

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{team} - Backend {name}</title>
<style>
 body{{font-family:-apple-system,Segoe UI,sans-serif;background:{bg};color:#fff;
      display:flex;min-height:100vh;margin:0;align-items:center;justify-content:center}}
 .card{{text-align:center}} h1{{font-size:96px;margin:0}} p{{opacity:.85;margin:.4em}}
 code{{background:rgba(0,0,0,.25);padding:2px 6px;border-radius:4px}}
</style></head>
<body><div class="card">
 <p>{team}</p>
 <h1>Backend {name}</h1>
 <p>served by <code>{host}</code> on port <code>{port}</code></p>
 <p>your request came in via <code>{client}</code></p>
 <p>refresh the page - the load balancer should alternate A / B</p>
</div></body></html>
"""


def now_http():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"          # keep-alive + Content-Length
    server_version = "cn-backend/1.0"
    sys_version = ""

    # ---- helpers ---------------------------------------------------------
    def _send(self, status, body=b"", ctype="application/json", extra=None):
        self.send_response(status)
        self.send_header("X-Backend", self.server.backend_name)
        if body or status != 304:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)) if status != 304 else "0")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD" and status != 304:
            self.wfile.write(body)

    def _json(self, status, obj, extra=None):
        self._send(status, (json.dumps(obj, indent=2) + "\n").encode(), extra=extra)

    def _client(self):
        # nginx adds X-Forwarded-For / X-Real-IP; the TCP peer is the edge itself
        return self.headers.get("X-Real-IP") or self.client_address[0]

    # ---- routes ----------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        name = self.server.backend_name

        if path == "/":
            body = PAGE.format(
                team=self.server.team, name=name, host=socket.gethostname(),
                port=self.server.server_address[1], client=self._client(),
                bg="#2563eb" if name == "A" else "#16a34a" if name == "B" else "#7c3aed",
            ).encode()
            self._send(200, body, "text/html; charset=utf-8", {"Cache-Control": "no-store"})

        elif path == "/api/status":
            self._json(200, {
                "backend": name,
                "status": "ok",
                "host": socket.gethostname(),
                "listen_port": self.server.server_address[1],
                "tcp_peer": f"{self.client_address[0]}:{self.client_address[1]}",
                "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                "x_forwarded_proto": self.headers.get("X-Forwarded-Proto"),
                "host_header": self.headers.get("Host"),
                "served_at": now_http(),
            }, {"Cache-Control": "no-store"})

        elif path == "/api/info":
            cache = {"Cache-Control": "public, max-age=60", "ETag": INFO_ETAG}
            inm = self.headers.get("If-None-Match", "")
            tags = [t.strip() for t in inm.split(",") if t.strip()]
            if "*" in tags or INFO_ETAG in tags or ("W/" + INFO_ETAG) in tags:
                self._send(304, extra=cache)          # conditional request hit
            else:
                self._send(200, INFO_BODY, extra=cache)

        elif path == "/healthz":
            self._send(200, b"ok\n", "text/plain", {"Cache-Control": "no-store"})

        else:
            self._json(404, {"backend": name, "error": "not found", "path": path})

    do_HEAD = do_GET

    def log_message(self, fmt, *args):
        sys.stdout.write("%s [backend %s] peer=%s:%s xff=%s \"%s\"\n" % (
            datetime.datetime.now().strftime("%H:%M:%S"), self.server.backend_name,
            self.client_address[0], self.client_address[1],
            self.headers.get("X-Forwarded-For", "-") if hasattr(self, "headers") else "-",
            fmt % args))
        sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser(description="CN project backend")
    ap.add_argument("--name", default=os.environ.get("BACKEND_NAME", "A"), help="A or B")
    ap.add_argument("--port", type=int, default=int(os.environ.get("BACKEND_PORT", 3001)))
    # 0.0.0.0 = every interface. Binding 127.0.0.1 would make the backend
    # invisible to Mac 2, which is exactly the mistake Task C warns about.
    ap.add_argument("--host", default=os.environ.get("BACKEND_HOST", "0.0.0.0"))
    ap.add_argument("--team", default=os.environ.get("TEAM_NAME", "Team X"))
    a = ap.parse_args()

    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    srv.backend_name = a.name.upper()
    srv.team = a.team
    srv.daemon_threads = True
    print(f"Backend {srv.backend_name} listening on {a.host}:{a.port}  (Ctrl+C to stop)", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")


if __name__ == "__main__":
    main()

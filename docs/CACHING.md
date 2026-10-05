# HTTP Caching (Task F)

`GET /api/info` returns the same document from both backends with:

```
Cache-Control: public, max-age=60
ETag: "8e637a1a8a261c8e"          ← a hash of the response body
```

`scripts/verify.sh cache` shows the whole sequence:

```
$ curl -I https://app.teamx.test/api/info
HTTP/2 200
cache-control: public, max-age=60
etag: "8e637a1a8a261c8e"
x-backend: A

$ curl -I -H 'If-None-Match: "8e637a1a8a261c8e"' https://app.teamx.test/api/info
HTTP/2 304                        ← no body sent, "you already have it"
etag: "8e637a1a8a261c8e"
x-backend: B                      ← works from either backend (same content, same hash)
```

In the browser: open DevTools → Network, load `https://app.teamx.test/api/info`, then reload. You'll see `(disk cache)` / `(memory cache)` within 60 s. A hard refresh (⌘⇧R) sends `If-None-Match` and you'll see **304**.

## The three cases

| Case | What happens on the network | Status | When |
|---|---|---|---|
| **Fresh cache hit** | **Nothing.** The browser uses its stored copy without asking. | (from cache) | Within `max-age` (60 s) |
| **Conditional request** | Small request with `If-None-Match: <etag>`, small reply with **no body** | **304 Not Modified** | Copy expired (stale), or user reloads. The server confirms it hasn't changed. |
| **Full new request** | Full request, full body downloaded | **200 OK** | No cached copy, content changed (new ETag), or `no-store` |

`/api/status` and `/` deliberately send `Cache-Control: no-store`. They show live data (which backend, the time), so caching them would be wrong. It would also hide the load balancing in the browser.

Link to CDNs: a CDN edge (CloudFront, Cloudflare) follows exactly these headers. `max-age` decides how long it can serve a copy without asking the origin, and ETags let it revalidate cheaply.

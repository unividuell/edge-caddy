# edge-caddy — shared TLS edge for unividuell.org

The single Caddy that binds **80/443** on the host and reverse-proxies by hostname to
each project. It is the only process allowed on those ports. Every app runs as its own
stack and joins the external Docker network **`edge`**; the edge reaches each app by its
stable `container_name`. TLS terminates here — apps speak plain HTTP behind it.

Server dir: **`/opt/unividuell/edge-caddy/`**. Images are pulled from Docker Hub
(`caddy:2-alpine`, public — no ghcr login needed for the edge itself).

## Routes
| Domain | Upstream container |
| --- | --- |
| `countdown.unividuell.org` | `countdown-web:80` |
| `mobility.unividuell.org` | `mobility-manager:8080` |
| `news.zingler46.unividuell.org` | `comunio-news-app:8080` (basicauth) |

## Bootstrap (first time)
```bash
mkdir -p /opt/unividuell/edge-caddy && cd /opt/unividuell/edge-caddy
curl -fsSL https://raw.githubusercontent.com/unividuell/edge-caddy/main/update.sh -o update.sh && chmod +x update.sh
./update.sh          # fetches compose.yaml + Caddyfile + a .env template, then stops
# edit .env: set BASIC_AUTH_HASH (see below)
./update.sh          # creates the edge network, pulls caddy, starts the edge
```

`BASIC_AUTH_HASH` is a bcrypt hash shared by the two news users:
```bash
docker run --rm caddy:2-alpine caddy hash-password --plaintext '<password>'
```

## Update (route/infra changes)
```bash
cd /opt/unividuell/edge-caddy && ./update.sh
```
Re-fetches `compose.yaml`, `Caddyfile`, `README.md`, and itself from `main`, ensures the
`edge` network, then `docker compose pull && up -d`.

## Add a new site
1. Add a site block to `Caddyfile`: `<domain> { reverse_proxy <container_name>:<port> }`.
2. Make sure the app's compose attaches that container to the external `edge` network with
   a stable `container_name` and **publishes no host ports**.
3. Commit, then on the server `./update.sh`. Caddy obtains the cert on first request.

## Certs
Caddy stores certs/ACME state in the `caddy-data` volume. A fresh volume triggers
Let's Encrypt issuance for every domain on first request — well within rate limits for
three domains. DNS for each domain must already point at this host and 80/443 must be open.

# Wildcard certificate and wildcard DNS for unividuell.org

**Status:** Draft (2026-11-17)
**Repo:** `github.com/unividuell/edge-caddy`
**Server dir:** `/opt/unividuell/edge-caddy/`

## Why

Every new site needs two things today: its own Cloudflare A record, and its own Let's
Encrypt certificate. The certificate lands in the public Certificate Transparency logs,
and bots read them live:

- `prueffahrt.unividuell.org` got its certificate on 2026-09-28 at 16:09:54. A crawler
  requested `/` in the same second; CT receives the precertificate before Caddy has the
  final one. A scanner tried `/.env`, `/.env.backup` and `/.env.save` 30 s later. The site
  has had 6,270 requests since, and it is a page meant for friends.
- Every renewal is a new CT entry, so the same wave comes back for every existing name
  about every 60 days.

## Goals

- A new one-label site (`<name>.unividuell.org`) needs only a Caddyfile site block. It
  needs no DNS record, and its name appears in no CT log.
- The existing one-label sites move to the wildcard certificate, so their renewals stop
  pushing them back into the CT stream.
- Two-label names go away, so the wildcard covers every name.
  - `news.zingler46.` is removed from the edge now: its site block and its basic-auth
    variables. The parked comunio-news stack on the server stays as it is. If it comes
    back, it gets a one-label name.
  - `beta.countdown.` moves to a one-label name in the countdown project, separately and
    soon. This change leaves it alone.

## Non-goals

- Hiding the names already issued. `countdown`, `beta.countdown`, `mobility`,
  `news.zingler46`, `stats`, `files`, `prueffahrt` and `monitoring` stay on crt.sh, and
  the bots that know them stay too.
- Renaming `beta.countdown.`. `*.unividuell.org` covers exactly one label, so until the
  countdown project moves it, it keeps its own HTTP-01 certificate, as today.
- The apex `unividuell.org`, which nothing serves today.
- Stopping the other ways a name is found: IP scans, wordlists, passive DNS, chat link
  previews. Authentication stays the actual protection.

## Anti-goals

- A third-party Caddy image holding every TLS key and the DNS token.
- Renewals failing silently. With one certificate, a broken token takes every one-label
  site down at the same time.

## Constraints

- Nothing on the server is in production use (as of 2026-11-17). A short outage during
  the switch is acceptable.
- Let's Encrypt issues wildcards only through DNS-01, and the official `caddy:2-alpine`
  has no DNS provider module. `dns-persist-01` would need neither a token nor a plugin,
  but Caddy does not support it yet (caddyserver/caddy#7495, open), and its production
  rollout at Let's Encrypt is frozen.
- The host runs Caddy v2.11.9 on aarch64. Since 2.10, Caddy uses a managed wildcard
  certificate for every site block it covers instead of ordering one certificate per name.
  `tls force_automate` opts a block out.
- `update.sh` pulls everything from `main`. Its validation gate runs `caddy validate` in
  the compose service's image.
- Cloudflare API tokens are scoped to a zone, not to single records.

## Approaches

### How the certificate is obtained

- **DNS-01 through the Cloudflare plugin and a scoped token (chosen).** Caddy obtains and
  renews the certificate itself, and there is only one component. The token can only edit
  DNS in one zone, and only from the server's IP.
- **Cloudflare proxy with an Origin CA certificate.** This is the only path that needs
  neither a token, nor a custom build, nor renewals: Cloudflare's edge certificate lists
  only `unividuell.org` and `*.unividuell.org`, and the origin certificate on the server is
  valid for 15 years and never appears in CT. Rejected, for these reasons:
  - Cloudflare terminates TLS. It sees all traffic in plaintext, including basic-auth
    passwords and files, and every visitor's IP. The prueffahrt fonts are self-hosted to
    keep visitor IPs away from Google; this would hand them to Cloudflare for every site.
  - Cloudflare caches PDFs and images by default, which breaks deleting a file on `files.`
    to revoke its link.
  - Caddy would need Cloudflare's IP ranges as `trusted_proxies` to log real client IPs.
- **`lego` with Google Trust Services and `dns-persist-01`.** Google has supported this in
  production since 2026-09-28, wildcards included, so one TXT record set once would
  replace the token. Rejected, for these reasons:
  - It needs a Google Cloud project for the EAB key.
  - `lego` becomes a second component with its own renewal timer and `caddy reload`, and
    Caddy no longer manages the certificate itself.
  - Google implements draft-01 while draft-02 is current, and warns that early adopters may
    need to update their records.
- **Cloudflare Tunnel.** No open ports at all, but it puts a tunnel token on the server
  and means a much larger rebuild. Rejected.
- **An external ACME client using the Cloudflare token.** The token stays; only the build
  is saved. Rejected.
- **`dns-persist-01` in Caddy itself.** This would be the best end state: the official
  image and one TXT record. It is not possible yet (see constraints).

### Where the Caddy image is built

- **On the server (chosen).** A `Dockerfile` builds Caddy with
  `xcaddy --with github.com/caddy-dns/cloudflare` on `caddy:2-builder` and copies the
  binary onto `caddy:2-alpine`. `update.sh` fetches the `Dockerfile` and builds the image
  before the validation gate. This needs no registry and no CI. The existing gate then
  checks the Caddyfile against the new binary, so a Caddyfile that needs the plugin can
  never be deployed with an image that lacks it. Cost: a build of about 1–2 minutes per
  update, with Go modules fetched at build time.
- **GitHub Actions pushing to ghcr.** The server would keep only pulling, but this needs a
  workflow, a registry, and a schedule so that Caddy updates still arrive. Rejected: too
  many moving parts for one host.
- **A third-party prebuilt image with the plugin.** Rejected (see anti-goals).

### Later

- When Caddy supports `dns-persist-01` (caddyserver/caddy#7495) with a CA that has it in
  production, switch to it. That drops the plugin, the custom build and the token, and
  leaves one TXT record.
- Once `beta.countdown.` has its one-label name:
  - Remove its site block and its A record. After that, every name is under the wildcard.
  - The individual A records can then go too, leaving only `*`. Not before: while
    `beta.countdown` has a record, `countdown` without its own record would be an empty
    node, and the wildcard does not answer for empty nodes.

## Design

- **DNS (you, in Cloudflare):**
  - `*.unividuell.org A 158.101.161.126`, unproxied.
  - The existing A records stay for now (see "Later"). Explicit records win over the
    wildcard, and they point to the same IP.
  - No record for `news.zingler46.`. The wildcard resolves it to the server, but with no
    site block and no certificate for it, HTTPS fails in the TLS handshake (`tlsv1 alert
    internal error`). Plain HTTP gets the `308` to https that every unknown host gets
    today, with one access-log line (both verified on the server, 2026-11-17). A TXT
    tombstone would keep the name unresolved. Skipped as a special case that is not worth
    keeping.
- **Token (you, in Cloudflare):**
  - Scope: Zone → DNS → Edit and Zone → Zone → Read (the plugin needs both), only for
    `unividuell.org`, with a client IP filter on `158.101.161.126`.
  - It goes into `.env` as `CLOUDFLARE_API_TOKEN`. The `update.sh` preflight requires it,
    and `.env.example` and the README document it.
- **Caddy image:** the `Dockerfile` above. Compose builds this image instead of pulling
  `caddy:2-alpine`.
  - Caddy and the plugin both track their latest release: `caddy:2-builder` and
    `caddy:2-alpine`, and the plugin without a version. `update.sh` rebuilds with `--pull`
    on every run, so security fixes arrive with every update.
  - If the latest Caddy and the latest plugin do not fit together, the build or
    `caddy validate` fails, and `update.sh` aborts before anything is changed.
- **Caddyfile:**
  - A new `*.unividuell.org` block with `tls { dns cloudflare … }`. It aborts, so every
    name without a block of its own gets a TLS handshake and a closed connection.
  - The `news.zingler46.` block goes, and with it `NEWS_AUTH_USER_1`, `NEWS_AUTH_USER_2`
    and `NEWS_AUTH_HASH` in `compose.yaml`, the `update.sh` preflight, `.env.example` and
    the README.
  - The lines in the server's `.env` may stay; nothing reads them. A revival would reuse
    them.
  - The other blocks stay as they are.
- **Rollout in one deploy, as a hard switch.** Until Caddy has obtained the wildcard, the
  one-label sites may answer without a certificate. That is acceptable (see constraints).
- **Alert:** a Grafana alert when certificate renewal fails, sent through the existing
  mail contact point.
- **Docs:**
  - README: "Add a new site" (no DNS step, one-label names only), the bootstrap section
    and the `.env` table.
  - The memory note on the DNS setup.

## Left to the builder

- How the alert detects a failing renewal. Two options: the certificate's remaining time,
  if the bundled collector's `httpcheck` receiver has a TLS metric, or shipping
  `system.log` to Loki and alerting on `tls` errors.
- The placeholder form for the token (`{env.…}` or `{$…}`), and how `caddy validate`
  behaves with it.
- How compose's `pull` and `build` interact for the caddy service (`pull_policy`,
  `--ignore-buildable`).

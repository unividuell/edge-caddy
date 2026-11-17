# The edge image: caddy:2-alpine plus the Cloudflare DNS provider, which the *.unividuell.org
# wildcard certificate needs (Let's Encrypt issues wildcards only through DNS-01, and the
# official image ships no DNS provider). Built on the server by update.sh, never pushed.
#
# Both base images and the plugin follow their latest release, for the security fixes.
# update.sh resolves the plugin's latest version and passes it in, so a new plugin release
# busts the build cache the way `build --pull` does for a new Caddy.
FROM caddy:2-builder AS builder
ARG CF_PLUGIN_VERSION=latest
RUN xcaddy build --with github.com/caddy-dns/cloudflare@${CF_PLUGIN_VERSION}

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

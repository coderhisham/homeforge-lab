# Caddy (core — reverse proxy + automatic TLS)

## What it does

Caddy is the single entrypoint for every web-facing service in your stack. It
terminates HTTPS and reverse-proxies requests to the right container. Its
defining feature here: it obtains real TLS certificates for your box's
**Tailscale MagicDNS name** (`*.ts.net`) automatically, by talking to the local
`tailscaled` — no ACME setup, no public domain, and no ports opened to the
internet.

As you add services (n8n, Grafana, …), their modules drop a site block into
`modules/caddy/conf.d/` and Caddy proxies them at `service.<host>.ts.net`.

## Prerequisites

In the [Tailscale admin console](https://login.tailscale.com/admin/dns), enable:

- **MagicDNS**
- **HTTPS Certificates** ("Enable HTTPS")

Without these, Caddy can't fetch a `*.ts.net` certificate. Tailscale must be up
on the box first (the access layer handles that).

## How it works

- The site address in the `Caddyfile` is `{$FORGE_TS_HOSTNAME}` — your box's
  MagicDNS name, which `forge.sh` detects from `tailscale status` and passes in.
- The compose file mounts `/var/run/tailscale/tailscaled.sock` into the
  container. Caddy (running as root in its image) uses it to fetch and renew the
  certificate. Renewal is automatic.
- Caddy joins the `forge_public` Docker network; proxied services share it.
- Certs and state persist in the `forge_caddy_data` volume — don't delete it or
  Caddy re-requests certificates on next start.

## How to verify

```bash
# Container healthy?
./modules/caddy/healthcheck.sh
# or
docker ps --filter name=forge_caddy

# From a device on your tailnet:
curl -sS https://<your-host>.<tailnet>.ts.net/healthz    # -> ok
```

`forge.sh status` also reports Caddy's health.

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| TLS cert never issues | MagicDNS or HTTPS Certificates not enabled in the tailnet admin; or Tailscale not up. Enable both, confirm `tailscale status`, restart Caddy. |
| `tailscaled.sock` not found | The socket path differs or Tailscale isn't installed on the host. Confirm `/var/run/tailscale/tailscaled.sock` exists; restart Caddy after Tailscale is up. |
| Healthcheck fails but site loads | The image may lack `wget`. Swap the healthcheck to `curl` or the caddy admin binary — see the compose file comment. |
| 404 for a service subdomain | That service's `conf.d/*.caddy` block isn't present yet, or Caddy wasn't reloaded. Re-run its module. |
| Port 80/443 already in use | Another web server is bound. Stop it, or remap Caddy's published ports. |

## Update strategy

Caddy carries the `com.centurylinklabs.watchtower.enable=true` label, so
Watchtower auto-updates it (it's stateless-ish — certs live in a volume). To pin
a version, change the image tag in `docker-compose.yml`.

## Backup / restore

The only state is the `forge_caddy_data` volume (certificates + config). Back it
up with the stack's Restic setup, or manually:

```bash
docker run --rm -v forge_caddy_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/caddy_data.tgz -C /data .
```

Restore by extracting the tarball back into the volume before starting Caddy.
Losing it is non-fatal — Caddy simply re-requests certificates.

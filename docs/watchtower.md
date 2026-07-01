# Watchtower (core — opt-in auto-updates)

## What it does

Watches your running containers and automatically updates the ones you've opted
in, pulling new images and recreating the container. In tuninforge it is
**scoped by label** so it never touches data you can't afford to lose to an
unattended upgrade.

## ⚠ The scoping model (read this)

Watchtower runs with `WATCHTOWER_LABEL_ENABLE=true`, which means it **only**
considers containers carrying:

```
com.centurylinklabs.watchtower.enable=true
```

tuninforge sets that label on **stateless** services and deliberately omits
it on **stateful** ones:

| Auto-updated (labeled) | Pinned — manual update only (no label) |
|---|---|
| Caddy, Portainer, Watchtower, n8n, Ollama, LiteLLM, Alloy, Grafana | Postgres, Redis, MinIO, Qdrant, Prometheus, Loki |

The pinned services hold your data. Update them deliberately, **after a backup**
(`scripts/backup.sh`), by bumping the image tag in their `docker-compose.yml`
and re-deploying.

## How to verify

```bash
./modules/watchtower/healthcheck.sh    # PASS = running (it's a poller; no HTTP port)
docker logs tuninforge_watchtower | tail    # shows what it's watching / last check
```

To confirm scoping is working, the logs list only labeled containers as
"watched" — Postgres/Redis/etc. should not appear.

## Configuration

`modules/watchtower/.env`:
- `WATCHTOWER_POLL_INTERVAL` — seconds between checks (default 86400 = daily).
- `WATCHTOWER_NOTIFICATION_URL` — optional shoutrrr URL for update reports.

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| Container restarting | Can't reach the Docker socket. Confirm the socket mount + daemon. `docker logs tuninforge_watchtower`. |
| A service didn't auto-update | It has no `watchtower.enable=true` label (by design if stateful), or no newer image exists. |
| A stateful service DID update | It shouldn't — verify its compose has no watchtower label. Report it. |
| Update broke a service | Pin that service's image tag to the previous version and re-deploy; consider removing its label. |

## Backup / restore

Nothing to back up — Watchtower is stateless. See [backup.md](backup.md) for the
data services it deliberately leaves alone.

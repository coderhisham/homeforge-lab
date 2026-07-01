# Loki (observability)

## What it does

Aggregates logs — the "Prometheus for logs." Promtail ships every container's
logs here, and you query them in Grafana. Uses **filesystem storage** (a local
volume) — the simplest setup for one homelab box, no object store required.

## Networking & safety

- `forge_internal` only — Promtail pushes to it, Grafana reads it, both
  privately. No public UI (you view logs through Grafana).
- **Not** auto-updated (stateful log store; no Watchtower label).

## How to verify

```bash
./modules/loki/healthcheck.sh       # PASS = /ready 2xx (503 until warmed up)
```

`/ready` returns 503 for the first ~30–60s while Loki initializes — that's
normal, not a failure.

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| `/ready` stuck at 503 | Still starting, or a config error. Check `docker logs forge_loki`. |
| Config parse error | Loki does NOT expand `${ENV}` vars in its config unless started with `-config.expand-env=true`. Values in `loki-config.yaml` are literal — edit them directly. |
| No logs appear in Grafana | Promtail isn't running or can't reach Loki. Check the promtail module. |
| Disk filling | Retention is 168h (7d) in `loki-config.yaml`. Lower it or grow the volume. |

## Backup / restore

`forge_loki_data` (chunks + index) is included in `scripts/backup.sh`. Log
history is typically non-critical — exclude it if you want smaller backups. See
[backup.md](backup.md).

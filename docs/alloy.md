# Alloy (observability — log collection)

## What it does

Grafana Alloy ships **all container logs to Loki with zero per-service
configuration**. It's the actively-maintained successor to Promtail (which
reached end-of-life on 2026-03-02). Alloy uses Docker service discovery to find
every running container automatically and forward its logs to Loki — so newly
added services show up in Grafana with no extra setup.

## Why Alloy instead of Promtail

Promtail is EOL: no more updates or security fixes, and Grafana has folded all
future log-collection work into Alloy. tuninforge uses Alloy so the logging
pipeline stays supported. It keeps the **same Loki labels** the old Promtail
config produced (`container`, `compose_project`, `compose_service`, and
`job="containers"`), so existing Grafana panels and LogQL queries work unchanged.

## How the zero-config discovery works

`config.alloy` defines a small pipeline:

1. `discovery.docker` — lists all containers via the mounted Docker socket.
2. `discovery.relabel` — turns Docker metadata into Loki labels.
3. `loki.source.docker` — reads each container's logs.
4. `loki.write` — pushes to `http://loki:3100/loki/api/v1/push`.

## Networking & safety

- `tuninforge_internal` — pushes to Loki privately. No published ports.
- Read-only Docker socket + container-log mounts (discovery + reading only), but
  note that socket access is inherently powerful.
- Stateless shipper (a WAL/positions dir persists) — Watchtower opt-in.

## How to verify

```bash
./modules/alloy/healthcheck.sh    # PASS = /-/ready 2xx
# Then in Grafana → Explore → Loki: query {job="containers"}
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| No logs in Loki | Alloy can't reach Loki, or the socket/log mounts are missing. Check `docker logs tuninforge_alloy`. |
| Config error on start | `config.alloy` syntax issue. Alloy prints the offending block; check `docker logs tuninforge_alloy`. |
| Some containers missing | They may use a non-json-file Docker log driver. Confirm the Docker log driver. |
| `pull` fails | Bump the `grafana/alloy` tag in the compose file to a current one from Docker Hub. |

## Backup / restore

Nothing meaningful to back up — Alloy holds only a positions/WAL bookmark. Logs
live in Loki. See [backup.md](backup.md).

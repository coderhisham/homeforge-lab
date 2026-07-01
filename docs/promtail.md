# Promtail (observability)

## What it does

Ships **all container logs to Loki with zero per-service configuration**. It uses
Docker service discovery (via the Docker socket) to find every running container
automatically and tail its logs — so newly added services show up in Grafana
with no extra setup.

## How the zero-config discovery works

- Mounts the Docker socket (read-only) to list containers, and
  `/var/lib/docker/containers` (read-only) to read their JSON log files.
- `docker_sd_configs` discovers containers; relabeling turns Docker metadata
  into Loki labels: `container`, `compose_project`, `compose_service`, `stream`,
  and a stable `job="containers"`.
- Everything is queryable in Grafana as `{job="containers"}`, or filtered like
  `{container="forge_postgres"}`.

## Networking & safety

- `forge_internal` — pushes to `loki:3100`. No published ports.
- Read-only Docker socket access (discovery only), but note that socket access
  is inherently powerful.
- Stateless shipper (only a positions file persists) — Watchtower opt-in.

## How to verify

```bash
./modules/promtail/healthcheck.sh    # PASS = /ready 2xx
# Then in Grafana → Explore → Loki: query {job="containers"}
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| No logs in Loki | Promtail can't reach Loki, or the socket/log mounts are missing. Check `docker logs forge_promtail`. |
| Some containers missing | They may log to a driver other than json-file. Promtail reads json-file logs; confirm the Docker log driver. |
| Permission denied on socket/logs | SELinux/AppArmor or path differences; confirm the read-only mounts exist on your host. |

## Backup / restore

Nothing to back up — Promtail only holds a positions file (a bookmark). Logs
live in Loki. See [backup.md](backup.md).

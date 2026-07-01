# Prometheus (observability)

## What it does

Collects and stores time-series metrics. In homelab-forge it ships as three
containers: **prometheus** (the TSDB + scraper), **node-exporter** (host CPU/
mem/disk/net), and **cAdvisor** (per-container CPU/mem/net/fs for every running
container). Grafana reads it for dashboards.

## Honest scope of "auto-discovery"

The spec asked for auto-scraping every service's exporter. Most stack images
(Postgres, Redis, …) don't expose Prometheus metrics without a **separate
exporter sidecar**, so there's nothing to scrape for them out of the box.
Rather than pretend otherwise, this module gives real box-wide observability
immediately via node-exporter + cAdvisor, and `prometheus.yml` includes
ready-to-enable stubs (and a Docker-SD template) for per-service exporters you
add later.

## Networking & safety

- `forge_internal` only — no published ports, not Caddy-fronted by default.
  (Expose the Prometheus UI via a Caddy block only if you want it.)
- **Not** auto-updated (stateful TSDB; no Watchtower label).

## How to verify

```bash
./modules/prometheus/healthcheck.sh                 # PASS = /-/healthy 2xx
# Targets up? (from a container on forge_internal)
docker run --rm --network forge_internal curlimages/curl:8.11.1 \
  -s http://forge_prometheus:9090/api/v1/targets | grep -o '"health":"[a-z]*"'
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| cAdvisor won't start | Needs privileged + `/dev/kmsg`; some kernels differ. Check `docker logs forge_cadvisor`. |
| node-exporter shows partial metrics | Host mount/pid settings; confirm `/:/host:ro,rslave` and `pid: host`. |
| A service target is "down" | It has no exporter, or the exporter isn't reachable. Add the exporter + enable the stub in `prometheus.yml`, then `curl -X POST .../-/reload`. |
| Disk filling | TSDB retention default 15d (`PROM_RETENTION`). Lower it or grow the volume. |

## Backup / restore

`forge_prometheus_data` (the TSDB) is included in `scripts/backup.sh`. Metrics
history is usually non-critical — you may exclude it to keep backups small. See
[backup.md](backup.md).

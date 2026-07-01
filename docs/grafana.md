# Grafana (observability)

## What it does

The dashboards front-end for the stack. It reads **Prometheus** (metrics) and
**Loki** (logs) and renders them. Everything is **auto-provisioned** — on first
start, both datasources and a starter dashboard are wired from mounted config
files, with no click-through setup.

## What's auto-provisioned

- **Datasources** (`provisioning/datasources/datasources.yaml`): Prometheus
  (uid `forge-prometheus`, default) and Loki (uid `forge-loki`).
- **Dashboard** (`dashboards/homelab-overview.json` via
  `provisioning/dashboards/dashboards.yaml`): "Homelab Overview" with host CPU,
  host memory, per-container memory (cAdvisor), and a live container-logs panel
  (Loki). Panels reference the fixed datasource uids so they resolve without any
  import-time mapping.

## Access & auth

- Reached through Caddy at a `*.ts.net` name (both networks; no ports
  published). Set `GRAFANA_ROOT_URL` in `.env` to that URL for correct links.
- Admin password auto-generated into git-ignored `.env`, shown once. Sign-up is
  disabled.

## How to verify

```bash
./modules/grafana/healthcheck.sh    # PASS = /api/health 2xx
# Then browse (over Tailscale): log in as admin, open the "homelab-forge"
# folder → "Homelab Overview". Panels should show data if Prometheus/Loki are up.
```

> **⚠ VM-verify:** the starter dashboard JSON is valid and uses the correct
> provisioning format (fixed datasource uids, no `${DS_}` import vars), but its
> panels can only be confirmed to *render* in a running Grafana. If a panel says
> "datasource not found," confirm the uids in `datasources.yaml` match those in
> the dashboard JSON.

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| Login fails | Use the password in `modules/grafana/.env`. |
| "datasource not found" on panels | uid mismatch between dashboard JSON and `datasources.yaml`. Both must be `forge-prometheus` / `forge-loki`. |
| Panels empty but datasources OK | Prometheus/Loki have no data yet, or the query needs adjusting for your metrics. |
| Wrong redirect URLs behind Caddy | Set `GRAFANA_ROOT_URL` to the public `*.ts.net` URL and re-deploy. |

## Backup / restore

`forge_grafana_data` holds users, preferences, and any dashboards you create in
the UI. Provisioned datasources + the starter dashboard come from files (in
git), so they're recreated on deploy regardless. Included in
`scripts/backup.sh`. See [backup.md](backup.md).

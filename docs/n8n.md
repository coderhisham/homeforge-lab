# n8n (automation)

## What it does

n8n is a workflow-automation tool (visual, node-based) — connect APIs, run
scheduled jobs, build integrations. In tuninforge it's the first service that
depends on other services: **Postgres** (stores every workflow + your encrypted
credentials) and **Redis** (wired for queue mode).

## How the cross-service wiring works

n8n needs Postgres's password — but that password was generated inside
Postgres's own `.env`, not n8n's. Rather than duplicate or regenerate it,
`modules/n8n/setup.sh` runs automatically before n8n starts and:

1. Reads Postgres's and Redis's generated passwords (via `tuninforge_get_env`) and
   writes them into `modules/n8n/.env`.
2. Ensures the `n8n` database exists in the already-running Postgres.

This is why the menu auto-selects Postgres + Redis when you pick n8n, and why
they install first (`postgres → redis → n8n`).

## ⚠ The encryption key

`N8N_ENCRYPTION_KEY` (generated once, shown once) encrypts all stored
credentials. **If it's lost or changed, saved credentials become unreadable.**
Back it up like any other secret — it's in `modules/n8n/.env`.

## Accessing it

n8n is reached through Caddy at a `*.ts.net` name (no ports published). Set
`N8N_HOST` and `N8N_WEBHOOK_URL` in `modules/n8n/.env` to that name so webhooks
and the editor build correct URLs, then re-deploy.

## How to verify

```bash
./modules/n8n/healthcheck.sh     # PASS = /healthz returns 2xx
# Confirm the DB wiring took:
docker exec tuninforge_postgres psql -U tuninforge -c '\l' | grep n8n     # n8n database exists
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| Won't start, "N8N_DB_PASSWORD must be set" | `setup.sh` didn't run or Postgres wasn't up. Ensure postgres is deployed, then re-run install for n8n. |
| DB connection refused | Postgres not running / n8n not on `tuninforge_internal`. Check both. |
| "n8n database does not exist" | `setup.sh` couldn't create it. Check `tuninforge_postgres` is healthy; re-run. |
| Credentials unreadable after a change | `N8N_ENCRYPTION_KEY` changed. Restore the original key from your backup. |
| Webhooks use wrong URL | Set `N8N_WEBHOOK_URL`/`N8N_HOST` to the public `*.ts.net` name and re-deploy. |

## Backup / restore

n8n's real state lives in **Postgres** (workflows + credentials) — covered by the
Postgres backup — plus the `tuninforge_n8n_data` volume (local files/config). Both are
captured by `scripts/backup.sh`. Critically, also keep `N8N_ENCRYPTION_KEY`
safe: restoring the database without the matching key leaves credentials
unreadable. See [backup.md](backup.md).

# Redis (data layer)

## What it does

In-memory cache and queue used by services like n8n. Runs on the **internal**
network only, password-protected, with append-only persistence so a restart
doesn't lose queued data.

## Isolation & safety

- On `tuninforge_internal` only — no published ports, not Caddy-fronted.
- Password (`requirepass`) auto-generated into git-ignored `.env`, shown once.
  Clients must `AUTH`.
- `--appendonly yes` for durability across restarts.
- **Not** auto-updated (stateful; no Watchtower label).

## How to verify

```bash
./modules/redis/healthcheck.sh    # PASS = authenticated PING -> PONG
# Manual (password read from inside the container, not the host CLI):
docker exec tuninforge_redis sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| "NOAUTH Authentication required" | Client isn't sending the password. Use the value in `modules/redis/.env`. |
| Container won't start, "PASSWORD must be set" | `.env` missing. Re-run install to generate it. |
| Data lost on restart | Confirm the `tuninforge_redis_data` volume is mounted and `--appendonly yes` is in the command. |

## Backup / restore

The `tuninforge_redis_data` volume (including the append-only file) is archived by
`scripts/backup.sh` and restored by `scripts/restore.sh`. See [backup.md](backup.md).
Redis data is usually a cache; losing it is rarely fatal, but queues (e.g. n8n)
benefit from the persistence + backup.

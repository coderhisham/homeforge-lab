# PostgreSQL (data layer)

## What it does

The shared relational database for services that need SQL (n8n, LiteLLM, and
your own apps). Runs on the **internal** network only — reachable by other
containers at `postgres:5432`, never from outside the box.

## Isolation & safety

- On `forge_internal` (an `--internal` Docker network, no gateway) — **no
  published ports**, not on the public/Caddy network.
- **Not** auto-updated (no Watchtower label). Databases are stateful; upgrade
  deliberately, after a backup.
- Password is auto-generated into a git-ignored `.env` (0600) and shown once.

## Multi-database

Set `POSTGRES_MULTIPLE_DATABASES` (comma-separated) in `modules/postgres/.env`
**before first boot**. Each name gets a database + an owner role of the same
name. The init script only runs on a fresh data volume — to add a database
later, create it manually or via the dependent service's flow.

```bash
# in modules/postgres/.env
POSTGRES_MULTIPLE_DATABASES=n8n,litellm
```

## How to verify

```bash
./modules/postgres/healthcheck.sh                     # PASS = accepting connections
docker exec forge_postgres pg_isready                 # accepting connections
docker exec -it forge_postgres psql -U forge -c '\l'  # list databases
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| Container won't start, "PASSWORD must be set" | `.env` missing/empty. Re-run install so `lib/env.sh` generates it. |
| Extra databases not created | `POSTGRES_MULTIPLE_DATABASES` was set *after* first boot. Init runs only on an empty volume; create them manually. |
| A service can't connect | It must join `forge_internal` and use host `postgres`. Check its compose networks. |
| Out of disk | Postgres data grows; monitor the `forge_postgres_data` volume; back up + prune. |

## Backup / restore

Covered by the stack backup: `scripts/backup.sh` takes a `pg_dumpall` logical
dump (the authoritative restore source) **and** archives the data volume.
Restore with `scripts/restore.sh` — it re-imports the SQL dump into the running
container. See [backup.md](backup.md).

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

Covered by the stack backup: `scripts/backup.sh` archives the data volume **and**
takes a `pg_dumpall` logical dump (kept for manual / cross-version recovery).
`scripts/restore.sh` restores the data volume as the primary source, and only
falls back to re-importing the SQL dump if the volume is absent from the snapshot
(applying both would duplicate rows). See [backup.md](backup.md).

## ⚠ Major-version upgrade (e.g. 16 → 18)

PostgreSQL stores its data in a format tied to the **major** version. The
`postgres:18` binary will **refuse to start** on a data directory created by
`postgres:16` — you'll see `database files are incompatible with server` in the
logs and the container will crash-loop. A major bump is a **migration**, not a
tag swap.

If you're on a **fresh box** (no existing `forge_postgres_data` volume), there's
nothing to do — 18 initializes cleanly.

If you have **existing data on v16**, migrate via dump/restore before switching
the image tag:

```bash
# 1. While STILL on the postgres:16 image, dump everything:
docker exec forge_postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' > /tmp/pg16-dump.sql

# 2. Stop postgres and REMOVE ONLY its data volume (back it up first!):
./forge.sh remove postgres              # keeps the volume
docker volume rm forge_postgres_data    # deletes the v16 data dir

# 3. Switch the image to postgres:18 (already done in this repo), then deploy —
#    it initializes a fresh v18 data dir:
./forge.sh add postgres

# 4. Restore the dump into the new v18 instance:
cat /tmp/pg16-dump.sql | docker exec -i forge_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
rm -f /tmp/pg16-dump.sql

# 5. Verify (e.g. your databases are back):
docker exec forge_postgres psql -U forge -c '\l'
```

Alternatively use `pg_upgrade` with both binaries, but for a homelab the
dump/restore path above is simpler and reliable. **Always take a fresh backup
first** (`scripts/backup.sh`).

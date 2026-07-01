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

A PostgreSQL data directory is tied to its **major** version — a newer binary
won't start on an older data dir. A major bump is a **migration**, not a tag
swap. Two things change going to 18:

1. **Data format** — v18 can't read a v16 data dir; you migrate via dump/restore.
2. **Mount path** — v18 images store data in a version-specific subdir and
   require the volume mounted at **`/var/lib/postgresql`** (v16 used
   `/var/lib/postgresql/data`). This repo's compose is already set for v18; a
   v16 mount path makes v18 refuse to start (see docker-library/postgres#1259).

If you're on a **fresh box** (no existing `forge_postgres_data` volume), there's
nothing to do — 18 initializes cleanly.

If you have **existing data on v16**, migrate via dump/restore. **Do the steps
in order and do NOT delete the dump until the restore is verified:**

```bash
# 1. While STILL on the postgres:16 image, dump everything. Verify it's non-empty.
docker exec forge_postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' > ~/pg16-dump.sql
test -s ~/pg16-dump.sql && echo "dump OK ($(wc -l < ~/pg16-dump.sql) lines)" || echo "DUMP EMPTY — stop, do not proceed"

# 2. Take a full stack backup too, as a safety net:
sudo ./scripts/backup.sh

# 3. Remove postgres and its v16 volume (the dump above is your recovery copy):
./forge.sh remove postgres
docker volume rm forge_postgres_data

# 4. Deploy fresh v18 (compose already pinned to 18 + correct mount path):
./forge.sh add postgres
./modules/postgres/healthcheck.sh          # must PASS before continuing

# 5. Restore the dump into v18:
cat ~/pg16-dump.sql | docker exec -i forge_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

# 6. VERIFY the data is back BEFORE deleting the dump:
docker exec forge_postgres psql -U forge -c '\l'   # your databases (incl. n8n) present?
# Only once you've confirmed the restore:
rm -f ~/pg16-dump.sql
```

> [!WARNING]
> Keep the dump (`~/pg16-dump.sql`) until step 6 confirms the restore. If v18
> fails to start or the restore errors, that file is your only recovery copy —
> deleting it early (together with the dropped volume) means data loss.

Alternatively use `pg_upgrade` with both binaries, but for a homelab the
dump/restore path above is simpler and reliable.

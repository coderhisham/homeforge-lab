# Backup & restore (Restic)

homelab-forge ships a working, encrypted backup out of the box. `scripts/backup.sh`
captures the data layer; `scripts/restore.sh` brings it back. Both use
[Restic](https://restic.net) — encrypted, deduplicated, incremental.

## What gets backed up

- **A Postgres logical dump** (`pg_dumpall`) when `forge_postgres` is running —
  kept for manual and cross-version recovery. (On a normal restore the Postgres
  data **volume** is the source; the dump is only auto-applied as a fallback if
  the volume is absent from the snapshot — applying both would duplicate rows.)
- **Every `forge_*_data` Docker volume** (postgres, redis, minio, qdrant, caddy,
  portainer, …), tarred via a throwaway alpine container.

Everything is staged, then sent to the Restic repo in one encrypted snapshot
tagged `forge`. Plaintext staging is deleted afterward.

## The encryption password — SAVE IT

On first run, if you haven't provided one, a strong password is generated at
`/var/lib/forge/restic.pass` (root, 0600) and printed **once**.

> **Without this password your backups cannot be decrypted or restored.** Copy
> it to your password manager AND somewhere off the box. If the box dies and the
> password only lived on it, the backups are useless.

## Default: encrypted local repo

```bash
sudo ./scripts/backup.sh            # backup to /var/lib/forge/restic
sudo ./scripts/backup.sh --dry-run  # preview, change nothing   (set DRY_RUN=1)
restic -r /var/lib/forge/restic snapshots   # list snapshots
```

Retention (auto-pruned): last 7 daily, 4 weekly, 6 monthly. Tune with
`FORGE_KEEP_DAILY` / `FORGE_KEEP_WEEKLY` / `FORGE_KEEP_MONTHLY`.

## Redirect to a remote repo (S3 / Backblaze B2 / SFTP)

A local repo dies with the box — send backups off-site by exporting standard
Restic env before running. Anything in the environment overrides the local
default.

```bash
# Amazon S3 (or any S3-compatible endpoint, incl. your own MinIO elsewhere)
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/my-bucket/forge"
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...
export RESTIC_PASSWORD_FILE=/var/lib/forge/restic.pass
sudo -E ./scripts/backup.sh

# Backblaze B2
export RESTIC_REPOSITORY="b2:my-bucket:forge"
export B2_ACCOUNT_ID=...  B2_ACCOUNT_KEY=...

# SFTP / rsync target
export RESTIC_REPOSITORY="sftp:user@host:/srv/restic/forge"
```

(Use `sudo -E` so the exported env reaches the script.) Schedule it with a cron
entry or systemd timer — e.g. daily at 03:00 — pointing at the same exports.

## Restore

`scripts/restore.sh` is **destructive**: it stops the data-layer services,
overwrites their volumes with the snapshot, restarts them, and re-imports the
Postgres dump. It requires typing `RESTORE` to proceed.

```bash
sudo ./scripts/restore.sh --list          # list snapshots
sudo ./scripts/restore.sh                  # restore the latest
sudo ./scripts/restore.sh <snapshot-id>    # restore a specific one
sudo ./scripts/restore.sh --dry-run        # preview the plan, change nothing
```

For a remote repo, export the same `RESTIC_REPOSITORY` / credentials first.

## Verify a restore actually works

A backup you've never restored is a hope, not a backup. Periodically:

1. `sudo ./scripts/backup.sh`
2. `sudo ./scripts/restore.sh --dry-run` (confirm it finds the snapshot + volumes)
3. On a **scratch VM**, do a real restore and check each service's
   `healthcheck.sh` passes and data is present.

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| "No Restic password file … cannot decrypt" | The password file is missing and none is in env. Restore the saved password to `/var/lib/forge/restic.pass` or export `RESTIC_PASSWORD`. |
| `restic init` says already initialized | Fine — idempotent; backup continues. |
| Remote backup can't authenticate | Missing/incorrect cloud credentials in env; and remember `sudo -E`. |
| Restore ran but a service is unhealthy | Check that service's `healthcheck.sh` and `docker logs`; the Postgres dump re-import waits for readiness but a very slow start can miss it — re-run the import. |

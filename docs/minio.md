# MinIO (data layer)

> [!WARNING]
> **MinIO Community Edition is effectively end-of-life (2026).** The
> `minio/minio` GitHub repo was archived Apr 25 2026, and free community Docker
> images stopped publishing (Oct 2025) — CE is now source-only. This module is
> pinned to the **last working community image** (`RELEASE.2025-04-22T22-12-26Z`)
> so existing setups keep running, but it will get **no updates or security
> fixes**. The license is still AGPLv3.
>
> **Recommendation:** for a new deployment, or when you're ready to migrate,
> replace this module with a maintained S3-compatible engine. Strongest
> self-host options in 2026: **Garage** (simple, lightweight), **SeaweedFS**
> (feature-rich), **RustFS**, or the **libreFS** MinIO fork. Note these are
> different storage engines — moving means a **data migration** (copy buckets
> via `mc mirror`/`rclone` to the new endpoint), not a tag swap. Adding one is a
> new module per [CONTRIBUTING.md](../CONTRIBUTING.md). Tracking issue: decide
> the target engine, then migrate.

## What it does

S3-compatible object storage — a local, private replacement for AWS S3. Other
services use it at `http://minio:9000` (internal), and you reach its web console
through Caddy at a `*.ts.net` name.

> **Disk note:** object storage grows with what you put in it. On a constrained
> SSD, watch the `forge_minio_data` volume.

## Isolation & safety

- On **both** networks: `forge_internal` (S3 API for in-cluster services) and
  `forge_public` (Caddy fronts the console over the tailnet). No ports published
  directly.
- Root credentials auto-generated into git-ignored `.env`, shown once.
- **Not** auto-updated (stateful; no Watchtower label).

## ⚠ Verify on your box

Two things this module could not confirm without running on the VM:

1. **Image tag.** MinIO uses date-stamped `RELEASE.*` tags. If `docker compose
   pull` fails, bump the tag in `modules/minio/docker-compose.yml` to a current
   one from [Docker Hub](https://hub.docker.com/r/minio/minio/tags). The failure
   is loud (pull error), not silent.
2. **Healthcheck.** Uses `mc ready local` (the `mc` client bundled in the server
   image). If unavailable, forge's liveness fallback still verifies the container
   and `healthcheck.sh` reports run-state.

## How to verify

```bash
./modules/minio/healthcheck.sh
docker exec forge_minio mc ready local          # if mc is present
docker logs forge_minio | tail                  # startup + endpoint info
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| `pull` fails | Stale image tag — bump it (see above). |
| Console redirect loops | Set `MINIO_CONSOLE_URL` in `.env` to the public `https://minio.<host>.ts.net` once the Caddy block is wired. |
| Can't reach console | Caddy/Tailscale down, or the Caddy site block not present yet. |
| Out of disk | Object data grows; prune buckets, monitor the volume, back up. |

## Backup / restore

The `forge_minio_data` volume is archived by `scripts/backup.sh` and restored by
`scripts/restore.sh`. For very large buckets, consider `mc mirror` to a remote
S3/B2 target in addition to the volume backup. See [backup.md](backup.md).

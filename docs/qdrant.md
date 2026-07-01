# Qdrant (data layer)

## What it does

Vector database for embeddings / similarity search — used by AI-layer services
(e.g. LiteLLM-backed apps) and your own code. Reachable in-cluster at
`http://qdrant:6333` and, through Caddy, at a `*.ts.net` name.

## Isolation & safety

- On **both** networks: `tuninforge_internal` (private API for in-cluster use) and
  `tuninforge_public` (Caddy fronts the dashboard/API over the tailnet). No ports
  published directly.
- API key auto-generated into git-ignored `.env`, shown once. Every request
  must send the `api-key` header.
- **Not** auto-updated (stateful; no Watchtower label).

## Healthcheck design (deliberate)

Qdrant's image is a minimal binary that may lack a shell/curl/wget, so an
in-container `CMD` healthcheck could be impossible (the same trap that bit
Portainer in Phase 1). This module therefore declares **no** compose healthcheck:

- tuninforge's health poller treats "running + stable" as healthy, and
- `modules/qdrant/healthcheck.sh` does a **real** HTTP `/readyz` probe from a
  throwaway `curl` container on `tuninforge_internal` — independent of Qdrant's own
  tooling. A definite non-2xx answer is reported as FAIL (no fail-open); only an
  un-runnable probe (e.g. curl image not pullable offline) falls back to
  liveness.

## How to verify

```bash
./modules/qdrant/healthcheck.sh    # PASS = /readyz responded 2xx
# Manual, over the internal network:
docker run --rm --network tuninforge_internal curlimages/curl:8.11.1 \
  -fsS http://tuninforge_qdrant:6333/readyz
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| 401/403 on API calls | Missing/incorrect `api-key` header. Use the value in `modules/qdrant/.env`. |
| `pull` fails | Bump the pinned image tag in the compose file to a current release. |
| Healthcheck WARN "probe could not run" | The curl helper image isn't available (offline). The container may still be fine; pull the image or check manually. |

## Backup / restore

The `tuninforge_qdrant_data` volume (collections + vectors) is archived by
`scripts/backup.sh` and restored by `scripts/restore.sh`. For large collections,
Qdrant also has a snapshot API you can use in addition. See [backup.md](backup.md).

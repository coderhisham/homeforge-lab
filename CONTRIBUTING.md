# Contributing to tuninforge

Thanks for wanting to add to tuninforge. The project is intentionally
**modular and registry-driven**: adding a service is a well-defined, self-
contained change that plugs into the existing install/status/remove machinery
without touching the core. This guide is the recipe.

## License

tuninforge is [AGPL-3.0](LICENSE). By contributing you agree your changes are
licensed under it.

## Architecture in one paragraph

`tuninforge.sh` is the entrypoint. `lib/deps.sh` holds the **single-source service
registry** — the one place a service is declared. The `lib/` scripts provide
shared behavior (logging, secret generation, `.env` materialization, Docker
networks, health polling, compose orchestration). Each service lives in
`modules/<name>/` with its own `docker-compose.yml`, `.env.example`, and
`healthcheck.sh`. The interactive selection UI is a committed Go/Bubble Tea
binary (`bin/`) with a whiptail fallback; **Bash stays authoritative** for
dependency resolution — the TUI is presentation only.

## Adding a new service (the checklist)

### 1. Register it in `lib/deps.sh`

Add one pipe-delimited row to `tuninforge_registry()`:

```
name|layer|deps|ram_mb|disk_mb|watchtower|networks|desc
```

- **layer**: `access | core | data | ai | automation | observability | backup`
- **deps**: space-separated service names, or `-` for none. Deps must appear
  **earlier** in the registry than your service (the registry is a valid
  topological order — install/teardown order derive from it).
- **ram_mb / disk_mb**: rough estimates for the summary screen.
- **watchtower**: `yes` for stateless services (safe to auto-update), **`no`
  for anything stateful** (databases, object/vector stores — never auto-update).
- **networks**: `public | internal | both | none`.

### 2. Create `modules/<name>/`

- **`docker-compose.yml`**
  - Pin the image tag (avoid surprise breakage).
  - Join the right external network(s): `tuninforge_public` (Caddy-fronted) and/or
    `tuninforge_internal` (data layer). Both are declared `external: true`.
  - **Don't publish ports** for anything Caddy should front — access is via the
    tailnet through Caddy.
  - Secrets come from the environment with a fail-fast guard:
    `FOO: "${FOO:?FOO must be set (see .env)}"`.
  - Add the Watchtower label **only if stateless**:
    `com.centurylinklabs.watchtower.enable: "true"`.
  - Prefer a real `healthcheck:` — **but only if the image ships the tool it
    needs**. Many minimal/distroless images have no shell/curl/wget; assuming
    otherwise is the single most common bug here. If unsure, omit the compose
    healthcheck (tuninforge treats "running + stable" as healthy) and do the real
    probe in `healthcheck.sh` (see below).
  - Name volumes `tuninforge_<name>_data` so backup/restore picks them up.

- **`.env.example`**
  - Use `__GEN:type:len__` placeholders for generated secrets (`alnum`, `hex`,
    `b64url`) — `lib/env.sh` fills them once, 0600, and prints them once.
  - Do **not** put `__GEN__` on a value that must *match* another service's
    secret (e.g. a shared DB password) — leave it empty and fill it in a
    pre-deploy `setup.sh` via `tuninforge_get_env <module> <key>`.

- **`healthcheck.sh`** — exit 0 healthy, non-zero not. For services on a network,
  the robust pattern (used by qdrant/litellm/prometheus/loki/…) is to probe the
  HTTP endpoint from a throwaway curl container on `tuninforge_internal`, so it does
  **not** depend on the service image's own tooling. **No fail-open**: a definite
  bad response is a FAIL; only an un-runnable probe falls back to liveness.

- **`setup.sh`** *(optional)* — a pre-deploy hook run by `tuninforge_deploy_module`
  before pull/up. Use it for cross-service wiring (e.g. create a database, copy
  another service's secret). Must be idempotent and honor `DRY_RUN`. See
  `modules/n8n/setup.sh` as the reference.

### 3. Document it: `docs/<name>.md`

Follow the existing docs: **what it does**, **how to verify**, **common failure
modes**, **backup/restore**. Write for someone who has never run the stack.

### 4. Verify before you open the PR

- `bash -n` every script you touched.
- `docker compose -f modules/<name>/docker-compose.yml config` (authoritative
  YAML validation).
- `./tuninforge.sh install --with <name> --dry-run` — confirms deps resolve and the
  deploy sequence is right.
- A real deploy on a **disposable VM** (never a primary box): the service comes
  up, `./modules/<name>/healthcheck.sh` passes, and `./tuninforge.sh remove <name>`
  tears it down cleanly.

## Coding conventions

- **Bash**, `set -euo pipefail`, target Ubuntu LTS (bash 5.x); keep pure logic
  bash-3.2-safe where practical so it's testable anywhere.
- Source shared helpers from `lib/`; don't reinvent logging/secrets/health.
- Everything **idempotent** (safe to run twice) and **dry-run aware**.
- Never print secrets except the one-time generation notice; never commit a
  real `.env` (they're git-ignored).
- Match the surrounding style. Comments explain *why*, not *what*.

## PR expectations

- One service (or one focused change) per PR.
- Say what you tested and on what (VM image, what passed).
- Flag anything you couldn't verify (e.g. GPU paths, an image tag you couldn't
  pull) so reviewers know where to look.

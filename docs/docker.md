# Docker (prerequisite — container runtime)

## What it does

Installs Docker Engine and the Compose plugin — the container runtime every
tuninforge service runs on. It is a **prerequisite**, not a selectable
service: `tuninforge.sh` runs it automatically before deploying any stack module if
Docker isn't already present and working.

## How it installs

It uses Docker's official convenience script from `https://get.docker.com`, with
the same safety posture as the Tailscale module:

1. Downloads the script to a **file** (never `curl | sh`).
2. Shows you its size + SHA-256 and offers to page through it.
3. Runs it only after you confirm.
4. Enables the `docker` systemd service.
5. Adds your user to the `docker` group.
6. Verifies with `docker run --rm hello-world` and `docker compose version`.

### Why the convenience script?

`get.docker.com` is Docker's own, widely used bootstrap for Ubuntu/Debian. It
sets up Docker's apt repo and installs Engine + Compose in one step, which keeps
this module small and distro-current. If you prefer manual apt-repo setup, you
can install Docker yourself first — this module detects a working Docker and
skips reinstalling.

## ⚠ Group membership requires a re-login

After adding you to the `docker` group, the change **only takes effect on your
next login**. Until then, `docker` needs `sudo`. tuninforge handles this
automatically (it detects whether it can reach Docker directly and uses `sudo`
when needed), but for your own shell:

```bash
# Either log out and back in, or in the current shell:
newgrp docker
docker info      # should work without sudo now
```

## How to verify

```bash
docker --version
docker compose version
docker run --rm hello-world
docker info
```

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| `permission denied` on the socket | Group change not active yet. `newgrp docker` or re-login; until then use `sudo docker`. |
| Daemon not running | `sudo systemctl enable --now docker`; check `sudo journalctl -u docker`. |
| Script download fails | Network/DNS. Confirm `curl -fsSL https://get.docker.com` works. |
| `docker compose` not found | Older install without the plugin. Re-run this module, or `sudo apt-get install docker-compose-plugin`. |
| Install on non-Ubuntu | The convenience script supports major distros but this project targets Ubuntu LTS; other distros are untested. |

## Idempotency

Running it again when Docker already works is a no-op — it verifies and exits
without reinstalling or re-adding the group.

## Backup / restore

Docker itself is stateless from tuninforge's perspective — your data lives in named
volumes managed per service (backed up via the Restic setup). Reinstalling
Docker does not touch existing volumes.

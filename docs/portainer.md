# Portainer (core — Docker management UI)

## What it does

Portainer is a web UI for managing Docker: containers, images, volumes,
networks, logs, and stacks. In homelab-forge it gives you a visual overview of
everything the installer stands up.

## ⚠ Security — read this first

Portainer mounts the **Docker socket** (`/var/run/docker.sock`). Controlling the
Docker daemon is **root-equivalent on the host** — anyone who reaches the
Portainer UI effectively controls the machine. Two rules follow:

1. **Tailnet-only.** Portainer publishes **no ports** by default; it's reached
   through Caddy at a `*.ts.net` name, over your tailnet. Do **not** expose it to
   the public internet.
2. **Set the admin password immediately.** On first launch Portainer shows an
   admin-account setup screen. Portainer **disables initial setup a few minutes
   after first boot** as an anti-hijack measure — so open the UI over Tailscale
   and set a strong password right after deploy. If you miss the window, restart
   the container (`docker restart forge_portainer`) to reopen setup.

The socket is mounted read-only (`:ro`), which reduces but does **not** eliminate
the risk — many privileged operations still work. Treat access as root.

## How to verify

```bash
./modules/portainer/healthcheck.sh
# or
docker ps --filter name=forge_portainer

# Status API (from the host):
docker exec forge_portainer wget -qO- http://localhost:9000/api/status
```

`forge.sh status` also reports Portainer's health.

## First login

1. Ensure Caddy is running and Tailscale is up.
2. From a tailnet device, browse to Portainer's `*.ts.net` URL (the Caddy site
   block for Portainer is wired when you add it via `forge.sh`).
3. Create the admin user + strong password on the setup screen.
4. Choose the **local** Docker environment when prompted.

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| Setup screen says "instance timed out" | You passed the initial-setup window. `docker restart forge_portainer`, then retry immediately. |
| Can't reach the UI | Caddy not running, Tailscale down, or the Portainer `conf.d` site block not present. Check `forge.sh status`. |
| Healthcheck fails | Image may lack `wget`; adjust the healthcheck to the container's available tool. Check `docker logs forge_portainer`. |
| "permission denied" on the socket | SELinux/AppArmor or socket perms. Confirm the daemon socket path and that the container can read it. |

## Update strategy

Portainer carries `com.centurylinklabs.watchtower.enable=true` — Watchtower
auto-updates it. The image tag is pinned in `docker-compose.yml`; bump it
deliberately for a controlled upgrade, or let Watchtower track the CE line.

## Backup / restore

All state is the `forge_portainer_data` volume (users, settings, endpoints).
Back it up via the stack's Restic setup, or manually:

```bash
docker run --rm -v forge_portainer_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/portainer_data.tgz -C /data .
```

Restore by extracting back into the volume before starting the container. If you
lose it, you'll re-run first-time setup (and re-create users).

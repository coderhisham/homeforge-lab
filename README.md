# homelab-forge

A CLI-driven installer that stands up a production-grade, modular, self-hosted
developer infrastructure stack on a fresh Ubuntu LTS server. Clone, run one command,
pick your services from an interactive menu, and get a Tailscale-fronted stack with
auto-TLS, backups, and observability.

> **Status:** under active development. Phase 0 (access layer) is the current focus.
> The README architecture diagram and full service docs land in Phase 5.

## Quickstart

```bash
git clone <this-repo> homelab-forge
cd homelab-forge
./forge.sh install          # interactive service-selection menu
```

Non-interactive:

```bash
./forge.sh install --with caddy,portainer,postgres,redis
# or
cp forge.config.example.yaml forge.config.yaml   # edit it
./forge.sh install --config forge.config.yaml
```

Other commands:

```bash
./forge.sh add qdrant       # add a service to a running stack
./forge.sh remove qdrant    # stop + remove (confirm + --dry-run supported)
./forge.sh status           # installed vs available services + health
./forge.sh --help
```

## Design principles

- **Safety first.** Nothing touches the system without an explicit confirmation gate.
  The access layer (Tailscale + SSH hardening) installs first so the box is safely
  reachable before anything else. SSH hardening never locks you out: it verifies
  key-based login works, backs up `sshd_config`, validates with `sshd -t`, reloads
  (not restarts), and makes you confirm a fresh login from a second terminal before
  it's considered done — with a printed rollback command if it isn't.
- **Idempotent.** Running the installer twice never breaks an existing setup.
- **Modular.** Each service lives in `modules/<service>/` with its own
  `docker-compose.yml`, `.env.example`, and `healthcheck.sh`.
- **Secrets stay secret.** Strong secrets are auto-generated into git-ignored `.env`
  files and printed to your terminal exactly once, on first generation.

## License

[AGPL-3.0](LICENSE). Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md)
(lands in Phase 5) for the module convention.

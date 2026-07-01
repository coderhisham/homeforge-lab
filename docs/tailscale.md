# Tailscale (access layer)

## What it does

Installs [Tailscale](https://tailscale.com) and joins this machine to your
tailnet, giving every tuninforge service a private, encrypted network path
without opening any inbound ports to the public internet. Tailscale also
provides MagicDNS, which the Caddy module later uses to obtain real HTTPS
certificates for a `*.ts.net` hostname.

It is installed **first**, before any other module, so the box is safely
reachable before anything else is exposed.

## What the module does, step by step

1. **Downloads the official installer** from `https://tailscale.com/install.sh`
   to a temp file, shows you its size + SHA-256, and offers to page through it.
   It is **never piped straight into `sh`** — you see it before it runs.
2. **Asks you to choose an SSH access model** explicitly:
   - **Tailscale SSH** — auth governed by your tailnet ACLs (`tailscale up --ssh`).
   - **Traditional sshd** — classic OpenSSH key auth; pair with the
     [ssh-hardening](ssh-hardening.md) module.

   The module will not silently enable both.
3. **Brings the interface up** using either an auth key you provide (prompted
   with hidden input, or via `TS_AUTHKEY` / config) or interactive auth. On a
   headless box (no `DISPLAY`), it prints an authentication URL for you to open
   on another device.
4. **Verifies** with `tailscale status` and `ip addr show tailscale0`, then
   prints your assigned Tailscale IP and MagicDNS name.

## How to run it

```bash
./tuninforge.sh install --with tailscale
# preview without changing anything:
./tuninforge.sh install --with tailscale --dry-run
```

Non-interactive (CI / cloud-init), supply a key:

```bash
TS_AUTHKEY="tskey-auth-..." TS_SSH_MODE="sshd" ./tuninforge.sh install --with tailscale --yes
```

## How to verify

```bash
tailscale status            # this node should be listed and "active"
tailscale ip -4             # your 100.x.y.z address
ip addr show tailscale0     # interface exists with the IP bound
```

## Prerequisites for later modules

For Caddy's MagicDNS certs to work, enable these in the tailnet admin console:

- **MagicDNS** (DNS page)
- **HTTPS Certificates** (DNS page → "Enable HTTPS")

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| `tailscale up` hangs on a headless box | It's waiting on browser auth. Look for the printed `https://login.tailscale.com/...` URL and open it on another device, or re-run with `TS_AUTHKEY`. |
| `tailscale0` interface missing but status OK | Networking/driver issue; check `sudo journalctl -u tailscaled`. |
| Auth key rejected | Key expired, single-use already consumed, or wrong tailnet. Generate a fresh reusable key in the admin console. |
| Install script download fails | DNS/network. Retry; verify `curl -fsSL https://tailscale.com/install.sh` works. |

## Backup / restore

Tailscale keeps no data you need to back up here — node state lives under
`/var/lib/tailscale`. To move to a new box, just re-run this module and
re-authenticate; remove the stale node from the admin console.

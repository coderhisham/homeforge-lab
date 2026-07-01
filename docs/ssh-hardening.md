# SSH hardening (access layer)

## What it does

Hardens the OpenSSH server so the box only accepts key-based logins, following
a strict, **lockout-safe** sequence. This is the single most dangerous module in
tuninforge — a careless sshd change can lock you out of a remote server
permanently — so it is built to fail safe at every step.

It enforces these directives (only changing values that differ from the target):

| Directive | Value |
|---|---|
| `PubkeyAuthentication` | `yes` |
| `PasswordAuthentication` | `no` |
| `PermitRootLogin` | `no` (or `prohibit-password` if you need root key recovery) |
| `KbdInteractiveAuthentication` | `no` |

## The sequence (never skips a step)

1. **Require working key auth.** If no public key exists for your login user, it
   **STOPS** and tells you to add one and confirm a key-based login *first*. It
   never disables passwords when that would strand you.
2. **Backup + detect layout.** Copies `/etc/ssh/sshd_config` to
   `/etc/ssh/sshd_config.bak.<timestamp>` unconditionally, and detects whether
   the config uses `Include /etc/ssh/sshd_config.d/*.conf` (modern Ubuntu).
3. **Apply where it actually wins.** On modern Ubuntu, sshd is
   **first-value-wins** and reads drop-ins via the `Include` before the rest of
   the main file — so a cloud-init drop-in can silently override edits to the
   main file. To defeat that, hardening is written to
   `/etc/ssh/sshd_config.d/00-tuninforge-hardening.conf` (the `00-` prefix sorts
   first, so it wins). On legacy layouts with no `Include`, it edits the main
   file directly (idempotent, duplicate-collapsing). It shows you exactly what
   it will write.
4. **Validate, reload, then verify the *effective* config.** Runs `sshd -t`
   and **aborts if it fails**, then `systemctl reload` (reload, not restart, so
   your session isn't dropped). Crucially, it then reads `sshd -T` (the fully
   resolved effective config) and confirms every hardened directive actually
   took effect. If something with higher precedence still overrides it, the
   module **reverts its change** rather than reporting a false success.
5. **Keep this session open.** Prints a bold/red banner instructing you to open a
   **second terminal** and confirm a fresh key-based login works.
6. **Confirm or roll back.** Only marks success after you confirm the new session
   worked. If you don't, it leaves the change in place but prints the exact
   rollback command so you can revert from your still-open session.
7. **Optional extras** (safe): configure `fail2ban` for sshd, and — *only after
   Tailscale is verified up* — a `ufw` rule limiting port 22 to the `tailscale0`
   interface. It refuses to firewall off SSH if Tailscale isn't confirmed.

> **Why a drop-in?** Editing only `/etc/ssh/sshd_config` is a classic footgun on
> Ubuntu 22.04/24.04: the main file's `Include` is read first, so a drop-in like
> `50-cloud-init.conf` shipping `PasswordAuthentication yes` wins over your edit.
> Writing `00-tuninforge-hardening.conf` plus verifying via `sshd -T` closes that gap.

## How to run it

```bash
# Preview every change without touching the system (recommended first):
./tuninforge.sh install --with ssh-hardening --dry-run

# Real run (interactive — required by default):
./tuninforge.sh install --with ssh-hardening
```

### Non-interactive / unattended

The module **refuses to run non-interactively** (no TTY) unless you explicitly
accept the lockout risk:

```bash
./tuninforge.sh install --with ssh-hardening --i-understand-the-risk --yes
```

Even with `--yes`, this is dangerous on a remote box — you won't be present to
test the new session. Prefer running it interactively over an existing SSH
connection you keep open.

## Rollback

The module prints the **exact** rollback command (with the real path/timestamp)
at the end of every run. Run it in your **still-open** original session. Which
command depends on how hardening was applied:

**Modern Ubuntu (drop-in layout)** — just remove the drop-in:

```bash
sudo rm -f /etc/ssh/sshd_config.d/00-tuninforge-hardening.conf && sudo systemctl reload ssh
```

**Legacy layout (main file edited)** — restore the backup:

```bash
sudo cp /etc/ssh/sshd_config.bak.<timestamp> /etc/ssh/sshd_config && sudo systemctl reload ssh
```

If you closed every session too, use your cloud provider's serial/VNC console to
run the same command.

## Root recovery access

If you need to keep root reachable by key (e.g. break-glass), set in
`tuninforge.config.yaml`:

```yaml
access:
  ssh_hardening:
    permit_root_login: "prohibit-password"
```

and ensure `/root/.ssh/authorized_keys` contains a key. The module warns if it
doesn't.

## Common failure modes

| Symptom | Cause / fix |
|---|---|
| Module stops at step 1 | No key found for your user. Run `ssh-copy-id you@host`, confirm `ssh you@host` logs in without a password, then re-run. |
| `sshd -t` rejects the candidate | A pre-existing syntax error or an unsupported directive on your OpenSSH version. The live config is untouched; fix the reported line and re-run. |
| Locked out of new sessions | Use the rollback command above from your open session. If you closed it too, use your cloud provider's serial/VNC console to restore the backup. |
| `systemctl reload ssh` fails | Your distro's unit may be `sshd`. The module tries both; if it still fails, check `sudo journalctl -u ssh`. |
| ufw step skipped with a warning | Tailscale wasn't verified up. Bring Tailscale up first — firewalling SSH before that risks lockout. |

## Backup / restore

The only artifact is the timestamped `sshd_config.bak.*` in `/etc/ssh/`. Keep at
least one known-good backup. To restore, copy it back and reload ssh (see
Rollback).

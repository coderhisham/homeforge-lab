# SSH hardening (access layer)

## What it does

Hardens the OpenSSH server so the box only accepts key-based logins, following
a strict, **lockout-safe** sequence. This is the single most dangerous module in
homelab-forge — a careless sshd change can lock you out of a remote server
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
2. **Backup.** Copies `/etc/ssh/sshd_config` to
   `/etc/ssh/sshd_config.bak.<timestamp>` before any edit — unconditionally.
3. **Apply idempotently.** Builds a candidate config, changing only directives
   whose value differs and collapsing duplicates. Shows you a unified diff. If
   the config already matches, it's a no-op.
4. **Validate then reload.** Runs `sshd -t` against the *candidate* first and
   **aborts if it fails** — your live config is never replaced by an invalid one.
   On success it installs the candidate and runs `systemctl reload` (reload, not
   restart, so your current session is not dropped).
5. **Keep this session open.** Prints a bold/red banner instructing you to open a
   **second terminal** and confirm a fresh key-based login works.
6. **Confirm or roll back.** Only marks success after you confirm the new session
   worked. If you don't, it leaves the change in place but prints the exact
   rollback command so you can revert from your still-open session.
7. **Optional extras** (safe): configure `fail2ban` for sshd, and — *only after
   Tailscale is verified up* — a `ufw` rule limiting port 22 to the `tailscale0`
   interface. It refuses to firewall off SSH if Tailscale isn't confirmed.

## How to run it

```bash
# Preview every change without touching the system (recommended first):
./forge.sh install --with ssh-hardening --dry-run

# Real run (interactive — required by default):
./forge.sh install --with ssh-hardening
```

### Non-interactive / unattended

The module **refuses to run non-interactively** (no TTY) unless you explicitly
accept the lockout risk:

```bash
./forge.sh install --with ssh-hardening --i-understand-the-risk --yes
```

Even with `--yes`, this is dangerous on a remote box — you won't be present to
test the new session. Prefer running it interactively over an existing SSH
connection you keep open.

## Rollback

If a new session fails, run this in your **still-open** original session:

```bash
sudo cp /etc/ssh/sshd_config.bak.<timestamp> /etc/ssh/sshd_config && sudo systemctl reload ssh
```

The exact command (with the real timestamp) is printed at the end of every run.

## Root recovery access

If you need to keep root reachable by key (e.g. break-glass), set in
`forge.config.yaml`:

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

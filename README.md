# admin-my-system

Run one read-only script on a Linux host, get a complete, ready-to-paste
prompt for an LLM (Claude). The prompt contains a full diagnostic report of
the system plus instructions telling the LLM to answer in **script style**:
every finding comes with an explanation and a fenced `sh` code block with
ready-to-run fix commands, so *you* decide per item whether to
execute/patch/apply anything.

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/TyrannosaurusRoot/admin-my-system/main/diagnose.sh | sh > prompt.txt
```

or with wget:

```sh
wget -qO- https://raw.githubusercontent.com/TyrannosaurusRoot/admin-my-system/main/diagnose.sh | sh > prompt.txt
```

Then paste the contents of `prompt.txt` into Claude ([claude.ai](https://claude.ai),
Claude Code, or the API). Progress messages go to stderr, so `prompt.txt`
contains only the clean prompt. Without the redirect, the prompt is printed
to your terminal instead.

Running as root is optional but recommended — some sections (journal
errors, sudoers, failed logins, firewall rules) are richer with root. As a
regular user those sections are marked as skipped/partial instead of
failing.

## What it collects (all strictly read-only)

- System identity: kernel, distro, hostname, uptime, virtualization
- CPU & memory: load, usage, top processes
- Storage: disk/inode usage, block devices, mounts
- Network: interfaces, routes, DNS, listening sockets
- Services: failed/running systemd units and timers (OpenRC fallback)
- Logs: recent journal/dmesg errors, OOM-killer events, kernel taint
- Packages: detected package manager and pending updates (query/simulation only)
- Security: SSH daemon settings, firewall status, login-capable users,
  sudoers, failed logins, SELinux/AppArmor
- Scheduled jobs: crontabs and systemd timers
- Misc: time sync, logged-in users, last reboots

The script never modifies the system. Package update checks use read-only
query/simulation modes (`apt-get -s upgrade`, `dnf check-update`, ...).

## Options

Configuration is via environment variables (stdin is not available when
piping into `sh`):

| Variable    | Default | Effect                                        |
|-------------|---------|-----------------------------------------------|
| `MAX_LINES` | `60`    | Per-section output limit (keeps the prompt within LLM context) |

Example:

```sh
curl -fsSL https://raw.githubusercontent.com/TyrannosaurusRoot/admin-my-system/main/diagnose.sh | MAX_LINES=120 sh > prompt.txt
```

## Requirements

- Any POSIX `sh` (dash, ash/BusyBox, bash, ...) — no bash required
- Linux; every probe is guarded, missing tools degrade to a
  "(not available)" note instead of an error

## Security notes

- **Review before you pipe.** Piping code from the internet into a shell
  executes it. Read [`diagnose.sh`](diagnose.sh) first — it is a single
  self-contained file with no dependencies.
- **The generated prompt contains real system details** — hostnames, IP
  addresses, usernames, running services, open ports. Nothing is redacted.
  Treat `prompt.txt` as sensitive and review it before sharing it with any
  third party, including an LLM.

#!/bin/sh
# diagnose.sh - Gather Linux system diagnostics and emit an LLM-ready prompt.
#
# Usage (pipe straight from GitHub, POSIX sh, no bash required):
#   curl -fsSL https://raw.githubusercontent.com/TyrannosaurusRoot/admin-my-system/main/diagnose.sh | sh > prompt.txt
#
# All collection is strictly read-only. Progress goes to stderr, the final
# prompt is the only thing written to stdout. Configuration is via
# environment variables only (stdin is not available when piped into sh):
#   MAX_LINES  - per-section output limit (default: 60)

MAX_LINES="${MAX_LINES:-60}"
case "$MAX_LINES" in
    ''|*[!0-9]*) MAX_LINES=60 ;;
esac

REPORT="$(mktemp "${TMPDIR:-/tmp}/sysdiag.XXXXXX")" || exit 1
trap 'rm -f "$REPORT"' EXIT INT TERM

IS_ROOT=no
[ "$(id -u 2>/dev/null)" = "0" ] && IS_ROOT=yes

status() {
    printf '%s\n' "$*" >&2
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# run CMD... : execute a command with a timeout (if available), merging
# stderr so permission errors are visible in context.
run() {
    if have timeout; then
        timeout 10 "$@" 2>&1
    else
        "$@" 2>&1
    fi
}

# emit raw text into the report
emit() {
    printf '%s\n' "$*" >>"$REPORT"
}

# capture "Title" cmd args... : run a command, truncate its output, and
# append it to the report as a fenced block. Degrades gracefully when the
# tool is missing or produces nothing.
capture() {
    _title="$1"
    shift
    emit "#### $_title"
    if ! have "$1"; then
        emit "(tool \`$1\` not available on this system)"
        emit ""
        return 0
    fi
    _out="$(run "$@")"
    _rc=$?
    if [ -z "$_out" ]; then
        if [ $_rc -eq 0 ]; then
            emit "(no output)"
        else
            emit "(command failed with exit code $_rc - possibly requires root)"
        fi
        emit ""
        return 0
    fi
    _total=$(printf '%s\n' "$_out" | wc -l)
    emit '```'
    printf '%s\n' "$_out" | head -n "$MAX_LINES" >>"$REPORT"
    emit '```'
    if [ "$_total" -gt "$MAX_LINES" ]; then
        emit "(output truncated: showing $MAX_LINES of $_total lines)"
    fi
    [ $_rc -ne 0 ] && emit "(note: command exited with code $_rc - output may be partial)"
    emit ""
}

# capture_file "Title" /path : include a file's content if readable.
capture_file() {
    _title="$1"
    _file="$2"
    emit "#### $_title"
    if [ ! -e "$_file" ]; then
        emit "(file $_file does not exist)"
    elif [ ! -r "$_file" ]; then
        emit "(file $_file not readable - requires root)"
    else
        _total=$(wc -l <"$_file")
        emit '```'
        head -n "$MAX_LINES" "$_file" >>"$REPORT"
        emit '```'
        if [ "$_total" -gt "$MAX_LINES" ]; then
            emit "(output truncated: showing $MAX_LINES of $_total lines)"
        fi
    fi
    emit ""
}

heading() {
    emit "### $1"
    emit ""
    status "Collecting: $1 ..."
}

status "admin-my-system: gathering read-only diagnostics (root: $IS_ROOT) ..."
status "Nothing on this system will be modified."

# ---------------------------------------------------------------- identity
heading "System identity"
capture "Kernel and architecture" uname -a
capture_file "OS release" /etc/os-release
capture "Hostname" hostname
capture "Uptime and load" uptime
if have systemd-detect-virt; then
    capture "Virtualization" systemd-detect-virt
fi
capture "Current date and timezone" date

# ------------------------------------------------------------- cpu/memory
heading "CPU and memory"
capture "CPU count" nproc
emit "#### CPU model"
if [ -r /proc/cpuinfo ]; then
    emit '```'
    grep -m1 'model name' /proc/cpuinfo >>"$REPORT" 2>/dev/null || head -n 8 /proc/cpuinfo >>"$REPORT"
    emit '```'
else
    emit "(/proc/cpuinfo not readable)"
fi
emit ""
capture "Memory usage" free -h
capture_file "Load averages" /proc/loadavg
capture "Top processes by memory" sh -c "{ ps aux --sort=-%mem 2>/dev/null || ps aux; } | head -n 11 | cut -c1-160"
capture "Top processes by CPU" sh -c "ps aux --sort=-%cpu 2>/dev/null | head -n 11 | cut -c1-160"

# ---------------------------------------------------------------- storage
heading "Storage"
capture "Disk usage" df -h
capture "Inode usage" df -i
capture "Block devices" lsblk
capture "Mounted filesystems (real)" sh -c "grep -Ev '^(proc|sysfs|cgroup|cgroup2|devpts|tmpfs|devtmpfs|securityfs|pstore|bpf|tracefs|debugfs|configfs|fusectl|mqueue|hugetlbfs|overlay /run|none)' /proc/mounts"

# ---------------------------------------------------------------- network
heading "Network"
capture "Interfaces and addresses" ip addr
capture "Routing table" ip route
capture_file "DNS configuration" /etc/resolv.conf
if have ss; then
    capture "Listening sockets" ss -tulpn
elif have netstat; then
    capture "Listening sockets" netstat -tulpn
else
    emit "#### Listening sockets"
    emit "(neither \`ss\` nor \`netstat\` available)"
    emit ""
fi

# systemd may be installed without being the running init (e.g. containers)
HAS_SYSTEMD=no
[ -d /run/systemd/system ] && have systemctl && HAS_SYSTEMD=yes

# --------------------------------------------------------------- services
heading "Services"
if [ "$HAS_SYSTEMD" = "yes" ]; then
    capture "Failed units" systemctl --failed --no-pager --no-legend
    capture "Running services" systemctl list-units --type=service --state=running --no-pager --no-legend
    capture "Enabled timers" systemctl list-timers --no-pager --no-legend
elif have rc-status; then
    capture "OpenRC service status" rc-status -a
elif have service; then
    capture "Service status" service --status-all
else
    emit "#### Services"
    emit "(no running service manager detected - possibly a container)"
    emit ""
    capture "All processes" sh -c "ps aux | cut -c1-160"
fi

# ---------------------------------------------------------- logs & kernel
heading "Logs and kernel messages"
if [ "$HAS_SYSTEMD" = "yes" ] && have journalctl; then
    capture "Recent journal errors (priority err and above)" journalctl -p 3 -n 50 --no-pager
else
    capture_file "Recent syslog tail" /var/log/syslog
    capture_file "Recent messages tail" /var/log/messages
fi
capture "Kernel warnings/errors (dmesg)" sh -c "dmesg --level=err,warn 2>/dev/null | tail -n 50 || dmesg 2>/dev/null | tail -n 50"
capture "OOM killer events" sh -c "dmesg 2>/dev/null | grep -i 'out of memory\\|oom-kill' | tail -n 10"
if [ -r /proc/sys/kernel/tainted ]; then
    capture_file "Kernel taint flag (0 = untainted)" /proc/sys/kernel/tainted
fi

# ------------------------------------------------------ packages & updates
heading "Packages and pending updates"
if have apt-get; then
    emit "Package manager: apt"
    emit ""
    capture "Pending upgrades (simulation, read-only)" sh -c "apt-get -s upgrade 2>/dev/null | grep -E '^(Inst|[0-9]+ upgraded)'"
    if [ -f /var/run/reboot-required ]; then
        emit "**Note: /var/run/reboot-required exists - a reboot is pending.**"
        emit ""
    fi
elif have dnf; then
    emit "Package manager: dnf"
    emit ""
    capture "Pending updates" dnf -q check-update
elif have yum; then
    emit "Package manager: yum"
    emit ""
    capture "Pending updates" yum -q check-update
elif have zypper; then
    emit "Package manager: zypper"
    emit ""
    capture "Pending updates" zypper --non-interactive list-updates
elif have pacman; then
    emit "Package manager: pacman"
    emit ""
    capture "Pending updates (against local sync db)" pacman -Qu
elif have apk; then
    emit "Package manager: apk"
    emit ""
    capture "Pending upgrades (simulation, read-only)" apk upgrade -s
else
    emit "(no known package manager detected)"
    emit ""
fi

# --------------------------------------------------------------- security
heading "Security posture"
if [ -r /etc/ssh/sshd_config ]; then
    capture "SSH daemon settings of interest" sh -c "grep -iE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|Port|X11Forwarding|PermitEmptyPasswords|AllowUsers|AllowGroups)' /etc/ssh/sshd_config"
else
    emit "#### SSH daemon settings of interest"
    emit "(/etc/ssh/sshd_config not present or not readable)"
    emit ""
fi
if have ufw; then
    capture "Firewall (ufw)" ufw status verbose
elif have firewall-cmd; then
    capture "Firewall (firewalld)" firewall-cmd --state
    capture "Firewalld active zones" firewall-cmd --list-all
elif have nft; then
    capture "Firewall (nftables ruleset)" nft list ruleset
elif have iptables; then
    capture "Firewall (iptables rules)" iptables -S
else
    emit "#### Firewall"
    emit "(no known firewall tool found)"
    emit ""
fi
capture "Users with login shells" sh -c "grep -vE '(nologin|false)\$' /etc/passwd"
capture "Sudo group members" sh -c "getent group sudo wheel admin 2>/dev/null; true"
if [ "$IS_ROOT" = "yes" ]; then
    capture "Sudoers entries (comments stripped)" sh -c "grep -hvE '^[[:space:]]*(#|\$)' /etc/sudoers /etc/sudoers.d/* 2>/dev/null"
    capture "Recent failed logins" sh -c "lastb -n 15 2>/dev/null"
else
    emit "#### Sudoers / failed logins"
    emit "(requires root - skipped)"
    emit ""
fi
if have getenforce; then
    capture "SELinux status" getenforce
elif have aa-status; then
    capture "AppArmor status" aa-status
elif [ -d /sys/kernel/security/apparmor ]; then
    capture_file "AppArmor profiles" /sys/kernel/security/apparmor/profiles
else
    emit "#### Mandatory access control"
    emit "(neither SELinux nor AppArmor detected)"
    emit ""
fi

# ----------------------------------------------------------- scheduled jobs
heading "Scheduled jobs"
capture_file "System crontab" /etc/crontab
capture "Cron drop-ins (/etc/cron.d)" sh -c "ls -la /etc/cron.d/ 2>/dev/null && cat /etc/cron.d/* 2>/dev/null"
if have crontab; then
    capture "Current user's crontab" sh -c "crontab -l 2>&1"
else
    emit "#### Current user's crontab"
    emit "(tool \`crontab\` not available on this system)"
    emit ""
fi

# ------------------------------------------------------------- misc health
heading "Miscellaneous health"
if [ "$HAS_SYSTEMD" = "yes" ] && have timedatectl; then
    capture "Time synchronization" timedatectl
fi
capture "Logged-in users" who
capture "Last reboots" sh -c "last reboot 2>/dev/null | head -n 5"

status "Collection complete. Writing LLM prompt to stdout."

# ---------------------------------------------------------------- prompt
cat <<'PROMPT_HEADER'
You are a senior Linux system administrator. Below is a read-only
diagnostic report collected from a specific Linux host. Analyze it
thoroughly and identify:

1. Actual problems (failed services, errors in logs, resource exhaustion,
   OOM events, full disks, etc.)
2. Risky or bad configuration (insecure SSH settings, missing firewall,
   pending security updates, questionable cron jobs, world-open ports,
   time sync issues, etc.)
3. Optimization opportunities and general hygiene improvements.

IMPORTANT - answer format requirements:

- Answer in SCRIPT STYLE: every single finding must include a short
  explanation of what is wrong and why it matters, followed by a concrete
  fix as shell commands inside a fenced ```sh code block, so I can decide
  per item whether to execute/patch/apply it on this system.
- Commands must be copy-paste ready for exactly this distribution and
  init system (identify them from the report).
- Prefer safe and idempotent command variants. Clearly flag any command
  that is destructive, requires root, or requires a reboot with a
  WARNING line before the code block.
- Prioritize your findings: CRITICAL first, then IMPORTANT, then
  NICE-TO-HAVE.
- Some sections may be marked as truncated, unavailable, or skipped due
  to missing root privileges - take that into account and, where useful,
  include commands I can run to gather the missing information.

=== BEGIN SYSTEM DIAGNOSTIC REPORT ===

PROMPT_HEADER

printf 'Report generated as user: %s (root: %s)\n\n' "$(id -un 2>/dev/null || echo unknown)" "$IS_ROOT"
cat "$REPORT"

cat <<'PROMPT_FOOTER'
=== END SYSTEM DIAGNOSTIC REPORT ===

Reminder: respond in the prioritized, script-style format described above -
explanation plus a fenced ```sh block with ready-to-run commands for every
finding, flagging anything destructive or reboot-requiring.
PROMPT_FOOTER

status "Done. Paste the prompt above (or the redirected file) into Claude."

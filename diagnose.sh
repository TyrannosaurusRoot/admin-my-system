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
#   REDACT     - set to 1/yes/true/on to replace personal identifiers
#                (hostname, usernames, home paths, MACs, public IPs) with
#                consistent placeholders like [HOST-1] (default: off)

MAX_LINES="${MAX_LINES:-60}"
case "$MAX_LINES" in
    ''|*[!0-9]*) MAX_LINES=60 ;;
esac

case "${REDACT:-}" in
    1|[Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]) REDACT=yes ;;
    *) REDACT=no ;;
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

# Redaction rewrites the report through awk; emitting an unredacted report
# after the user asked for redaction would be worse than failing, so bail
# out early (before any collection) rather than degrade.
if [ "$REDACT" = "yes" ] && ! have awk; then
    status "ERROR: REDACT requested but awk is not available - refusing to emit an unredacted report."
    exit 1
fi

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

# -------------------------------------------------------------- redaction
# With REDACT=yes the finished report is streamed through redact_filter,
# which replaces each personal identifier with a consistent numbered
# placeholder (the same real value always maps to the same token, so the
# LLM can still correlate entities across sections). Loopback, link-local
# and RFC1918 private addresses stay visible - they do not identify the
# host publicly and help with local-network diagnosis.
if [ "$REDACT" = "yes" ]; then
    status "Building redaction lists ..."

    _passwd="$(getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null || true)"

    # hostnames: FQDN and short form, longest first
    RD_HOSTS="$( { uname -n 2>/dev/null; hostname 2>/dev/null; } | awk '
        NF && $0 != "localhost" && !seen[$0]++ {
            print length($0), $0
            n = split($0, p, ".")
            if (n > 1 && !seen[p[1]]++) print length(p[1]), p[1]
        }' | sort -rn | cut -d' ' -f2- )"

    # human users: UID >= 1000 plus the invoking user; never root or
    # system accounts (replacing "root" would mangle /root and semantics)
    RD_USERS="$( { id -un 2>/dev/null | grep -vx root; printf '%s\n' "$_passwd" | awk -F: '
        $3 + 0 >= 1000 && $3 + 0 != 65534 && $1 != "nobody" { print $1 }'; } | awk 'NF && !seen[$0]++' )"

    # GECOS real names of those users (the login-shell section leaks them);
    # skip names that are just the capitalized username (e.g. "Ubuntu")
    RD_NAMES="$(printf '%s\n' "$_passwd" | awk -F: '
        $3 + 0 >= 1000 && $3 + 0 != 65534 && $1 != "nobody" {
            split($5, g, ",")
            if (length(g[1]) > 2 && tolower(g[1]) != $1 && !seen[g[1]]++) print g[1]
        }')"

    # home dirs whose basename differs from the username (/home/alice is
    # already covered by the username replacement)
    RD_HOMES="$(printf '%s\n' "$_passwd" | awk -F: '
        $3 + 0 >= 1000 && $3 + 0 != 65534 && $1 != "nobody" && length($6) > 1 {
            n = split($6, p, "/")
            if (p[n] != $1 && !seen[$6]++) print $6
        }')"

    RD_DOMAINS="$(awk '/^[[:space:]]*(search|domain)[[:space:]]/ {
        for (i = 2; i <= NF; i++) if (length($i) > 1 && !seen[$i]++) print $i
    }' /etc/resolv.conf 2>/dev/null || true)"

    export RD_HOSTS RD_USERS RD_NAMES RD_HOMES RD_DOMAINS
fi

# redact_filter : stream filter replacing personal identifiers with
# consistent placeholders. Strictly POSIX awk: no gensub, no \b word
# boundaries, no {n,m} intervals (mawk/BusyBox portability).
redact_filter() {
    awk '
    BEGIN {
        WORD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        HEXC = "0123456789abcdefABCDEF:"
        H = "[0-9a-fA-F][0-9a-fA-F]"
        MAC_RE = H ":" H ":" H ":" H ":" H ":" H
        O = "[0-9][0-9]?[0-9]?"
        IPV4_RE = O "\\." O "\\." O "\\." O
        IPV6_RE = "[0-9a-fA-F:]*:[0-9a-fA-F:]*:[0-9a-fA-F:]*"
        nhome = split(ENVIRON["RD_HOMES"], homes, "\n")
        nhost = split(ENVIRON["RD_HOSTS"], hosts, "\n")
        nname = split(ENVIRON["RD_NAMES"], names, "\n")
        nuser = split(ENVIRON["RD_USERS"], users, "\n")
        ndom  = split(ENVIRON["RD_DOMAINS"], doms, "\n")
    }
    # same kind+value -> same numbered token, so the report stays correlatable
    function placeholder(kind, val) {
        if (!((kind, val) in map))
            map[kind, val] = "[" kind "-" (++cnt[kind]) "]"
        return map[kind, val]
    }
    function boundary_ok(chars, pre, post) {
        return (pre == "" || index(chars, pre) == 0) && (post == "" || index(chars, post) == 0)
    }
    # replace word-bounded occurrences of literal s; output is built
    # progressively so inserted placeholders are never re-scanned, and
    # lastc carries the boundary context across scan continuations
    function replace_literal(line, s, kind,    out, i, len, pre, post, lastc) {
        len = length(s)
        if (len == 0) return line
        out = ""
        lastc = ""
        while ((i = index(line, s)) > 0) {
            pre = (i > 1) ? substr(line, i - 1, 1) : lastc
            post = substr(line, i + len, 1)
            if (boundary_ok(WORD, pre, post)) {
                out = out substr(line, 1, i - 1) placeholder(kind, s)
                lastc = "]"
            } else {
                out = out substr(line, 1, i - 1 + len)
                lastc = substr(s, len, 1)
            }
            line = substr(line, i + len)
        }
        return out line
    }
    function replace_regex(line, re, kind, chars,    out, s, pre, post, lastc) {
        out = ""
        lastc = ""
        while (match(line, re) > 0) {
            s = substr(line, RSTART, RLENGTH)
            pre = (RSTART > 1) ? substr(line, RSTART - 1, 1) : lastc
            post = substr(line, RSTART + RLENGTH, 1)
            if (boundary_ok(chars, pre, post) && valid(kind, s)) {
                out = out substr(line, 1, RSTART - 1) placeholder(kind, s)
                lastc = "]"
            } else {
                out = out substr(line, 1, RSTART - 1 + RLENGTH)
                lastc = substr(s, length(s), 1)
            }
            line = substr(line, RSTART + RLENGTH)
        }
        return out line
    }
    function valid(kind, s) {
        if (kind == "IPV4") return ipv4_ok(s)
        if (kind == "IPV6") return ipv6_ok(s)
        return 1
    }
    # redact only public IPv4; loopback, unspecified, broadcast/netmask,
    # link-local and RFC1918 ranges stay visible
    function ipv4_ok(s,    p, n, i) {
        n = split(s, p, ".")
        if (n != 4) return 0
        for (i = 1; i <= 4; i++) if (p[i] + 0 > 255) return 0
        if (s == "0.0.0.0") return 0
        if (p[1] + 0 == 127 || p[1] + 0 == 10 || p[1] + 0 == 255) return 0
        if (p[1] + 0 == 192 && p[2] + 0 == 168) return 0
        if (p[1] + 0 == 172 && p[2] + 0 >= 16 && p[2] + 0 <= 31) return 0
        if (p[1] + 0 == 169 && p[2] + 0 == 254) return 0
        return 1
    }
    # candidates need "::" or >= 4 colons with 1-4 hex chars per group
    # (spares HH:MM:SS timestamps) and must be structurally plausible
    # (spares colon-separated fields like passwd lines);
    # loopback/link-local/ULA stay visible
    function ipv6_ok(s,    lc, i, colons, groups, n, p) {
        lc = tolower(s)
        if (lc == "::" || lc == "::1") return 0
        if (substr(lc, 1, 4) == "fe80") return 0
        if (substr(lc, 1, 2) == "fc" || substr(lc, 1, 2) == "fd") return 0
        if (substr(s, 1, 1) == ":" && substr(s, 1, 2) != "::") return 0
        if (substr(s, length(s), 1) == ":" && substr(s, length(s) - 1, 2) != "::") return 0
        i = index(s, "::")
        if (i > 0 && index(substr(s, i + 1), "::") > 0) return 0
        colons = 0
        for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ":") colons++
        if (index(s, "::") == 0 && colons < 4) return 0
        groups = 0
        n = split(s, p, ":")
        for (i = 1; i <= n; i++) {
            if (length(p[i]) > 4) return 0
            if (index(s, "::") == 0 && length(p[i]) < 1) return 0
            if (length(p[i]) > 0) groups++
        }
        if (groups > 8) return 0
        return 1
    }
    {
        line = $0
        for (i = 1; i <= nhome; i++) line = replace_literal(line, homes[i], "HOME")
        for (i = 1; i <= nhost; i++) line = replace_literal(line, hosts[i], "HOST")
        for (i = 1; i <= nname; i++) line = replace_literal(line, names[i], "NAME")
        for (i = 1; i <= nuser; i++) line = replace_literal(line, users[i], "USER")
        for (i = 1; i <= ndom;  i++) line = replace_literal(line, doms[i], "DOMAIN")
        line = replace_regex(line, MAC_RE, "MAC", HEXC)
        line = replace_regex(line, IPV6_RE, "IPV6", HEXC ".")
        line = replace_regex(line, IPV4_RE, "IPV4", "0123456789.")
        print line
    }
    '
}

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
PROMPT_HEADER

if [ "$REDACT" = "yes" ]; then
cat <<'REDACT_NOTE'
- Personal identifiers in this report (hostname, usernames, real names,
  home paths, MAC addresses, public IP addresses) were replaced with
  consistent placeholders such as [HOST-1], [USER-1], [IPV4-1]. The same
  placeholder always denotes the same real value. Use the placeholders
  verbatim wherever the real value would appear in your commands; I will
  substitute the real values before running them.
REDACT_NOTE
fi

printf '\n=== BEGIN SYSTEM DIAGNOSTIC REPORT ===\n\n'

emit_body() {
    printf 'Report generated as user: %s (root: %s)\n\n' "$(id -un 2>/dev/null || echo unknown)" "$IS_ROOT"
    cat "$REPORT"
}

if [ "$REDACT" = "yes" ]; then
    emit_body | redact_filter
else
    emit_body
fi

cat <<'PROMPT_FOOTER'
=== END SYSTEM DIAGNOSTIC REPORT ===

Reminder: respond in the prioritized, script-style format described above -
explanation plus a fenced ```sh block with ready-to-run commands for every
finding, flagging anything destructive or reboot-requiring.
PROMPT_FOOTER

status "Done. Paste the prompt above (or the redirected file) into Claude."

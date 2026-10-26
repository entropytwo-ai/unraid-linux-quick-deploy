#!/bin/bash
#
# unraid-quick-deploy.sh - Quickly deploy Linux on Unraid as a VM, a Docker
# container, or both.
#
#   * VM path     : QEMU/KVM through libvirt (the engine behind Unraid's VM
#                   Manager). Disks live in the 'domains' share, ISOs in the
#                   'isos' share, and the generated XML carries Unraid's
#                   <vmtemplate> metadata so the VM shows up with an icon in
#                   the VMS tab.
#   * Docker path : 'docker run' with config stored in the 'appdata' share and,
#                   optionally, a dockerMan user template so the container can
#                   be edited from the DOCKER tab.
#
# Every detected Unraid setting is shown before anything happens, and each one
# can be accepted with Enter or overridden.
#
# Project: https://github.com/entropytwo-ai/unraid-linux-quick-deploy
# License: MIT
#
# Every setting can also be preset from the environment, e.g.:
#   DEPLOY_TYPE=vm OS_CHOICE=1 VM_MEMORY=4096 ./unraid-quick-deploy.sh
# Combine with --yes to run fully unattended.

set -Eeuo pipefail

QD_VERSION="1.0.0"

# =============================================================================
# CONFIGURATION (override any of these via environment variables)
# =============================================================================
UNRAID_BOOT_CONFIG="${UNRAID_BOOT_CONFIG:-/boot/config}"   # Unraid flash config dir
UNRAID_USER_SHARE="${UNRAID_USER_SHARE:-/mnt/user}"         # user share root
UNRAID_VERSION_FILE="${UNRAID_VERSION_FILE:-/etc/unraid-version}"
UNRAID_VM_ICON_DIR="${UNRAID_VM_ICON_DIR:-/usr/local/emhttp/plugins/dynamix.vm.manager/templates/images}"
NVRAM_DIR="${NVRAM_DIR:-/etc/libvirt/qemu/nvram}"           # Unraid keeps OVMF vars here
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"
LOG_DIR="${LOG_DIR:-/tmp}"

ASSUME_YES="${ASSUME_YES:-0}"     # 1 = accept every default, never prompt
DRY_RUN="${DRY_RUN:-0}"           # 1 = show what would happen, change nothing
DEPLOY_TYPE="${DEPLOY_TYPE:-}"    # vm | docker | both   (or 1 | 2 | 3)
OS_CHOICE="${OS_CHOICE:-}"        # 1-16, c (custom) or an id such as debian-stable (see --list)
LIST_ONLY=0

# Storage paths (empty = auto-detect from Unraid config)
DOMAINS_PATH="${DOMAINS_PATH:-}"
ISO_PATH="${ISO_PATH:-}"
APPDATA_PATH="${APPDATA_PATH:-}"
CLOUD_CACHE="${CLOUD_CACHE:-}"

# VM settings
VM_MODE="${VM_MODE:-}"            # cloud | iso
VM_NAME="${VM_NAME:-}"
VM_CPUS="${VM_CPUS:-2}"
VM_CPU_PIN="${VM_CPU_PIN:-}"      # e.g. "2,3" (empty = no pinning)
VM_MEMORY="${VM_MEMORY:-2048}"    # MiB
VM_DISK_SIZE="${VM_DISK_SIZE:-20G}"
VM_DISK_FORMAT="${VM_DISK_FORMAT:-qcow2}"
VM_DISK_NAME="${VM_DISK_NAME:-vdisk1.img}"   # Unraid's own naming convention
VM_MACHINE="${VM_MACHINE:-q35}"   # q35 | i440fx
VM_BIOS="${VM_BIOS:-seabios}"     # seabios | ovmf
VM_BRIDGE="${VM_BRIDGE:-}"
VM_VNC_LISTEN="${VM_VNC_LISTEN:-0.0.0.0}"
VM_VNC_KEYMAP="${VM_VNC_KEYMAP:-en-us}"
VM_ISO_FILE="${VM_ISO_FILE:-}"    # installer ISO (iso mode)
VM_AUTOSTART="${VM_AUTOSTART:-no}"
VM_START="${VM_START:-yes}"
DEFAULT_USER="${DEFAULT_USER:-admin}"
DEFAULT_PASS="${DEFAULT_PASS:-password123}"
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-}"   # override the distro's cloud image URL
ISO_URL="${ISO_URL:-}"                   # override the distro's installer ISO URL
CLOUD_IMAGE_SUM_URL="${CLOUD_IMAGE_SUM_URL:-}"  # checksum file for a CLOUD_IMAGE_URL override
ISO_SUM_URL="${ISO_SUM_URL:-}"           # checksum file for an ISO_URL override
VERIFY_CHECKSUMS="${VERIFY_CHECKSUMS:-yes}"     # no = skip checksum verification (not recommended)

# Docker settings
CONTAINER_NAME="${CONTAINER_NAME:-}"
DOCKER_IMAGE="${DOCKER_IMAGE:-}"
DOCKER_APPDATA="${DOCKER_APPDATA:-}"
DOCKER_CONFIG_TARGET="${DOCKER_CONFIG_TARGET:-/config}"
DOCKER_PORTS="${DOCKER_PORTS:-}"         # "8080:80,2222:22/tcp"
DOCKER_VOLUMES="${DOCKER_VOLUMES:-}"     # "/mnt/user/data:/data:rw,/mnt/user/media:/media:ro"
DOCKER_ENV="${DOCKER_ENV:-}"             # "FOO=bar,BAZ=qux"
DOCKER_NETWORK="${DOCKER_NETWORK:-bridge}"
DOCKER_RESTART="${DOCKER_RESTART:-unless-stopped}"
DOCKER_CMD="${DOCKER_CMD:-tail -f /dev/null}"
DOCKER_PUID="${DOCKER_PUID:-99}"         # Unraid 'nobody'
DOCKER_PGID="${DOCKER_PGID:-100}"        # Unraid 'users'
DOCKER_TEMPLATE="${DOCKER_TEMPLATE:-yes}"
FEDORA_VERSION="${FEDORA_VERSION:-}"     # empty = newest release
# =============================================================================

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_FILE:-${LOG_DIR%/}/unraid-quick-deploy-${TIMESTAMP}.log}"

# ---------------------------------------------------------------------------
# Command-line flags
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Unraid Quick Deploy Linux v${QD_VERSION}

Usage: $(basename "$0") [options]

Options:
  -y, --yes       Accept every detected/default value without prompting
  -n, --dry-run   Detect, prompt and generate configs, but change nothing
  -l, --list      Look up and print the image/ISO every menu entry points to
                  right now (no root needed, changes nothing), then exit
  -h, --help      Show this help
  -V, --version   Show version

Any setting can be preset from the environment (see README.md), e.g.:
  DEPLOY_TYPE=both OS_CHOICE=3 VM_MEMORY=4096 CONTAINER_NAME=deb $(basename "$0")
EOF
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -l|--list) LIST_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        -V|--version) echo "$QD_VERSION"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Output, colours & logging
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'; C_ORANGE=$'\e[38;5;208m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_ORANGE=""
fi

if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
    echo "[!] Cannot write log file $LOG_FILE (set LOG_DIR to a writable directory)." >&2
    exit 1
fi
exec 3>>"$LOG_FILE"

_log()  { printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$1" "$2" >&3; }
info()  { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; _log INFO "$*"; }
ok()    { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _log OK "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log WARN "$*"; }
err()   { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log ERROR "$*"; }
die()   { err "$*"; print_summary "FAILED"; exit 1; }

STEP_NO=0
step() {
    STEP_NO=$((STEP_NO + 1))
    printf '\n%s%s━━ Step %d: %s %s%s\n' "$C_BOLD" "$C_ORANGE" "$STEP_NO" "$1" \
        "$(printf '━%.0s' $(seq 1 $((50 - ${#1} > 3 ? 50 - ${#1} : 3))))" "$C_RESET"
    _log STEP "$STEP_NO: $1"
}

# run CMD...  - log the command, then execute it (output to terminal + log).
# Honours DRY_RUN: the command is printed but not executed.
run() {
    _log CMD "$(printf '%q ' "$@")"
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '%s    [dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$(printf '%q ' "$@")"
        return 0
    fi
    "$@" 2>&1 | tee -a "$LOG_FILE"
}

# run_q CMD...  - like run, but output goes to the log only.
run_q() {
    _log CMD "$(printf '%q ' "$@")"
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '%s    [dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$(printf '%q ' "$@")"
        return 0
    fi
    "$@" >>"$LOG_FILE" 2>&1
}

# write_file PATH  (content on stdin). In dry-run it goes to a scratch dir.
DRY_DIR=""
write_file() {
    local path="$1"
    if [[ "$DRY_RUN" == 1 ]]; then
        [[ -z "$DRY_DIR" ]] && DRY_DIR="$(mktemp -d "${LOG_DIR%/}/unraid-quick-deploy-dryrun-XXXX")"
        path="${DRY_DIR}/$(basename "$1")"
        printf '%s    [dry-run]%s would write %s  (preview: %s)\n' "$C_DIM" "$C_RESET" "$1" "$path"
    fi
    cat >"$path"
    _log FILE "wrote $path"
    LAST_WRITTEN="$path"
}

with_timeout() {
    if command -v timeout &>/dev/null; then timeout "$@"; else shift; "$@"; fi
}

# ---------------------------------------------------------------------------
# Summary bookkeeping
# ---------------------------------------------------------------------------
SUMMARY_KEYS=(); SUMMARY_VALS=(); CREATED=(); NEXT_STEPS=()
add_summary() { SUMMARY_KEYS+=("$1"); SUMMARY_VALS+=("$2"); _log SUM "$1 = $2"; }
add_created() { CREATED+=("$1"); _log MADE "$1"; }
add_next()    { NEXT_STEPS+=("$1"); }

SUMMARY_PRINTED=0
print_summary() {
    local status="$1" i line color
    [[ "$SUMMARY_PRINTED" == 1 ]] && return 0
    SUMMARY_PRINTED=1
    case "$status" in SUCCESS) color="$C_GREEN" ;; DRY-RUN) color="$C_CYAN" ;; *) color="$C_RED" ;; esac
    line="$(printf '═%.0s' $(seq 1 64))"
    printf '\n%s%s%s%s\n' "$C_BOLD" "$color" "$line" "$C_RESET"
    printf '%s%s  Unraid Quick Deploy - %s%s\n' "$C_BOLD" "$color" "$status" "$C_RESET"
    printf '%s%s%s%s\n' "$C_BOLD" "$color" "$line" "$C_RESET"
    for i in "${!SUMMARY_KEYS[@]}"; do
        printf '  %s%-22s%s %s\n' "$C_BOLD" "${SUMMARY_KEYS[$i]}" "$C_RESET" "${SUMMARY_VALS[$i]}"
    done
    if [[ ${#CREATED[@]} -gt 0 ]]; then
        printf '\n  %sCreated:%s\n' "$C_BOLD" "$C_RESET"
        for i in "${CREATED[@]}"; do printf '    • %s\n' "$i"; done
    fi
    if [[ ${#NEXT_STEPS[@]} -gt 0 && "$status" != "FAILED" ]]; then
        printf '\n  %sNext steps:%s\n' "$C_BOLD" "$C_RESET"
        for i in "${NEXT_STEPS[@]}"; do printf '    → %s\n' "$i"; done
    fi
    printf '\n  %sLog file:%s %s\n' "$C_BOLD" "$C_RESET" "$LOG_FILE"
    printf '%s%s%s%s\n' "$C_BOLD" "$color" "$line" "$C_RESET"
    _log END "status=$status"
}

on_error() {
    local rc=$? line="$1" cmd="$2"
    trap - ERR
    err "Command failed (exit $rc) at line $line: $cmd"
    print_summary "FAILED"
    exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap 'printf "\n"; warn "Interrupted by user."; print_summary "FAILED"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Prompts & validation
# ---------------------------------------------------------------------------
TTY_IN=""
if [[ -t 0 ]]; then TTY_IN=/dev/stdin
elif [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then TTY_IN=/dev/tty
fi
if [[ -z "$TTY_IN" && "$ASSUME_YES" != 1 ]]; then
    ASSUME_YES=1
    warn "No terminal available for input - continuing with defaults (as if --yes)."
fi

is_yes() { [[ "${1,,}" =~ ^(y|yes|1|true|on)$ ]]; }

# prompt LABEL DEFAULT -> prints the answer (default on empty input)
prompt() {
    local label="$1" def="$2" ans=""
    if [[ "$ASSUME_YES" == 1 ]]; then printf '%s\n' "$def"; return 0; fi
    printf '  %s%s%s [%s%s%s]: ' "$C_BOLD" "$label" "$C_RESET" "$C_CYAN" "$def" "$C_RESET" >&2
    IFS= read -r ans <"$TTY_IN" || true
    printf '%s\n' "${ans:-$def}"
}

validate() {
    local type="$1" v="$2" item
    case "$type" in
        any) return 0 ;;
        nonempty) [[ -n "$v" ]] ;;
        posint) [[ "$v" =~ ^[1-9][0-9]*$ ]] ;;
        mib) [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 256 )) ;;
        size) [[ "$v" =~ ^[1-9][0-9]*[MGT]$ ]] ;;
        name) [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] ;;
        yesno) [[ "${v,,}" =~ ^(y|yes|n|no|1|0|true|false|on|off)$ ]] ;;
        abspath) [[ "$v" == /* && "$v" != *[[:space:]]* ]] ;;
        isofile) [[ "$v" == /* || "$v" =~ ^(https?|ftp|file):// ]] ;;
        user) [[ "$v" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$v" != root ]] ;;
        pass) [[ -n "$v" && "$v" != *"'"* ]] ;;
        cpuset)
            [[ -z "$v" ]] && return 0
            [[ "$v" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
            for item in ${v//,/ }; do (( item < CPU_TOTAL )) || return 1; done ;;
        ports)
            [[ -z "$v" ]] && return 0
            for item in ${v//,/ }; do [[ "$item" =~ ^[0-9]{1,5}:[0-9]{1,5}(/(tcp|udp))?$ ]] || return 1; done ;;
        volumes)
            [[ -z "$v" ]] && return 0
            for item in ${v//,/ }; do [[ "$item" =~ ^/[^:]+:/[^:]+(:(ro|rw))?$ ]] || return 1; done ;;
        envlist)
            [[ -z "$v" ]] && return 0
            for item in ${v//,/ }; do [[ "$item" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || return 1; done ;;
        image) [[ "$v" =~ ^[a-z0-9]([a-z0-9._/:@-]*[a-zA-Z0-9._-])?$ ]] ;;
        restart) [[ "$v" =~ ^(no|always|unless-stopped|on-failure(:[0-9]+)?)$ ]] ;;
        machine) [[ "$v" =~ ^(q35|i440fx)$ ]] ;;
        bios) [[ "$v" =~ ^(seabios|ovmf)$ ]] ;;
        format) [[ "$v" =~ ^(qcow2|raw)$ ]] ;;
        vmmode) [[ "$v" =~ ^(cloud|iso)$ ]] ;;
        *) return 1 ;;
    esac
}

hint_for() {
    case "$1" in
        posint) echo "a whole number > 0" ;; mib) echo "MiB, at least 256" ;;
        size) echo "e.g. 20G, 512M, 1T" ;; name) echo "letters, digits, . _ - (max 63)" ;;
        yesno) echo "yes or no" ;; abspath) echo "absolute path without spaces" ;;
        isofile) echo "absolute path or http(s):// URL" ;; user) echo "lowercase Linux user name (not root)" ;;
        pass) echo "non-empty, no single quotes" ;; cpuset) echo "comma list of core numbers < $CPU_TOTAL, or blank" ;;
        ports) echo "host:container[/tcp|udp], comma separated" ;; volumes) echo "/host:/container[:ro|rw], comma separated" ;;
        envlist) echo "KEY=value, comma separated" ;; image) echo "e.g. ubuntu:24.04" ;;
        restart) echo "no | always | unless-stopped | on-failure[:N]" ;; machine) echo "q35 or i440fx" ;;
        bios) echo "seabios or ovmf" ;; format) echo "qcow2 or raw" ;; vmmode) echo "cloud or iso" ;;
        *) echo "a valid value" ;;
    esac
}

# ask VAR LABEL TYPE  - prompt for VAR (current value is the default), loop until valid.
ask() {
    local var="$1" label="$2" type="${3:-any}" ans tries=0
    while true; do
        ans="$(prompt "$label" "${!var-}")"
        if validate "$type" "$ans"; then
            printf -v "$var" '%s' "$ans"
            if [[ "$var" == *PASS* ]]; then _log INPUT "$var=********"; else _log INPUT "$var=$ans"; fi
            return 0
        fi
        warn "Invalid value '${ans}' for ${label} - expected $(hint_for "$type")."
        tries=$((tries + 1))
        [[ "$ASSUME_YES" == 1 || $tries -ge 5 ]] && die "No valid value for ${label}."
    done
}

confirm() {  # confirm QUESTION DEFAULT(y|n)
    local ans
    ans="$(prompt "$1 (y/n)" "$2")"
    _log INPUT "$1 -> $ans"
    is_yes "$ans"
}

# cfg_get FILE KEY  - read KEY="value" from an Unraid .cfg file
cfg_get() {
    [[ -r "$1" ]] || return 0
    awk -v k="$2" '{ sub(/\r$/, "") }
        index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/^"|"$/, "", v); val = v }
        END { if (val != "") print val }' "$1"
}

table_row() { printf '  %-28s %s%-34s%s %s%s%s\n' "$1" "$C_CYAN" "$2" "$C_RESET" "$C_DIM" "${3:-}" "$C_RESET"; }
table_rule() { printf '  %s%s%s\n' "$C_DIM" "$(printf '─%.0s' $(seq 1 78))" "$C_RESET"; }

xml_esc() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; s="${s//\'/&apos;}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
banner() {
    printf '%s%s' "$C_ORANGE" "$C_BOLD"
    cat <<'EOF'
   _   _                 _     _    ___       _      _
  | | | |_ __  _ __ __ _(_) __| |  / _ \ _  _(_) ___| | __
  | | | | '_ \| '__/ _` | |/ _` | | | | | || | |/ __| |/ /
  | |_| | | | | | | (_| | | (_| | | |_| | || | | (__|   <
   \___/|_| |_|_|  \__,_|_|\__,_|  \__\_\\_,_|_|\___|_|\_\
          D E P L O Y   L I N U X   -   VM  |  Docker
EOF
    printf '%s  v%s   log: %s%s\n' "$C_RESET$C_DIM" "$QD_VERSION" "$LOG_FILE" "$C_RESET"
    [[ "$DRY_RUN" == 1 ]] && printf '  %s%sDRY-RUN: nothing will be changed on this server.%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    return 0
}

# =============================================================================
# 1. Environment detection
# =============================================================================
detect_environment() {
    step "Detecting Unraid environment"

    IS_UNRAID=0; UNRAID_VERSION="not detected"
    if [[ -r "$UNRAID_VERSION_FILE" ]]; then
        IS_UNRAID=1
        UNRAID_VERSION="$(sed -n 's/^version="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$UNRAID_VERSION_FILE" | head -n1)"
        UNRAID_VERSION="${UNRAID_VERSION:-unknown}"
    fi
    HOST_NAME="$(hostname 2>/dev/null || echo unraid)"
    SERVER_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}' || true)"
    SERVER_IP="${SERVER_IP:-<server-ip>}"

    CPU_TOTAL="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
    CPU_MODEL="$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    MEM_TOTAL_MIB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
    MEM_AVAIL_MIB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
    HW_VIRT="no"; grep -Eqw 'vmx|svm' /proc/cpuinfo 2>/dev/null && HW_VIRT="yes"
    KVM_DEV="missing"; [[ -e /dev/kvm ]] && KVM_DEV="present"

    # VM Manager (Settings -> VM Manager) - /boot/config/domain.cfg
    DOMAIN_CFG="${UNRAID_BOOT_CONFIG}/domain.cfg"
    VM_SERVICE="$(cfg_get "$DOMAIN_CFG" SERVICE)"
    CFG_DOMAINDIR="$(cfg_get "$DOMAIN_CFG" DOMAINDIR)"
    CFG_MEDIADIR="$(cfg_get "$DOMAIN_CFG" MEDIADIR)"
    CFG_BRNAME="$(cfg_get "$DOMAIN_CFG" BRNAME)"
    VM_PLUGIN="no"; [[ -d "${UNRAID_BOOT_CONFIG}/plugins/dynamix.vm.manager" ]] && VM_PLUGIN="yes"
    if [[ "$VM_SERVICE" == "enable" ]]; then VM_MANAGER="enabled"
    elif [[ -n "$VM_SERVICE" ]]; then VM_MANAGER="disabled"
    elif command -v virsh &>/dev/null; then VM_MANAGER="unknown (no domain.cfg, virsh present)"
    else VM_MANAGER="not available"; fi

    # Docker (Settings -> Docker) - /boot/config/docker.cfg
    DOCKER_CFG="${UNRAID_BOOT_CONFIG}/docker.cfg"
    CFG_DOCKER_ENABLED="$(cfg_get "$DOCKER_CFG" DOCKER_ENABLED)"
    CFG_DOCKER_IMAGE="$(cfg_get "$DOCKER_CFG" DOCKER_IMAGE_FILE)"
    CFG_APPDATA="$(cfg_get "$DOCKER_CFG" DOCKER_APP_CONFIG_PATH)"
    CFG_DOCKER_FS="$(cfg_get "$DOCKER_CFG" DOCKER_BACKINGFS)"
    CFG_DOCKER_TYPE="$(cfg_get "$DOCKER_CFG" DOCKER_IMAGE_TYPE)"
    DOCKER_SOCK_STATE="missing"; [[ -S "$DOCKER_SOCK" ]] && DOCKER_SOCK_STATE="present"
    if [[ "$CFG_DOCKER_ENABLED" == "yes" ]]; then DOCKER_STATE="enabled"
    elif [[ -n "$CFG_DOCKER_ENABLED" ]]; then DOCKER_STATE="disabled"
    elif [[ "$DOCKER_SOCK_STATE" == present ]]; then DOCKER_STATE="unknown (no docker.cfg, socket present)"
    else DOCKER_STATE="not available"; fi
    DOCKER_DRIVER="${CFG_DOCKER_FS:-${CFG_DOCKER_TYPE:-unknown}}"
    if [[ "$DOCKER_SOCK_STATE" == present ]] && command -v docker &>/dev/null; then
        local drv
        drv="$(with_timeout 10 docker info --format '{{.Driver}}' 2>/dev/null || true)"
        [[ -n "$drv" ]] && DOCKER_DRIVER="$drv"
    fi

    # Share defaults (Unraid stock layout unless the config says otherwise)
    DET_DOMAINS="${CFG_DOMAINDIR:-${UNRAID_USER_SHARE}/domains}"; DET_DOMAINS="${DET_DOMAINS%/}"
    DET_ISOS="${CFG_MEDIADIR:-${UNRAID_USER_SHARE}/isos}";        DET_ISOS="${DET_ISOS%/}"
    DET_APPDATA="${CFG_APPDATA:-${UNRAID_USER_SHARE}/appdata}";   DET_APPDATA="${DET_APPDATA%/}"
    DOMAINS_PATH="${DOMAINS_PATH:-$DET_DOMAINS}"
    ISO_PATH="${ISO_PATH:-$DET_ISOS}"
    APPDATA_PATH="${APPDATA_PATH:-$DET_APPDATA}"
    ARRAY_STATE="not mounted"; [[ -d "$UNRAID_USER_SHARE" ]] && ARRAY_STATE="mounted"

    # Network bridge for VMs: domain.cfg BRNAME -> br0 -> virbr0 -> first bridge
    local b
    DET_BRIDGE=""
    for b in "$CFG_BRNAME" br0 virbr0; do
        if [[ -n "$b" && -d "/sys/class/net/$b" ]]; then DET_BRIDGE="$b"; break; fi
    done
    if [[ -z "$DET_BRIDGE" ]]; then
        DET_BRIDGE="$(for b in /sys/class/net/*/bridge; do [[ -d "$b" ]] && basename "$(dirname "$b")"; done 2>/dev/null | head -n1 || true)"
    fi
    DET_BRIDGE="${DET_BRIDGE:-${CFG_BRNAME:-br0}}"
    VM_BRIDGE="${VM_BRIDGE:-$DET_BRIDGE}"

    # Time zone: Unraid ident.cfg -> /etc/localtime
    DET_TZ="$(cfg_get "${UNRAID_BOOT_CONFIG}/ident.cfg" timeZone)"
    if [[ -z "$DET_TZ" && -L /etc/localtime ]]; then
        DET_TZ="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
    fi
    DET_TZ="${DET_TZ:-Etc/UTC}"

    printf '\n'
    table_row "SETTING" "DETECTED VALUE" "SOURCE"; table_rule
    table_row "Unraid version" "$UNRAID_VERSION" "$UNRAID_VERSION_FILE"
    table_row "Server" "$HOST_NAME ($SERVER_IP)" "hostname / ip"
    table_row "CPU threads" "$CPU_TOTAL" "${CPU_MODEL:0:40}"
    table_row "RAM total / available" "${MEM_TOTAL_MIB} / ${MEM_AVAIL_MIB} MiB" "/proc/meminfo"
    table_row "HW virtualization / KVM" "$HW_VIRT / $KVM_DEV" "/proc/cpuinfo, /dev/kvm"
    table_row "Array / user shares" "$ARRAY_STATE" "$UNRAID_USER_SHARE"
    table_row "VM Manager" "$VM_MANAGER" "$DOMAIN_CFG"
    table_row "VM Manager plugin dir" "$VM_PLUGIN" "${UNRAID_BOOT_CONFIG}/plugins/dynamix.vm.manager"
    table_row "VM disk share (domains)" "$DET_DOMAINS" "DOMAINDIR"
    table_row "ISO share (isos)" "$DET_ISOS" "MEDIADIR"
    table_row "VM network bridge" "$DET_BRIDGE" "BRNAME / /sys/class/net"
    table_row "Docker service" "$DOCKER_STATE" "$DOCKER_CFG"
    table_row "Docker socket" "$DOCKER_SOCK_STATE" "$DOCKER_SOCK"
    table_row "Docker storage driver" "$DOCKER_DRIVER" "docker info / DOCKER_BACKINGFS"
    table_row "Docker vDisk / directory" "${CFG_DOCKER_IMAGE:-n/a}" "DOCKER_IMAGE_FILE"
    table_row "Docker appdata share" "$DET_APPDATA" "DOCKER_APP_CONFIG_PATH"
    table_row "Time zone" "$DET_TZ" "ident.cfg / localtime"
    table_rule

    for b in UNRAID_VERSION CPU_TOTAL MEM_TOTAL_MIB MEM_AVAIL_MIB HW_VIRT KVM_DEV VM_MANAGER DET_DOMAINS \
             DET_ISOS DET_BRIDGE DOCKER_STATE DOCKER_SOCK_STATE DOCKER_DRIVER DET_APPDATA DET_TZ ARRAY_STATE; do
        _log DETECT "$b=${!b}"
    done

    if [[ "$IS_UNRAID" != 1 ]]; then
        warn "This does not look like an Unraid server ($UNRAID_VERSION_FILE not found)."
        confirm "Continue anyway?" "n" || die "Aborted: not an Unraid server."
    fi
    if [[ "$ARRAY_STATE" != mounted ]]; then
        warn "$UNRAID_USER_SHARE is not available - is the array started?"
    fi
}

# =============================================================================
# 2. Deployment type
# =============================================================================
choose_deploy_type() {
    step "Choose deployment type"
    if [[ -z "$DEPLOY_TYPE" ]]; then
        printf '  Deploy as:  %s[1]%s VM (QEMU/KVM)   %s[2]%s Docker container   %s[3]%s Both\n' \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        DEPLOY_TYPE="$(prompt "Select 1-3" "1")"
    fi
    case "${DEPLOY_TYPE,,}" in
        1|vm) DO_VM=1; DO_DOCKER=0; DEPLOY_TYPE=vm ;;
        2|docker|container) DO_VM=0; DO_DOCKER=1; DEPLOY_TYPE=docker ;;
        3|both) DO_VM=1; DO_DOCKER=1; DEPLOY_TYPE=both ;;
        *) die "Invalid deployment type: '$DEPLOY_TYPE' (use 1/vm, 2/docker or 3/both)." ;;
    esac
    ok "Deployment type: $DEPLOY_TYPE"
}

# =============================================================================
# 3. Dependency validation - every tool is executed, not just located
# =============================================================================
# check_tool LABEL CMD ARGS...  - binary must be on PATH, executable, and the
# probe command must succeed. Stores the first output line in TOOL_OUT.
TOOL_OUT=""
check_tool() {
    local label="$1" bin="$2" path out rc=0
    shift
    path="$(command -v "$bin" 2>/dev/null || true)"
    if [[ -z "$path" ]]; then err "$label: '$bin' not found on PATH."; return 1; fi
    if [[ ! -x "$path" ]]; then err "$label: $path is not executable."; return 1; fi
    out="$(with_timeout 30 "$@" 2>&1)" || rc=$?
    _log PROBE "$* -> rc=$rc: $(printf '%s' "$out" | head -n3 | tr '\n' ' ')"
    if [[ $rc -ne 0 ]]; then
        err "$label: '$*' failed (exit $rc): $(printf '%s' "$out" | head -n1)"
        return 1
    fi
    TOOL_OUT="$(printf '%s' "$out" | head -n1 | cut -c1-70)"
    ok "$label: $path  ($TOOL_OUT)"
}

DOWNLOADER=""
CLOUD_URL=""; CLOUD_FILE=""; CLOUD_SUM_URL=""; CLOUD_LABEL=""; ISO_FILE=""; ISO_LABEL=""
validate_common() {
    local t missing=0
    [[ $EUID -eq 0 ]] || die "Run this script as root (Unraid's terminal logs in as root)."
    (( BASH_VERSINFO[0] >= 4 )) || die "Bash 4+ is required (found $BASH_VERSION)."
    for t in awk sed grep sort tee mktemp seq cut tr wc tac basename du; do
        command -v "$t" &>/dev/null || { err "Required tool '$t' is missing."; missing=1; }
    done
    [[ $missing -eq 0 ]] || die "Basic shell tools are missing."
    detect_downloader
    validate_lookup_tools
}

# detect_downloader - curl (preferred) or wget, each actually executed
detect_downloader() {
    if check_tool "Downloader (curl)" curl --version; then DOWNLOADER=curl
    elif check_tool "Downloader (wget)" wget --version; then DOWNLOADER=wget
    else die "Neither curl nor wget works - cannot download images."; fi
}

# validate_lookup_tools - the release lookup and checksum code needs these to
# actually work, not just exist: the hash tools must produce the known digest
# of an empty input, 'sort -V' must order versions, and 'date -d' must parse
# an HTTP date (GNU coreutils behaviour; BusyBox differs).
validate_lookup_tools() {
    local bad=0
    if [[ "$(printf '' | sha256sum 2>/dev/null | cut -d' ' -f1)" == e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]]; then
        ok "sha256sum works"
    else err "sha256sum is missing or broken - downloads cannot be verified."; bad=1; fi
    if [[ "$(printf '' | sha512sum 2>/dev/null | cut -c1-16)" == cf83e1357eefb8bd ]]; then
        ok "sha512sum works"
    else err "sha512sum is missing or broken - Debian/Alpine downloads cannot be verified."; bad=1; fi
    if [[ "$(printf '1.10\n1.9\n1.2\n' | sort -V 2>/dev/null | tail -n1)" == 1.10 ]]; then
        ok "sort -V (version sort) works"
    else err "'sort -V' is not supported - the newest release cannot be picked."; bad=1; fi
    if [[ "$(date -u -d 'Mon, 05 Oct 2026 10:00:00 GMT' +%Y%m%d 2>/dev/null)" == 20261005 ]]; then
        ok "date -d (HTTP date parsing) works"
    else warn "'date -d' cannot parse HTTP dates - NixOS/CentOS ISOs will be named by today's date instead."; fi
    [[ $bad -eq 0 ]] || die "Tools needed to look up and verify images are missing (see above)."
}

VM_OK=1; DOCKER_OK=1
validate_vm_deps() {
    info "Validating VM prerequisites..."
    VM_OK=1
    if [[ "$VM_MANAGER" == "disabled" || "$VM_MANAGER" == "not available" ]]; then
        err "Unraid VM Manager is $VM_MANAGER. Enable it in Settings -> VM Manager -> Enable VMs: Yes."
        VM_OK=0
    fi
    check_tool "virsh (libvirt)" virsh version || VM_OK=0
    if [[ $VM_OK == 1 ]]; then
        check_tool "libvirt capabilities" virsh capabilities >/dev/null || VM_OK=0
    fi
    check_tool "qemu-img" qemu-img --version || VM_OK=0
    if [[ "$KVM_DEV" != present ]]; then
        warn "/dev/kvm is missing - enable VT-x/AMD-V (SVM) in the BIOS. VMs will fail to start without it."
    fi
    if [[ $VM_OK == 1 ]]; then detect_libvirt_caps; fi
    return 0
}

validate_docker_deps() {
    info "Validating Docker prerequisites..."
    DOCKER_OK=1
    if [[ "$DOCKER_STATE" == "disabled" ]]; then
        err "Unraid Docker service is disabled. Enable it in Settings -> Docker -> Enable Docker: Yes."
        DOCKER_OK=0
    fi
    if [[ ! -S "$DOCKER_SOCK" ]]; then err "Docker socket $DOCKER_SOCK not found - is the Docker service running?"; DOCKER_OK=0; fi
    check_tool "docker client" docker --version || DOCKER_OK=0
    if [[ $DOCKER_OK == 1 ]]; then
        check_tool "docker daemon" docker info --format '{{.ServerVersion}} (driver: {{.Driver}})' || DOCKER_OK=0
    fi
    return 0
}

validate_deps() {
    step "Validating required tools (functional checks)"
    validate_common
    [[ $DO_VM == 1 ]] && validate_vm_deps
    [[ $DO_DOCKER == 1 ]] && validate_docker_deps
    if [[ $DO_VM == 1 && $DO_DOCKER == 1 ]]; then
        if [[ $VM_OK == 0 && $DOCKER_OK == 0 ]]; then die "Neither the VM nor the Docker prerequisites are met."; fi
        if [[ $VM_OK == 0 ]]; then
            confirm "VM prerequisites failed. Continue with Docker only?" "n" || die "VM prerequisites not met."
            DO_VM=0; DEPLOY_TYPE=docker
        elif [[ $DOCKER_OK == 0 ]]; then
            confirm "Docker prerequisites failed. Continue with the VM only?" "n" || die "Docker prerequisites not met."
            DO_DOCKER=0; DEPLOY_TYPE=vm
        fi
    else
        [[ $DO_VM == 1 && $VM_OK == 0 ]] && die "VM prerequisites not met (see errors above)."
        [[ $DO_DOCKER == 1 && $DOCKER_OK == 0 ]] && die "Docker prerequisites not met (see errors above)."
    fi
    ok "All required tools for '$DEPLOY_TYPE' are present and working."
}

# Emulator, machine types and OVMF firmware as this server's libvirt reports them
detect_libvirt_caps() {
    local caps f
    caps="$(virsh capabilities 2>/dev/null || true)"
    QEMU_EMULATOR="$(printf '%s' "$caps" | awk '/<arch name=.x86_64.>/ {a=1} a && /<emulator>/ {gsub(/.*<emulator>|<\/emulator>.*/, ""); print; exit}')"
    if [[ -z "$QEMU_EMULATOR" ]]; then
        for f in /usr/local/sbin/qemu /usr/bin/qemu-system-x86_64 /usr/libexec/qemu-kvm; do
            [[ -x "$f" ]] && { QEMU_EMULATOR="$f"; break; }
        done
    fi
    QEMU_EMULATOR="${QEMU_EMULATOR:-/usr/local/sbin/qemu}"
    MACHINE_Q35="$(printf '%s' "$caps" | grep -oE 'pc-q35-[0-9]+\.[0-9]+' | sort -uV | tail -n1 || true)"
    MACHINE_I440="$(printf '%s' "$caps" | grep -oE 'pc-i440fx-[0-9]+\.[0-9]+' | sort -uV | tail -n1 || true)"
    MACHINE_Q35="${MACHINE_Q35:-q35}"; MACHINE_I440="${MACHINE_I440:-pc}"

    OVMF_CODE=""; OVMF_VARS=""
    for f in /usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        if [[ -r "$f" ]]; then
            OVMF_CODE="$f"
            OVMF_VARS="${f/CODE/VARS}"
            [[ -r "$OVMF_VARS" ]] || OVMF_VARS=""
            break
        fi
    done
    info "libvirt: emulator=$QEMU_EMULATOR  q35=$MACHINE_Q35  i440fx=$MACHINE_I440  OVMF=${OVMF_CODE:-not found}"
}

# =============================================================================
# 4. Distro catalogue
# =============================================================================
# Nothing below pins a point release or build: every resolver reads the
# distro's own release metadata / directory listing, picks the newest dated or
# versioned file (never a moving "latest" alias, so a new release is downloaded
# fresh instead of reusing an old cached copy) and records the checksum file
# that the download is verified against.
fetch_text() {
    if [[ "$DOWNLOADER" == wget ]]; then wget -qO- --timeout=30 --tries=2 "$1" 2>/dev/null || true
    else curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "$1" 2>/dev/null || true; fi
}
# url_ok URL - the URL exists (fetches 1 byte; some mirrors reject HEAD)
url_ok() {
    if [[ "$DOWNLOADER" == wget ]]; then wget -q --spider --timeout=30 --tries=1 "$1" 2>/dev/null
    else curl -fsL --connect-timeout 10 --max-time 30 --retry 1 -r 0-0 -o /dev/null "$1" 2>/dev/null; fi
}
# effective_url URL - final URL after redirects (empty on failure)
effective_url() {
    if [[ "$DOWNLOADER" == wget ]]; then
        wget -S --spider --timeout=30 --tries=1 "$1" 2>&1 | awk 'tolower($1) == "location:" {u = $2} END {print u}' || true
    else
        curl -fsIL --connect-timeout 10 --max-time 30 -o /dev/null -w '%{url_effective}' "$1" 2>/dev/null || true
    fi
}
# last_modified URL - Last-Modified header of URL as YYYYMMDD (empty if unknown)
last_modified() {
    local h
    if [[ "$DOWNLOADER" == wget ]]; then h="$(wget -S --spider --timeout=30 --tries=1 "$1" 2>&1 || true)"
    else h="$(curl -fsIL --connect-timeout 10 --max-time 30 "$1" 2>/dev/null || true)"; fi
    h="$(printf '%s\n' "$h" | awk 'tolower($1) == "last-modified:" {sub(/^[^:]*: */, ""); v = $0} END {print v}' | tr -d '\r')"
    [[ -n "$h" ]] && date -u -d "$h" +%Y%m%d 2>/dev/null || true
}
# latest_match URL REGEX - newest (version-sorted) match of REGEX in an index page
latest_match() {
    fetch_text "$1" | grep -oE "$2" | sort -uV | tail -n1 || true
}
# hrefs URL REGEX - directory names/links matching REGEX in an index page
hrefs() {
    fetch_text "$1" | grep -oE "href=\"$2\"" | sed -E 's/^href="//; s/"$//; s#/$##' || true
}

# Menu entries. Numbers are fixed - new entries are appended at the end so an
# existing OS_CHOICE number never changes meaning. Each also has a stable id
# that OS_CHOICE accepts (e.g. OS_CHOICE=debian-stable).
DISTRO_COUNT=16

# distro_load N|ID - sets D_* for a menu entry (number, id or legacy key)
distro_load() {
    local sel="${1,,}" i
    if [[ ! "$sel" =~ ^([0-9]+|c)$ ]]; then
        for i in $(seq 1 "$DISTRO_COUNT") c; do
            distro_load "$i"
            if [[ "$sel" == "$D_ID" || "$sel" == "$D_KEY" ]]; then return 0; fi
        done
        return 1
    fi
    D_KEY=""; D_ID=""; D_NAME=""; D_ICONS="linux.png"; D_DOCKER=""; D_CLOUD=1; D_ISO=1
    D_OS_TYPE="standard"; D_MIN_MEM=0; D_MIN_DISK=""; D_CLOUD_BIOS_ONLY=0; D_SHELL="/bin/bash"
    D_FAMILY=""; D_CODENAME=""; D_VER=""; D_DYN=""; D_RESOLVED=0
    case "$sel" in
        1)  D_KEY=ubuntu2404; D_ID=ubuntu-24.04; D_NAME="Ubuntu 24.04 LTS (Noble)"; D_ICONS="ubuntu.png"; D_DOCKER="ubuntu:24.04"
            D_FAMILY=ubuntu; D_CODENAME=noble; D_VER=24.04 ;;
        2)  D_KEY=ubuntu2604; D_ID=ubuntu-26.04; D_NAME="Ubuntu 26.04 LTS (Resolute)"; D_ICONS="ubuntu.png"; D_DOCKER="ubuntu:26.04"
            D_FAMILY=ubuntu; D_CODENAME=resolute; D_VER=26.04 ;;
        3)  D_KEY=debian12; D_ID=debian-12; D_NAME="Debian 12 (Bookworm)"; D_ICONS="debian.png"; D_DOCKER="debian:12"
            D_FAMILY=debian; D_CODENAME=bookworm; D_VER=12 ;;
        4)  D_KEY=debian13; D_ID=debian-13; D_NAME="Debian 13 (Trixie)"; D_ICONS="debian.png"; D_DOCKER="debian:13"
            D_FAMILY=debian; D_CODENAME=trixie; D_VER=13 ;;
        5)  D_KEY=fedora; D_ID=fedora; D_NAME="Fedora (newest release)"; D_ICONS="fedora.png"; D_DOCKER="fedora:latest" ;;
        6)  D_KEY=arch; D_ID=arch; D_NAME="Arch Linux (rolling)"; D_ICONS="arch.png archlinux.png"; D_DOCKER="archlinux:latest" ;;
        7)  D_KEY=omarchy; D_ID=omarchy; D_NAME="Omarchy (Arch + Omarchy ready)"; D_ICONS="arch.png archlinux.png"
            D_ISO=0; D_OS_TYPE="omarchy"; D_MIN_MEM=4096; D_MIN_DISK="32G" ;;
        8)  D_KEY=nixos; D_ID=nixos; D_NAME="NixOS (unstable)"; D_ICONS="nixos.png linux.png"; D_DOCKER="nixos/nix:latest"; D_CLOUD=0 ;;
        9)  D_KEY=rocky9; D_ID=rocky-9; D_NAME="Rocky Linux 9"; D_ICONS="rocky.png rockylinux.png centos.png"; D_DOCKER="rockylinux/rockylinux:9" ;;
        10) D_KEY=alpine; D_ID=alpine; D_NAME="Alpine Linux (newest stable)"; D_ICONS="alpine.png alpinelinux.png"; D_DOCKER="alpine:latest"
            D_CLOUD_BIOS_ONLY=1; D_SHELL="/bin/sh" ;;
        11) D_KEY=centos10; D_ID=centos-10; D_NAME="CentOS Stream 10"; D_ICONS="centos.png"; D_DOCKER="quay.io/centos/centos:stream10" ;;
        12) D_KEY=rocky10; D_ID=rocky-10; D_NAME="Rocky Linux 10"; D_ICONS="rocky.png rockylinux.png centos.png"; D_DOCKER="rockylinux/rockylinux:10" ;;
        # Auto-updating entries: the release itself is looked up live.
        13) D_KEY=ubuntults; D_ID=ubuntu-lts; D_NAME="Ubuntu LTS (newest, looked up live)"; D_ICONS="ubuntu.png"
            D_FAMILY=ubuntu; D_DYN=lts; D_DOCKER="ubuntu:latest" ;;
        14) D_KEY=ubuntulatest; D_ID=ubuntu-latest; D_NAME="Ubuntu newest release (incl. interim)"; D_ICONS="ubuntu.png"
            D_FAMILY=ubuntu; D_DYN=latest; D_DOCKER="ubuntu:rolling" ;;
        15) D_KEY=debianstable; D_ID=debian-stable; D_NAME="Debian stable (newest, looked up live)"; D_ICONS="debian.png"
            D_FAMILY=debian; D_DYN=stable; D_DOCKER="debian:stable" ;;
        16) D_KEY=debianoldstable; D_ID=debian-oldstable; D_NAME="Debian oldstable (looked up live)"; D_ICONS="debian.png"
            D_FAMILY=debian; D_DYN=oldstable; D_DOCKER="debian:oldstable" ;;
        c)  D_KEY=custom; D_ID=custom; D_NAME="Custom ISO / custom image"; D_CLOUD=0 ;;
        *) return 1 ;;
    esac
}

# docker_tag_ok REPO TAG - the official Docker Hub image has this tag
docker_tag_ok() {
    url_ok "https://hub.docker.com/v2/repositories/library/$1/tags/$2"
}

# resolve_release - for the auto-updating entries (13-16), find the release
# the menu entry points to right now and fill in D_CODENAME / D_VER / D_KEY /
# D_NAME / D_DOCKER. Returns 1 if the release metadata cannot be read.
resolve_release() {
    [[ -z "$D_DYN" || "$D_RESOLVED" == 1 ]] && return 0
    local list line c v lts
    case "$D_FAMILY" in
        ubuntu)
            # Canonical's release-upgrader metadata: one stanza per release.
            list="$(fetch_text "https://changelogs.ubuntu.com/meta-release" | awk '
                /^Dist:/ {d = $2}
                /^Version:/ { lts = ($0 ~ /LTS/); split($2, p, "."); if (d != "") print d, p[1] "." p[2], lts; d = "" }')"
            [[ "$D_DYN" == lts ]] && list="$(awk '$3 == 1' <<<"$list")"
            line="$(tail -n1 <<<"$list")"
            read -r c v lts <<<"$line" || true
            [[ -n "$c" && -n "$v" ]] || return 1
            D_CODENAME="$c"; D_VER="$v"; D_KEY="ubuntu${v//./}"
            D_NAME="Ubuntu ${v}$([[ "$lts" == 1 ]] && echo " LTS") (${c^})"
            [[ "$D_DYN" == lts ]] && D_NAME+=" - newest LTS" || D_NAME+=" - newest release"
            docker_tag_ok ubuntu "$v" && D_DOCKER="ubuntu:$v"
            ;;
        debian)
            # The archive's suite alias (stable/oldstable) names the codename + version.
            list="$(fetch_text "https://deb.debian.org/debian/dists/${D_DYN}/Release")"
            c="$(awk '/^Codename:/ {print $2; exit}' <<<"$list")"
            v="$(awk '/^Version:/ {split($2, p, "."); print p[1]; exit}' <<<"$list")"
            [[ -n "$c" && "$v" =~ ^[0-9]+$ ]] || return 1
            D_CODENAME="$c"; D_VER="$v"; D_KEY="debian${v}"
            D_NAME="Debian ${v} (${c^}) - ${D_DYN}"
            docker_tag_ok debian "$v" && D_DOCKER="debian:$v"
            ;;
        *) return 1 ;;
    esac
    D_RESOLVED=1
}

choose_distro() {
    step "Choose a Linux distribution"
    if [[ -z "$OS_CHOICE" ]]; then
        local i
        printf '  %sImages and ISOs are looked up live, so the newest build is always used.%s\n' "$C_DIM" "$C_RESET"
        for i in $(seq 1 "$DISTRO_COUNT"); do
            distro_load "$i"
            printf '  %s[%2s]%s %-40s %s%s%s\n' "$C_BOLD" "$i" "$C_RESET" "$D_NAME" "$C_DIM" \
                "$( { [[ $D_CLOUD == 1 ]] && printf 'cloud '; [[ $D_ISO == 1 ]] && printf 'iso '; [[ -n $D_DOCKER ]] && printf 'docker'; } )" "$C_RESET"
        done
        printf '  %s[ c]%s Custom ISO (VM) / custom image (Docker)\n' "$C_BOLD" "$C_RESET"
        OS_CHOICE="$(prompt "Select OS (1-${DISTRO_COUNT}, c, or an id like debian-stable)" "1")"
    fi
    distro_load "$OS_CHOICE" || die "Invalid OS choice: '$OS_CHOICE' (use 1-${DISTRO_COUNT}, c, or an id - see --list)."
    if [[ -n "$D_DYN" ]]; then
        info "Looking up the newest '$D_ID' release..."
        resolve_release || die "Could not read the release metadata for '$D_ID' (check internet/DNS), or pick a fixed entry such as 1-4."
    fi
    if [[ $DO_VM == 0 && -z "$D_DOCKER" && "$D_KEY" != custom ]]; then
        die "$D_NAME has no Docker image (it needs a full VM). Choose another distro or deploy as a VM."
    fi
    if [[ $DO_DOCKER == 1 && -z "$D_DOCKER" && "$D_KEY" != custom ]]; then
        warn "$D_NAME has no Docker image - only the VM will be deployed."
        DO_DOCKER=0; DEPLOY_TYPE=vm
    fi
    ok "Distribution: $D_NAME"
    _log INPUT "OS_CHOICE=$OS_CHOICE ($D_KEY)"
}

# ---------------------------------------------------------------------------
# Cloud image resolvers -> CLOUD_URL, CLOUD_FILE (versioned cache name),
# CLOUD_SUM_URL (checksum file), CLOUD_LABEL. Return 1 if nothing is found.
# ---------------------------------------------------------------------------
# fedora_candidates - release numbers to try, newest first (FEDORA_VERSION pins one)
fedora_candidates() {
    if [[ -n "$FEDORA_VERSION" ]]; then echo "$FEDORA_VERSION"; return 0; fi
    hrefs "https://dl.fedoraproject.org/pub/fedora/linux/releases/" '[0-9]+/' | sort -rn | sed -n '1,4p'
}

find_cloud_image() {
    local dir file serial n build ver
    CLOUD_URL=""; CLOUD_FILE=""; CLOUD_SUM_URL=""; CLOUD_LABEL=""
    case "$D_FAMILY:$D_KEY" in
        ubuntu:*)
            # Dated build directories under /<codename>/ - newest that has the image.
            dir="https://cloud-images.ubuntu.com/${D_CODENAME}/"
            while read -r serial; do
                [[ -z "$serial" ]] && continue
                CLOUD_URL="${dir}${serial}/${D_CODENAME}-server-cloudimg-amd64.img"
                url_ok "$CLOUD_URL" || { CLOUD_URL=""; continue; }
                CLOUD_SUM_URL="${dir}${serial}/SHA256SUMS"
                CLOUD_FILE="ubuntu-${D_VER}-${D_CODENAME}-${serial}.qcow2"
                CLOUD_LABEL="Ubuntu ${D_VER} (${D_CODENAME^}, build ${serial})"
                break
            done < <(hrefs "$dir" '[0-9]{8}(\.[0-9]+)?/' | sort -uV | tac | sed -n '1,3p')
            ;;
        debian:*)
            dir="https://cloud.debian.org/images/cloud/${D_CODENAME}/"
            while read -r serial; do
                [[ -z "$serial" ]] && continue
                file="$(fetch_text "${dir}${serial}/" | grep -oE "debian-${D_VER}-generic-amd64-${serial}\.qcow2" | head -n1 || true)"
                [[ -z "$file" ]] && continue
                CLOUD_URL="${dir}${serial}/${file}"
                CLOUD_SUM_URL="${dir}${serial}/SHA512SUMS"
                CLOUD_FILE="debian-${D_VER}-${D_CODENAME}-${serial}.qcow2"
                CLOUD_LABEL="Debian ${D_VER} (${D_CODENAME^}, build ${serial})"
                break
            done < <(hrefs "$dir" '[0-9]{8}-[0-9]+/' | sort -uV | tac | sed -n '1,5p')
            ;;
        *:fedora)
            # Not every release dir has a Cloud image yet (e.g. while it is being
            # composed), so walk down from the newest until one does.
            while read -r n; do
                [[ -z "$n" ]] && continue
                dir="https://dl.fedoraproject.org/pub/fedora/linux/releases/${n}/Cloud/x86_64/images/"
                file="$(latest_match "$dir" "Fedora-Cloud-Base-Generic-${n}-[0-9.]+\.x86_64\.qcow2")"
                [[ -z "$file" ]] && continue
                build="${file#Fedora-Cloud-Base-Generic-"${n}"-}"; build="${build%.x86_64.qcow2}"
                CLOUD_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${n}/Cloud/x86_64/images/${file}"
                url_ok "$CLOUD_URL" || CLOUD_URL="${dir}${file}"
                CLOUD_SUM_URL="${dir}Fedora-Cloud-${n}-${build}-x86_64-CHECKSUM"
                CLOUD_FILE="fedora-${n}-${build}.qcow2"
                CLOUD_LABEL="Fedora ${n} Cloud (build ${build})"
                FEDORA_VERSION="$n"
                break
            done < <(fedora_candidates)
            ;;
        *:arch|*:omarchy)
            dir="https://geo.mirror.pkgbuild.com/images/latest/"
            file="$(latest_match "$dir" 'Arch-Linux-x86_64-cloudimg-[0-9.]+\.qcow2')"
            if [[ -n "$file" ]]; then
                ver="${file#Arch-Linux-x86_64-cloudimg-}"; ver="${ver%.qcow2}"
                CLOUD_URL="${dir}${file}"; CLOUD_SUM_URL="${CLOUD_URL}.SHA256"
                CLOUD_FILE="arch-${ver}.qcow2"; CLOUD_LABEL="Arch Linux (build ${ver})"
            fi
            ;;
        *:rocky9|*:rocky10)
            n="${D_KEY#rocky}"
            dir="https://dl.rockylinux.org/pub/rocky/${n}/images/x86_64/"
            file="$(latest_match "$dir" "Rocky-${n}-GenericCloud(-Base)?-${n}\.[0-9]+-[0-9.]+\.x86_64\.qcow2")"
            if [[ -n "$file" ]]; then
                ver="$(sed -E "s/^Rocky-${n}-GenericCloud(-Base)?-//; s/\.x86_64\.qcow2$//" <<<"$file")"
                CLOUD_URL="${dir}${file}"; CLOUD_SUM_URL="${CLOUD_URL}.CHECKSUM"
                CLOUD_FILE="rocky-${ver}.qcow2"; CLOUD_LABEL="Rocky Linux ${ver%%-*} (build ${ver#*-})"
            fi
            ;;
        *:centos10)
            dir="https://cloud.centos.org/centos/10-stream/x86_64/images/"
            file="$(latest_match "$dir" 'CentOS-Stream-GenericCloud-10-[0-9]{8}\.[0-9]+\.x86_64\.qcow2')"
            if [[ -n "$file" ]]; then
                ver="${file#CentOS-Stream-GenericCloud-10-}"; ver="${ver%.x86_64.qcow2}"
                CLOUD_URL="${dir}${file}"; CLOUD_SUM_URL="${CLOUD_URL}.SHA256SUM"
                CLOUD_FILE="$file"; CLOUD_LABEL="CentOS Stream 10 (build ${ver})"
            fi
            ;;
        *:alpine)
            # Any rebuild number (-r0, -r1, ...), not just -r0.
            dir="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud/"
            file="$(latest_match "$dir" 'generic_alpine-[0-9.]+-x86_64-bios-cloudinit-r[0-9]+\.qcow2')"
            if [[ -n "$file" ]]; then
                ver="$(sed -E 's/^generic_alpine-([0-9.]+)-x86_64-bios-cloudinit-(r[0-9]+)\.qcow2$/\1-\2/' <<<"$file")"
                CLOUD_URL="${dir}${file}"; CLOUD_SUM_URL="${CLOUD_URL}.sha512"
                CLOUD_FILE="$file"; CLOUD_LABEL="Alpine Linux ${ver%-r*} (${ver##*-})"
            fi
            ;;
    esac
    [[ -n "$CLOUD_URL" && -n "$CLOUD_FILE" ]]
}

# resolve_cloud_url - CLOUD_IMAGE_URL override, or the newest image (dies if none)
resolve_cloud_url() {
    if [[ -n "$CLOUD_IMAGE_URL" ]]; then
        CLOUD_URL="$CLOUD_IMAGE_URL"; CLOUD_FILE="$(basename "${CLOUD_URL%%\?*}")"
        CLOUD_SUM_URL="$CLOUD_IMAGE_SUM_URL"; CLOUD_LABEL="custom image (CLOUD_IMAGE_URL)"
    else
        info "Looking up the newest $D_NAME cloud image..."
        find_cloud_image || die "Could not find the newest $D_NAME cloud image on its official mirror. Check internet/DNS, try again later, or set CLOUD_IMAGE_URL=..."
    fi
    ok "Cloud image: $CLOUD_LABEL"
    info "    $CLOUD_URL"
}

# ---------------------------------------------------------------------------
# Installer ISO resolvers -> ISO_URL, ISO_FILE (versioned local name),
# ISO_SUM_URL, ISO_LABEL. Return 1 if nothing is found.
# ---------------------------------------------------------------------------
find_iso() {
    local base file n build v eff date
    ISO_URL=""; ISO_FILE=""; ISO_SUM_URL=""; ISO_LABEL=""
    case "$D_FAMILY:$D_KEY" in
        ubuntu:*)
            base="https://releases.ubuntu.com/${D_VER}/"
            file="$(latest_match "$base" "ubuntu-${D_VER//./\\.}(\.[0-9]+)?-live-server-amd64\.iso")"
            [[ -n "$file" ]] && { ISO_URL="${base}${file}"; ISO_SUM_URL="${base}SHA256SUMS"; }
            ;;
        debian:*)
            # The current release lives in debian-cd/current, older ones in the archive.
            base="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
            file="$(latest_match "$base" "debian-${D_VER}\.[0-9.]+-amd64-netinst\.iso")"
            if [[ -z "$file" ]]; then
                v="$(hrefs "https://cdimage.debian.org/cdimage/archive/" "${D_VER}\.[0-9.]+/" | sort -uV | tail -n1)"
                if [[ -n "$v" ]]; then
                    base="https://cdimage.debian.org/cdimage/archive/${v}/amd64/iso-cd/"
                    file="$(latest_match "$base" "debian-${D_VER}\.[0-9.]+-amd64-netinst\.iso")"
                fi
            fi
            [[ -n "$file" ]] && { ISO_URL="${base}${file}"; ISO_SUM_URL="${base}SHA512SUMS"; }
            ;;
        *:fedora)
            while read -r n; do
                [[ -z "$n" ]] && continue
                base="https://dl.fedoraproject.org/pub/fedora/linux/releases/${n}/Server/x86_64/iso/"
                file="$(latest_match "$base" "Fedora-Server-netinst-x86_64-${n}-[0-9.]+\.iso")"
                [[ -z "$file" ]] && continue
                build="${file#Fedora-Server-netinst-x86_64-"${n}"-}"; build="${build%.iso}"
                ISO_URL="${base}${file}"; ISO_SUM_URL="${base}Fedora-Server-${n}-${build}-x86_64-CHECKSUM"
                FEDORA_VERSION="$n"
                break
            done < <(fedora_candidates)
            ;;
        *:arch)
            base="https://geo.mirror.pkgbuild.com/iso/latest/"
            file="$(latest_match "$base" 'archlinux-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-x86_64\.iso')"
            [[ -n "$file" ]] && { ISO_URL="${base}${file}"; ISO_SUM_URL="${base}sha256sums.txt"; }
            ;;
        *:nixos)
            # The channel alias redirects to the versioned build on releases.nixos.org.
            base="https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso"
            eff="$(effective_url "$base")"
            if [[ "$eff" == *.iso && "$eff" != "$base" ]]; then
                ISO_URL="$eff"; ISO_SUM_URL="${eff}.sha256"
            elif url_ok "$base"; then
                date="$(last_modified "$base")"
                ISO_URL="$base"; ISO_SUM_URL="${base}.sha256"
                ISO_FILE="nixos-minimal-unstable-${date:-$TIMESTAMP}-x86_64-linux.iso"
            fi
            ;;
        *:rocky9|*:rocky10)
            n="${D_KEY#rocky}"
            base="https://dl.rockylinux.org/pub/rocky/${n}/isos/x86_64/"
            file="$(latest_match "$base" "Rocky-${n}\.[0-9]+-x86_64-minimal\.iso")"
            [[ -n "$file" ]] && { ISO_URL="${base}${file}"; ISO_SUM_URL="${base}CHECKSUM"; }
            ;;
        *:centos10)
            # CentOS publishes only a 'latest' alias; name the local copy after its
            # publish date so a newer build is downloaded instead of reusing an old one.
            base="https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/iso/CentOS-Stream-10-latest-x86_64-boot.iso"
            if url_ok "$base"; then
                date="$(last_modified "$base")"
                ISO_URL="$base"; ISO_SUM_URL="${base}.SHA256SUM"
                ISO_FILE="CentOS-Stream-10-${date:-$TIMESTAMP}-x86_64-boot.iso"
            fi
            ;;
        *:alpine)
            base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
            file="$(latest_match "$base" 'alpine-virt-[0-9.]+-x86_64\.iso')"
            [[ -n "$file" ]] && { ISO_URL="${base}${file}"; ISO_SUM_URL="${ISO_URL}.sha256"; }
            ;;
    esac
    [[ -n "$ISO_URL" ]] || return 1
    ISO_FILE="${ISO_FILE:-$(basename "${ISO_URL%%\?*}")}"
    ISO_LABEL="${ISO_FILE}"
}

# resolve_iso_url - ISO_URL override, or the newest installer ISO (dies if none)
resolve_iso_url() {
    if [[ -n "$ISO_URL" && -z "${ISO_FILE:-}" ]]; then
        ISO_FILE="$(basename "${ISO_URL%%\?*}")"
    elif [[ -z "$ISO_URL" ]]; then
        info "Looking up the newest $D_NAME installer ISO..."
        find_iso || die "Could not find the newest $D_NAME installer ISO on its official mirror. Check internet/DNS, try again later, or set ISO_URL=... / use a custom ISO."
    fi
    ok "Installer ISO: $ISO_FILE"
    info "    $ISO_URL"
}

# ---------------------------------------------------------------------------
# Checksum verification
# ---------------------------------------------------------------------------
# expected_hash SUMS NAME - hash for NAME from a checksum file in any common
# format: GNU ("hash  name" / "hash *name"), BSD ("SHA256 (name) = hash") or
# a bare hash.
expected_hash() {
    local sums="$1" name="$2" h
    h="$(awk -v n="$name" '{
            ok = 0
            for (i = 1; i <= NF; i++) { t = $i; gsub(/^[*(]|[)]$/, "", t); if (t == n) ok = 1 }
            if (ok) for (i = 1; i <= NF; i++)
                if ($i ~ /^[0-9a-fA-F]+$/ && (length($i) == 64 || length($i) == 128)) { print tolower($i); exit }
        }' <<<"$sums")"
    if [[ -z "$h" ]]; then
        local bare
        bare="$(tr -d '[:space:]' <<<"$sums")"
        if [[ $(wc -w <<<"$sums") -eq 1 && "$bare" =~ ^[0-9a-fA-F]{64}([0-9a-fA-F]{64})?$ ]]; then h="${bare,,}"; fi
    fi
    printf '%s' "$h"
}

# verify_file FILE URL SUM_URL - 0 = verified or nothing to verify against
# (reported), 1 = real mismatch.
verify_file() {
    local file="$1" url="$2" sum_url="$3" name sums expected actual algo
    if [[ -z "$sum_url" ]]; then warn "No checksum published for $(basename "$file") - not verified."; return 0; fi
    name="$(basename "${url%%\?*}")"
    sums="$(fetch_text "$sum_url")"
    if [[ -z "$sums" ]]; then warn "Could not fetch $sum_url - download not verified."; return 0; fi
    expected="$(expected_hash "$sums" "$name")"
    if [[ -z "$expected" ]]; then warn "$name is not listed in $sum_url - download not verified."; return 0; fi
    if [[ ${#expected} -eq 128 ]]; then algo=512; actual="$(sha512sum "$file" | cut -d' ' -f1)"
    else algo=256; actual="$(sha256sum "$file" | cut -d' ' -f1)"; fi
    _log VERIFY "$name sha$algo expected=$expected actual=$actual"
    if [[ "$actual" != "$expected" ]]; then
        err "CHECKSUM MISMATCH for $name"
        err "    expected $expected"
        err "    got      $actual"
        return 1
    fi
    ok "SHA${algo} checksum verified: $name"
}

# ---------------------------------------------------------------------------
# --list: what every menu entry resolves to right now
# ---------------------------------------------------------------------------
list_sources() {
    local i rc=0
    for i in $(seq 1 "$DISTRO_COUNT"); do
        distro_load "$i"
        if ! resolve_release; then
            printf '  %s[%2d] %-16s%s %s[!] could not read the release metadata%s\n' "$C_BOLD" "$i" "$D_ID" "$C_RESET" "$C_YELLOW" "$C_RESET"
            rc=1; continue
        fi
        printf '  %s[%2d] %-16s%s %s\n' "$C_BOLD" "$i" "$D_ID" "$C_RESET" "$D_NAME"
        if [[ $D_CLOUD == 1 ]]; then
            if find_cloud_image; then printf '       cloud : %s\n               %s%s%s\n' "$CLOUD_LABEL" "$C_DIM" "$CLOUD_URL" "$C_RESET"
            else printf '       cloud : %s[!] not found (mirror/network issue?)%s\n' "$C_YELLOW" "$C_RESET"; rc=1; fi
        fi
        if [[ $D_ISO == 1 ]]; then
            if find_iso; then printf '       iso   : %s\n               %s%s%s\n' "$ISO_LABEL" "$C_DIM" "$ISO_URL" "$C_RESET"
            else printf '       iso   : %s[!] not found (mirror/network issue?)%s\n' "$C_YELLOW" "$C_RESET"; rc=1; fi
        fi
        [[ -n "$D_DOCKER" ]] && printf '       docker: %s\n' "$D_DOCKER"
    done
    return "$rc"
}

# =============================================================================
# 5. Settings review - every value can be accepted (Enter) or overridden
# =============================================================================
next_free_vm_name() {
    local base="$1" n=1
    while virsh dominfo "${base}-${n}" &>/dev/null || [[ -e "${DOMAINS_PATH}/${base}-${n}" ]]; do n=$((n + 1)); done
    printf '%s-%d\n' "$base" "$n"
}
next_free_container_name() {
    local base="$1" n=1 names
    names="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
    while printf '%s\n' "$names" | grep -qx "${base}-${n}"; do n=$((n + 1)); done
    printf '%s-%d\n' "$base" "$n"
}

choose_vm_mode() {
    if [[ -z "$VM_MODE" ]]; then
        if [[ $D_CLOUD == 1 && $D_ISO == 1 ]]; then
            printf '\n  VM install method:\n'
            printf '    %s[1]%s Cloud image  - boots in seconds, user/password/SSH pre-configured (cloud-init)\n' "$C_BOLD" "$C_RESET"
            printf '    %s[2]%s Installer ISO - classic installer, you finish the install over VNC\n' "$C_BOLD" "$C_RESET"
            case "$(prompt "Select 1-2" "1")" in 2|iso) VM_MODE=iso ;; *) VM_MODE=cloud ;; esac
        elif [[ $D_CLOUD == 1 ]]; then VM_MODE=cloud
        else VM_MODE=iso; fi
    fi
    validate vmmode "$VM_MODE" || die "Invalid VM_MODE '$VM_MODE' (cloud or iso)."
    [[ "$VM_MODE" == cloud && $D_CLOUD == 0 ]] && die "$D_NAME has no cloud image - use VM_MODE=iso."
    [[ "$VM_MODE" == iso && $D_ISO == 0 ]] && die "$D_NAME has no installer ISO - use VM_MODE=cloud."
    ok "VM install method: $VM_MODE"
}

prepare_defaults() {
    if [[ $DO_VM == 1 ]]; then
        choose_vm_mode
        if [[ "$VM_MODE" == cloud ]]; then resolve_cloud_url
        elif [[ "$D_KEY" != custom && -z "$VM_ISO_FILE" ]]; then resolve_iso_url; fi
        CLOUD_CACHE="${CLOUD_CACHE:-${ISO_PATH}/cloud-images}"
        local base="${D_KEY}"; [[ "$D_KEY" == custom ]] && base="linux"
        VM_NAME="${VM_NAME:-$(next_free_vm_name "$base")}"
        if (( D_MIN_MEM > 0 && VM_MEMORY < D_MIN_MEM )); then VM_MEMORY="$D_MIN_MEM"; fi
        if [[ -n "$D_MIN_DISK" && "$VM_DISK_SIZE" == "20G" ]]; then VM_DISK_SIZE="$D_MIN_DISK"; fi
        (( VM_CPUS > CPU_TOTAL )) && VM_CPUS="$CPU_TOTAL"
        if [[ "$VM_MODE" == cloud && $D_CLOUD_BIOS_ONLY == 1 ]]; then VM_BIOS=seabios; fi
        if [[ -z "$VM_ISO_FILE" && "$VM_MODE" == iso && -n "$ISO_URL" ]]; then
            VM_ISO_FILE="${ISO_PATH%/}/${ISO_FILE}"
        fi
    fi
    if [[ $DO_DOCKER == 1 ]]; then
        DOCKER_IMAGE="${DOCKER_IMAGE:-$D_DOCKER}"
        if [[ "$D_KEY" == fedora && "$DOCKER_IMAGE" == "fedora:latest" && -n "$FEDORA_VERSION" ]]; then
            DOCKER_IMAGE="fedora:${FEDORA_VERSION}"
        fi
        local cbase="${D_KEY}"; [[ "$D_KEY" == custom ]] && cbase="linux"
        CONTAINER_NAME="${CONTAINER_NAME:-$(next_free_container_name "$cbase")}"
    fi
}

review_settings() {
    step "Review & confirm settings"
    printf '  These are the detected Unraid settings. Press %sEnter%s to accept each or type a new value.\n\n' "$C_BOLD" "$C_RESET"
    [[ "$ASSUME_YES" == 1 ]] && printf '  %s(--yes: accepting every value as shown in the plan below)%s\n' "$C_DIM" "$C_RESET"

    printf '  %sStorage (Unraid shares)%s\n' "$C_BOLD$C_ORANGE" "$C_RESET"
    if [[ $DO_VM == 1 ]]; then
        ask DOMAINS_PATH "VM disk share (domains)" abspath
        ask ISO_PATH "ISO share (isos)" abspath
        [[ "$CLOUD_CACHE" == "${DET_ISOS}/cloud-images" ]] && CLOUD_CACHE="${ISO_PATH}/cloud-images"
        if [[ "$VM_MODE" == cloud ]]; then ask CLOUD_CACHE "Cloud image cache" abspath; fi
    fi
    if [[ $DO_DOCKER == 1 ]]; then
        ask APPDATA_PATH "Docker appdata share" abspath
    fi

    if [[ $DO_VM == 1 ]]; then
        printf '\n  %sVirtual machine%s  %s(%s, %s CPU threads, %s MiB RAM available)%s\n' "$C_BOLD$C_ORANGE" "$C_RESET" \
            "$C_DIM" "$D_NAME" "$CPU_TOTAL" "$MEM_AVAIL_MIB" "$C_RESET"
        ask VM_NAME "VM name" name
        while virsh dominfo "$VM_NAME" &>/dev/null; do
            warn "A VM called '$VM_NAME' already exists."
            [[ "$ASSUME_YES" == 1 ]] && die "VM name '$VM_NAME' is taken."
            ask VM_NAME "VM name" name
        done
        if [[ "$D_KEY" == custom || "$VM_MODE" == iso ]]; then
            [[ -z "$VM_ISO_FILE" ]] && VM_ISO_FILE="${ISO_PATH}/"
            while true; do
                ask VM_ISO_FILE "Installer ISO (path in isos share or URL)" isofile
                # Accept: a URL, an existing file, or a target path the distro ISO will be downloaded to.
                [[ "$VM_ISO_FILE" =~ ^(https?|ftp|file):// || -f "$VM_ISO_FILE" ]] && break
                [[ -n "$ISO_URL" && "$VM_ISO_FILE" == *.iso ]] && break
                warn "ISO '$VM_ISO_FILE' not found. Existing ISOs in ${ISO_PATH}:"
                find "$ISO_PATH" -maxdepth 2 -iname '*.iso' 2>/dev/null | head -n 15 | sed 's/^/      /' >&2 || true
                [[ "$ASSUME_YES" == 1 ]] && die "Installer ISO not found: $VM_ISO_FILE"
            done
        fi
        ask VM_CPU_PIN "CPU pinning (e.g. 2,3; blank = none; avoid core 0)" cpuset
        if [[ -n "$VM_CPU_PIN" ]]; then
            VM_CPUS="$(tr ',' '\n' <<<"$VM_CPU_PIN" | grep -c .)"
            info "vCPUs set to $VM_CPUS (one per pinned core)."
        else
            ask VM_CPUS "vCPUs" posint
            (( VM_CPUS > CPU_TOTAL )) && warn "$VM_CPUS vCPUs is more than the $CPU_TOTAL threads on this server."
        fi
        ask VM_MEMORY "RAM (MiB)" mib
        (( VM_MEMORY > MEM_AVAIL_MIB )) && warn "${VM_MEMORY} MiB is more than the ${MEM_AVAIL_MIB} MiB currently available."
        ask VM_DISK_SIZE "vDisk size" size
        ask VM_DISK_FORMAT "vDisk format (qcow2/raw)" format
        ask VM_DISK_NAME "vDisk file name" name
        printf '  %sMachine types on this server: q35 -> %s, i440fx -> %s%s\n' "$C_DIM" "$MACHINE_Q35" "$MACHINE_I440" "$C_RESET"
        ask VM_MACHINE "Machine type (q35/i440fx)" machine
        if [[ "$VM_MODE" == cloud && $D_CLOUD_BIOS_ONLY == 1 ]]; then
            info "BIOS: SeaBIOS (the $D_NAME cloud image is BIOS-only)."
        else
            ask VM_BIOS "BIOS (seabios/ovmf)" bios
            if [[ "$VM_BIOS" == ovmf && ( -z "$OVMF_CODE" || -z "$OVMF_VARS" ) ]]; then
                warn "OVMF firmware not found on this server - falling back to SeaBIOS."
                VM_BIOS=seabios
            fi
        fi
        ask VM_BRIDGE "Network bridge" name
        [[ -d "/sys/class/net/$VM_BRIDGE" ]] || warn "Bridge '$VM_BRIDGE' does not exist on this server right now."
        ask VM_VNC_LISTEN "VNC listen address" nonempty
        ask VM_VNC_KEYMAP "VNC keyboard layout" nonempty
        if [[ "$VM_MODE" == cloud ]]; then
            ask DEFAULT_USER "Guest user name" user
            ask DEFAULT_PASS "Guest password (user + root)" pass
        fi
        ask VM_START "Start the VM after creation" yesno
        ask VM_AUTOSTART "Autostart with the array" yesno
    fi

    if [[ $DO_DOCKER == 1 ]]; then
        printf '\n  %sDocker container%s\n' "$C_BOLD$C_ORANGE" "$C_RESET"
        ask CONTAINER_NAME "Container name" name
        while docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; do
            warn "A container called '$CONTAINER_NAME' already exists."
            [[ "$ASSUME_YES" == 1 ]] && die "Container name '$CONTAINER_NAME' is taken."
            ask CONTAINER_NAME "Container name" name
        done
        [[ -z "$DOCKER_IMAGE" ]] && DOCKER_IMAGE="ubuntu:24.04"
        ask DOCKER_IMAGE "Image:tag" image
        # Keep the appdata folder in step with the container name unless the user customised it.
        if [[ -z "$DOCKER_APPDATA" || "$DOCKER_APPDATA" == "${APPDATA_AUTO:-}" ]]; then
            DOCKER_APPDATA="${APPDATA_PATH%/}/${CONTAINER_NAME}"
        fi
        APPDATA_AUTO="${APPDATA_PATH%/}/${CONTAINER_NAME}"
        ask DOCKER_APPDATA "Appdata folder" abspath
        ask DOCKER_CONFIG_TARGET "Appdata mount point in container" abspath
        ask DOCKER_PORTS "Port mappings (host:container, comma list)" ports
        ask DOCKER_VOLUMES "Extra volumes (/host:/ctr[:ro], comma list)" volumes
        ask DOCKER_ENV "Extra environment (KEY=value, comma list)" envlist
        local nets
        nets="$(docker network ls --format '{{.Name}}' 2>/dev/null | tr '\n' ' ' || true)"
        [[ -n "$nets" ]] && printf '  %sAvailable networks: %s%s\n' "$C_DIM" "$nets" "$C_RESET"
        ask DOCKER_NETWORK "Network" name
        if [[ -n "$nets" ]] && ! grep -qw -- "$DOCKER_NETWORK" <<<"$nets"; then
            warn "Docker network '$DOCKER_NETWORK' does not exist (available: $nets)."
        fi
        ask DOCKER_RESTART "Restart policy" restart
        ask DOCKER_CMD "Container command (keeps it running)" nonempty
        ask DOCKER_TEMPLATE "Save a dockerMan template (edit from DOCKER tab)" yesno
    fi
}

show_plan() {
    printf '\n'
    table_row "PLAN" "VALUE" ""; table_rule
    table_row "Deployment" "$DEPLOY_TYPE" ""
    table_row "Distribution" "$D_NAME" ""
    if [[ $DO_VM == 1 ]]; then
        table_row "VM name / method" "$VM_NAME / $VM_MODE" ""
        table_row "vDisk" "${DOMAINS_PATH}/${VM_NAME}/${VM_DISK_NAME}" "$VM_DISK_FORMAT, $VM_DISK_SIZE"
        if [[ "$VM_MODE" == cloud ]]; then table_row "Cloud image" "${CLOUD_CACHE}/${CLOUD_FILE}" ""
        else table_row "Installer ISO" "$VM_ISO_FILE" ""; fi
        table_row "CPU / RAM" "${VM_CPUS} vCPU${VM_CPU_PIN:+ (pinned $VM_CPU_PIN)} / ${VM_MEMORY} MiB" ""
        table_row "Machine / BIOS" "$VM_MACHINE / $VM_BIOS" ""
        table_row "Network / VNC" "$VM_BRIDGE / ${VM_VNC_LISTEN} (${VM_VNC_KEYMAP})" ""
        [[ "$VM_MODE" == cloud ]] && table_row "Guest login" "$DEFAULT_USER / ********" "also root"
        table_row "Start / autostart" "$VM_START / $VM_AUTOSTART" ""
    fi
    if [[ $DO_DOCKER == 1 ]]; then
        table_row "Container / image" "$CONTAINER_NAME / $DOCKER_IMAGE" ""
        table_row "Appdata" "$DOCKER_APPDATA -> $DOCKER_CONFIG_TARGET" ""
        table_row "Ports" "${DOCKER_PORTS:-none}" ""
        table_row "Extra volumes" "${DOCKER_VOLUMES:-none}" ""
        table_row "Network / restart" "$DOCKER_NETWORK / $DOCKER_RESTART" ""
        table_row "dockerMan template" "$DOCKER_TEMPLATE" ""
    fi
    table_rule
}

confirm_plan() {
    local ans
    while true; do
        show_plan
        ans="$(prompt "Proceed? [y]es / [e]dit / [q]uit" "y")"
        _log INPUT "proceed -> $ans"
        case "${ans,,}" in
            y|yes) return 0 ;;
            e|edit) review_settings ;;
            q|quit|n|no) info "Aborted by user - nothing was changed."; print_summary "ABORTED"; exit 0 ;;
            *) warn "Please answer y, e or q." ;;
        esac
    done
}

# =============================================================================
# 6. Path checks - directories must exist (or be creatable) and be writable
# =============================================================================
ensure_dir() {
    local dir="$1" label="$2" probe
    if [[ ! -d "$dir" ]]; then
        local top="${dir#"${UNRAID_USER_SHARE}"/}"; top="${top%%/*}"
        if [[ "$dir" == "${UNRAID_USER_SHARE}"/* && ! -d "${UNRAID_USER_SHARE}/${top}" ]]; then
            warn "Share '${top}' does not exist yet; creating it makes a new Unraid user share with default settings."
        fi
        info "Creating $label: $dir"
        run mkdir -p "$dir"
        [[ "$DRY_RUN" == 1 ]] && return 0
        add_created "$label: $dir"
    fi
    [[ "$DRY_RUN" == 1 ]] && return 0
    probe="${dir%/}/.quick-deploy-write-test.$$"
    if ! ( : >"$probe" ) 2>/dev/null; then die "$label '$dir' is not writable."; fi
    rm -f "$probe"
    ok "$label is writable: $dir"
}

# =============================================================================
# 7. Downloads
# =============================================================================
# download URL DEST [SUM_URL] - fetch URL to DEST and verify it against the
# published checksum. A cached DEST is re-verified; if it no longer matches it
# is downloaded again. A mismatch after a fresh download is fatal.
download() {
    local url="$1" dest="$2" sum_url="${3:-}"
    is_yes "$VERIFY_CHECKSUMS" || sum_url=""
    if [[ -f "$dest" ]]; then
        if [[ "$DRY_RUN" == 1 || -z "$sum_url" ]]; then ok "Using existing file: $dest"; return 0; fi
        info "Found cached $(basename "$dest") - re-checking its checksum..."
        if verify_file "$dest" "$url" "$sum_url"; then ok "Using existing file: $dest"; return 0; fi
        warn "Cached file does not match the published checksum - downloading it again."
        rm -f "$dest"
    fi
    fetch_file "$url" "$dest"
    if [[ "$DRY_RUN" == 1 ]]; then
        [[ -n "$sum_url" ]] && info "Would verify against $sum_url"
        return 0
    fi
    if [[ -z "$sum_url" ]] && ! is_yes "$VERIFY_CHECKSUMS"; then
        warn "Checksum verification disabled (VERIFY_CHECKSUMS=no)."
    elif ! verify_file "$dest" "$url" "$sum_url"; then
        rm -f "$dest"
        die "Downloaded file failed checksum verification and was deleted: $url (re-run to try again)."
    fi
    add_created "Download: $dest ($(du -h "$dest" | cut -f1))"
}

# fetch_file URL DEST - raw transfer via a *.part file
fetch_file() {
    local url="$1" dest="$2"
    info "Downloading $url"
    info "        -> $dest"
    [[ "$DRY_RUN" == 1 ]] && { run_q "$DOWNLOADER" "$url"; return 0; }
    _log CMD "$DOWNLOADER $url -> $dest.part"
    local rc=0
    # Download to *.part so an interrupted transfer never looks like a valid file.
    if [[ "$DOWNLOADER" == wget ]]; then
        wget -q --show-progress -O "${dest}.part" "$url" || rc=$?
    else
        curl -fL --retry 3 --progress-bar -o "${dest}.part" "$url" || rc=$?
    fi
    if [[ $rc -ne 0 || ! -s "${dest}.part" ]]; then
        rm -f "${dest}.part"
        die "Download failed (exit $rc): $url"
    fi
    mv "${dest}.part" "$dest"
}

# =============================================================================
# 8. VM deployment
# =============================================================================
vm_icon() {
    local i
    for i in $D_ICONS; do
        [[ -f "${UNRAID_VM_ICON_DIR}/$i" ]] && { printf '%s' "$i"; return; }
    done
    printf 'linux.png'
}

gen_mac() { printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)); }
gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen &>/dev/null; then uuidgen
    else od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'; fi
}

# Build the NoCloud seed (cloud-init) for cloud-image VMs.
# Preference: ISO via genisoimage/mkisofs/xorriso, fallback: small vfat disk (mkfs.vfat + loop mount).
build_seed() {
    local dir="$1" pw_line root_pw sudo_rule="ALL=(ALL) NOPASSWD:ALL" extra_pkgs="" hash=""
    run mkdir -p "${dir}/cloud-init"
    # shellcheck disable=SC2016  # literal "$6$" prefix of a SHA-512 crypt hash
    if command -v openssl &>/dev/null && hash="$(openssl passwd -6 "$DEFAULT_PASS" 2>/dev/null)" && [[ "$hash" == '$6$'* ]]; then
        pw_line="    passwd: '${hash}'"
        root_pw="      - {name: root, password: '${hash}', type: hash}"
    else
        pw_line="    plain_text_passwd: '${DEFAULT_PASS}'"
        root_pw="      - {name: root, password: '${DEFAULT_PASS}', type: text}"
    fi
    [[ "$D_KEY" == alpine ]] && extra_pkgs=$'\n  - sudo'

    write_file "${dir}/cloud-init/user-data" <<EOF
#cloud-config
# Generated by unraid-linux-quick-deploy v${QD_VERSION}
hostname: ${VM_NAME}
manage_etc_hosts: true
ssh_pwauth: true
disable_root: false
users:
  - name: ${DEFAULT_USER}
    gecos: Quick Deploy user
    shell: ${D_SHELL}
    sudo: "${sudo_rule}"
    lock_passwd: false
${pw_line}
chpasswd:
  expire: false
  users:
${root_pw}
package_update: true
packages:
  - qemu-guest-agent${extra_pkgs}
runcmd:
  - [sh, -c, "rm -f /etc/ssh/sshd_config.d/*cloudimg*.conf || true"]
  - [sh, -c, "sed -i 's/^#\\\\?PasswordAuthentication.*/PasswordAuthentication yes/; s/^#\\\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true"]
  - [sh, -c, "systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || rc-service sshd restart 2>/dev/null || true"]
  - [sh, -c, "systemctl enable --now qemu-guest-agent 2>/dev/null || (rc-update add qemu-guest-agent && rc-service qemu-guest-agent start) 2>/dev/null || true"]
EOF
    if [[ "$D_OS_TYPE" == omarchy ]]; then
        cat >>"$LAST_WRITTEN" <<EOF
  - [sh, -c, "usermod -aG wheel ${DEFAULT_USER} || true"]
  - [sh, -c, "printf '#!/bin/bash\\\\nset -e\\\\nsudo pacman -Sy --noconfirm git curl wget\\\\nwget -qO- https://omarchy.org/install | bash\\\\n' > /home/${DEFAULT_USER}/install-omarchy.sh"]
  - [sh, -c, "chmod +x /home/${DEFAULT_USER}/install-omarchy.sh && chown ${DEFAULT_USER}:${DEFAULT_USER} /home/${DEFAULT_USER}/install-omarchy.sh"]
  - [sh, -c, "echo 'echo \"Run ./install-omarchy.sh to launch the Omarchy installer!\"' >> /home/${DEFAULT_USER}/.bashrc"]
EOF
    fi
    write_file "${dir}/cloud-init/meta-data" <<EOF
instance-id: ${VM_NAME}-${VM_UUID}
local-hostname: ${VM_NAME}
EOF
    local udata="${dir}/cloud-init/user-data" mdata="${dir}/cloud-init/meta-data" tool=""
    if [[ "$DRY_RUN" == 1 ]]; then udata="${DRY_DIR}/user-data"; mdata="${DRY_DIR}/meta-data"; fi

    for tool in genisoimage mkisofs xorrisofs; do
        if command -v "$tool" &>/dev/null && "$tool" --version &>/dev/null; then break; fi
        tool=""
    done
    if [[ -z "$tool" ]] && command -v xorriso &>/dev/null && xorriso -version &>/dev/null; then tool="xorriso"; fi
    if [[ -n "$tool" ]]; then
        SEED_PATH="${dir}/cloud-init.iso"; SEED_KIND="iso"
        info "Building cloud-init seed ISO with $tool..."
        if [[ "$tool" == xorriso ]]; then
            run_q xorriso -as mkisofs -output "$SEED_PATH" -volid cidata -joliet -rock "$udata" "$mdata"
        else
            run_q "$tool" -output "$SEED_PATH" -volid cidata -joliet -rock "$udata" "$mdata"
        fi
    elif command -v mkfs.vfat &>/dev/null; then
        SEED_PATH="${dir}/cloud-init.img"; SEED_KIND="vfat"
        info "Building cloud-init seed disk (vfat, label CIDATA)..."
        run_q truncate -s 4M "$SEED_PATH"
        run_q mkfs.vfat -n CIDATA "$SEED_PATH"
        if [[ "$DRY_RUN" != 1 ]]; then
            local mnt; mnt="$(mktemp -d)"
            run_q mount -o loop "$SEED_PATH" "$mnt"
            cp "$udata" "$mdata" "$mnt/" && sync
            run_q umount "$mnt"; rmdir "$mnt"
        fi
    else
        die "No tool to build the cloud-init seed (need genisoimage/mkisofs/xorriso or mkfs.vfat)."
    fi
    [[ "$DRY_RUN" == 1 ]] || add_created "cloud-init seed: $SEED_PATH"
}

prepare_vdisk() {
    local disk="$1" src
    if [[ -e "$disk" ]]; then die "vDisk already exists: $disk (choose another VM name or remove it)."; fi
    if [[ "$VM_MODE" == cloud ]]; then
        src="${CLOUD_CACHE}/${CLOUD_FILE}"
        info "Converting cloud image to $VM_DISK_FORMAT vDisk..."
        run qemu-img convert -p -O "$VM_DISK_FORMAT" "$src" "$disk"
        local cur=0 want
        if [[ "$DRY_RUN" != 1 ]]; then
            cur="$(qemu-img info --output=json "$disk" | awk -F'[:,]' '/"virtual-size"/ {gsub(/ /, "", $2); print $2; exit}')"
        fi
        want="$(numfmt --from=iec "$VM_DISK_SIZE" 2>/dev/null || echo 0)"
        if [[ "$want" != 0 && "${cur:-0}" -gt "$want" ]]; then
            warn "Cloud image is already larger ($((cur / 1024 / 1024)) MiB) than $VM_DISK_SIZE - keeping its size."
        else
            info "Resizing vDisk to $VM_DISK_SIZE..."
            run_q qemu-img resize -f "$VM_DISK_FORMAT" "$disk" "$VM_DISK_SIZE"
        fi
    else
        info "Creating empty $VM_DISK_FORMAT vDisk ($VM_DISK_SIZE)..."
        run_q qemu-img create -f "$VM_DISK_FORMAT" "$disk" "$VM_DISK_SIZE"
    fi
    [[ "$DRY_RUN" == 1 ]] || add_created "vDisk: $disk ($VM_DISK_FORMAT, $VM_DISK_SIZE)"
}

# cdrom_xml FILE DEV BUS EXTRA_LINE - a read-only CD-ROM <disk> element
cdrom_xml() {
    printf "    <disk type='file' device='cdrom'>\n      <driver name='qemu' type='raw'/>\n"
    printf "      <source file='%s'/>\n      <target dev='%s' bus='%s'/>\n      <readonly/>\n" "$(xml_esc "$1")" "$2" "$3"
    if [[ -n "$4" ]]; then printf '%s\n' "$4"; fi
    printf '    </disk>'
}

# seed_vfat_xml FILE - the vfat cloud-init seed attached as a small virtio disk
seed_vfat_xml() {
    printf "    <disk type='file' device='disk'>\n      <driver name='qemu' type='raw'/>\n"
    printf "      <source file='%s'/>\n      <target dev='hdd' bus='virtio'/>\n    </disk>" "$(xml_esc "$1")"
}

# Generate a libvirt domain XML in the same shape Unraid's VM Manager writes.
generate_vm_xml() {
    local disk="$1" machine cdbus mem_kib icon i cputune="" loader="" iso_disk="" seed_disk=""
    mem_kib=$((VM_MEMORY * 1024))
    icon="$(vm_icon)"
    if [[ "$VM_MACHINE" == q35 ]]; then machine="$MACHINE_Q35"; cdbus=sata; else machine="$MACHINE_I440"; cdbus=ide; fi

    if [[ -n "$VM_CPU_PIN" ]]; then
        cputune="  <cputune>"$'\n'
        i=0
        for core in ${VM_CPU_PIN//,/ }; do
            cputune+="    <vcpupin vcpu='${i}' cpuset='${core}'/>"$'\n'
            i=$((i + 1))
        done
        cputune+="  </cputune>"$'\n'
    fi
    if [[ "$VM_BIOS" == ovmf ]]; then
        loader="    <loader readonly='yes' type='pflash'>$(xml_esc "$OVMF_CODE")</loader>"$'\n'
        loader+="    <nvram template='$(xml_esc "$OVMF_VARS")'>$(xml_esc "$NVRAM_FILE")</nvram>"$'\n'
    fi
    if [[ "$VM_MODE" == iso ]]; then
        iso_disk="$(cdrom_xml "$VM_ISO_LOCAL" hda "$cdbus" "      <boot order='2'/>")"$'\n'
    fi
    if [[ "$VM_MODE" == cloud ]]; then
        if [[ "$SEED_KIND" == iso ]]; then
            seed_disk="$(cdrom_xml "$SEED_PATH" hdb "$cdbus" "")"$'\n'
        else
            seed_disk="$(seed_vfat_xml "$SEED_PATH")"$'\n'
        fi
    fi

    cat <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<domain type='kvm'>
  <name>$(xml_esc "$VM_NAME")</name>
  <uuid>${VM_UUID}</uuid>
  <description>$(xml_esc "$D_NAME") - created by unraid-linux-quick-deploy</description>
  <metadata>
    <vmtemplate xmlns="unraid" name="Linux" icon="${icon}" os="linux"/>
  </metadata>
  <memory unit='KiB'>${mem_kib}</memory>
  <currentMemory unit='KiB'>${mem_kib}</currentMemory>
  <memoryBacking>
    <nosharepages/>
  </memoryBacking>
  <vcpu placement='static'>${VM_CPUS}</vcpu>
${cputune}  <os>
    <type arch='x86_64' machine='${machine}'>hvm</type>
${loader}  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='${VM_CPUS}' threads='1'/>
    <cache mode='passthrough'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
    <emulator>$(xml_esc "$QEMU_EMULATOR")</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='${VM_DISK_FORMAT}' cache='writeback' discard='unmap'/>
      <source file='$(xml_esc "$disk")'/>
      <target dev='hdc' bus='virtio'/>
      <boot order='1'/>
    </disk>
${iso_disk}${seed_disk}    <controller type='usb' index='0' model='qemu-xhci' ports='15'/>
    <interface type='bridge'>
      <mac address='${VM_MAC}'/>
      <source bridge='$(xml_esc "$VM_BRIDGE")'/>
      <model type='virtio-net'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <input type='tablet' bus='usb'/>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes' websocket='-1' listen='$(xml_esc "$VM_VNC_LISTEN")' keymap='$(xml_esc "$VM_VNC_KEYMAP")'>
      <listen type='address' address='$(xml_esc "$VM_VNC_LISTEN")'/>
    </graphics>
    <audio id='1' type='none'/>
    <video>
      <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1' primary='yes'/>
    </video>
    <memballoon model='none'/>
  </devices>
</domain>
EOF
}

deploy_vm() {
    step "Deploying VM '$VM_NAME'"
    local vmdir="${DOMAINS_PATH%/}/${VM_NAME}" disk xml_path
    disk="${vmdir}/${VM_DISK_NAME}"
    VM_UUID="$(gen_uuid)"; VM_MAC="$(gen_mac)"
    NVRAM_FILE="${NVRAM_DIR%/}/${VM_UUID}_VARS-pure-efi.fd"
    SEED_PATH=""; SEED_KIND=""

    ensure_dir "$DOMAINS_PATH" "VM disk share"
    ensure_dir "$vmdir" "VM folder"

    if [[ "$VM_MODE" == cloud ]]; then
        ensure_dir "$CLOUD_CACHE" "Cloud image cache"
        download "$CLOUD_URL" "${CLOUD_CACHE}/${CLOUD_FILE}" "$CLOUD_SUM_URL"
    else
        if [[ "$VM_ISO_FILE" =~ ^(https?|ftp|file):// ]]; then
            ensure_dir "$ISO_PATH" "ISO share"
            VM_ISO_LOCAL="${ISO_PATH%/}/$(basename "${VM_ISO_FILE%%\?*}")"
            download "$VM_ISO_FILE" "$VM_ISO_LOCAL" "$ISO_SUM_URL"
        elif [[ -n "$ISO_URL" && "$(basename "$VM_ISO_FILE")" == "$ISO_FILE" ]]; then
            # The looked-up ISO (cached copies are re-verified by download).
            ensure_dir "$(dirname "$VM_ISO_FILE")" "ISO folder"
            VM_ISO_LOCAL="$VM_ISO_FILE"
            download "$ISO_URL" "$VM_ISO_LOCAL" "$ISO_SUM_URL"
        elif [[ -f "$VM_ISO_FILE" ]]; then
            VM_ISO_LOCAL="$VM_ISO_FILE"; ok "Using existing ISO: $VM_ISO_LOCAL"
        else
            die "ISO file not found: $VM_ISO_FILE"
        fi
    fi

    prepare_vdisk "$disk"
    [[ "$VM_MODE" == cloud ]] && build_seed "$vmdir"

    if [[ "$VM_BIOS" == ovmf ]]; then
        run mkdir -p "$NVRAM_DIR"
        run cp "$OVMF_VARS" "$NVRAM_FILE"
    fi

    info "Generating libvirt XML..."
    xml_path="${vmdir}/${VM_NAME}.xml"
    local xml_content
    xml_content="$(generate_vm_xml "$disk")"
    write_file "$xml_path" <<<"$xml_content"
    xml_path="$LAST_WRITTEN"
    if command -v virt-xml-validate &>/dev/null; then
        if virt-xml-validate "$xml_path" domain >>"$LOG_FILE" 2>&1; then ok "XML validated against the libvirt schema."
        else warn "virt-xml-validate reported issues (see log); libvirt will have the final say."; fi
    fi
    [[ "$DRY_RUN" == 1 ]] || add_created "libvirt XML: $xml_path"

    info "Registering VM with libvirt (Unraid VM Manager)..."
    run virsh define "$xml_path"
    if [[ "$DRY_RUN" != 1 ]]; then
        virsh dominfo "$VM_NAME" >>"$LOG_FILE" 2>&1 || die "virsh define reported success but '$VM_NAME' is not registered."
        VM_UUID="$(virsh domuuid "$VM_NAME" 2>/dev/null | head -n1 || echo "$VM_UUID")"
        add_created "VM: $VM_NAME ($VM_UUID)"
    fi
    ok "VM '$VM_NAME' defined."

    is_yes "$VM_AUTOSTART" && run_q virsh autostart "$VM_NAME"

    VNC_INFO="not started"
    if is_yes "$VM_START"; then
        info "Starting VM..."
        run virsh start "$VM_NAME"
        if [[ "$DRY_RUN" != 1 ]]; then
            local state disp port
            state="$(virsh domstate "$VM_NAME" 2>/dev/null | head -n1 || true)"
            [[ "$state" == running ]] || die "VM did not reach the running state (state: ${state:-unknown})."
            ok "VM is running."
            disp="$(virsh vncdisplay "$VM_NAME" 2>/dev/null | head -n1 || true)"
            if [[ "$disp" =~ :([0-9]+)$ ]]; then
                port=$((5900 + BASH_REMATCH[1]))
                local host="$VM_VNC_LISTEN"; [[ "$host" == 0.0.0.0 ]] && host="$SERVER_IP"
                VNC_INFO="${host}:${port}  (display ${disp})"
            else
                VNC_INFO="use the VNC Remote option in the VMS tab"
            fi
        else
            VNC_INFO="(dry-run)"
        fi
    fi

    add_summary "VM name" "$VM_NAME"
    add_summary "VM UUID" "$VM_UUID"
    add_summary "VM distro / method" "$D_NAME / $VM_MODE"
    add_summary "VM vDisk" "$disk ($VM_DISK_FORMAT, $VM_DISK_SIZE)"
    add_summary "VM resources" "${VM_CPUS} vCPU, ${VM_MEMORY} MiB, $VM_MACHINE, $VM_BIOS"
    add_summary "VM network" "$VM_BRIDGE (MAC $VM_MAC)"
    add_summary "VNC" "$VNC_INFO"
    add_summary "VM XML" "${vmdir}/${VM_NAME}.xml"
    if [[ "$VM_MODE" == cloud ]]; then
        add_summary "Guest login" "$DEFAULT_USER / $DEFAULT_PASS (root too)"
        add_next "VM: wait ~1 min for cloud-init, then find the IP with: virsh domifaddr '$VM_NAME' --source agent"
        add_next "VM: ssh ${DEFAULT_USER}@<vm-ip>  - and CHANGE THE DEFAULT PASSWORD"
        [[ "$D_OS_TYPE" == omarchy ]] && add_next "VM: log in as ${DEFAULT_USER} and run ./install-omarchy.sh"
    else
        add_next "VM: open the VMS tab -> ${VM_NAME} -> VNC Remote (or VNC to ${VNC_INFO%% *}) and run the installer"
        add_next "VM: after installing, edit the VM in the VMS tab and remove the ISO so it boots from the vDisk"
    fi
    add_next "VM: manage it under the VMS tab in the Unraid web UI (http://${SERVER_IP}/VMs)"
}

# =============================================================================
# 9. Docker deployment
# =============================================================================
write_docker_template() {
    local dir="${UNRAID_BOOT_CONFIG}/plugins/dockerMan/templates-user" f item h c proto extra repo_url
    f="${dir}/my-${CONTAINER_NAME}.xml"
    run mkdir -p "$dir"
    extra="--init --hostname=${CONTAINER_NAME} --restart=${DOCKER_RESTART} -l net.unraid.docker.quickdeploy=${QD_VERSION}"
    repo_url="https://hub.docker.com/r/${DOCKER_IMAGE%%:*}"
    [[ "$DOCKER_IMAGE" != */* ]] && repo_url="https://hub.docker.com/_/${DOCKER_IMAGE%%:*}"
    local tpl
    tpl="$({
        cat <<EOF
<?xml version="1.0"?>
<Container version="2">
  <Name>$(xml_esc "$CONTAINER_NAME")</Name>
  <Repository>$(xml_esc "$DOCKER_IMAGE")</Repository>
  <Registry>$(xml_esc "$repo_url")</Registry>
  <Network>$(xml_esc "$DOCKER_NETWORK")</Network>
  <MyIP/>
  <Shell>$( [[ "$D_SHELL" == /bin/sh ]] && echo sh || echo bash )</Shell>
  <Privileged>false</Privileged>
  <Support/>
  <Project/>
  <Overview>$(xml_esc "$D_NAME") container created by unraid-linux-quick-deploy.</Overview>
  <Category>Tools:</Category>
  <WebUI/>
  <TemplateURL/>
  <Icon/>
  <ExtraParams>$(xml_esc "$extra")</ExtraParams>
  <PostArgs>$(xml_esc "$DOCKER_CMD")</PostArgs>
  <CPUset/>
  <DateInstalled>$(date +%s)</DateInstalled>
  <DonateText/>
  <DonateLink/>
  <Requires/>
  <Config Name="Appdata" Target="$(xml_esc "$DOCKER_CONFIG_TARGET")" Default="$(xml_esc "$DOCKER_APPDATA")" Mode="rw" Description="Container config/data" Type="Path" Display="always" Required="true" Mask="false">$(xml_esc "$DOCKER_APPDATA")</Config>
EOF
        for item in ${DOCKER_PORTS//,/ }; do
            h="${item%%:*}"; c="${item#*:}"; proto=tcp
            [[ "$c" == */* ]] && { proto="${c#*/}"; c="${c%/*}"; }
            printf '  <Config Name="Port %s" Target="%s" Default="%s" Mode="%s" Description="" Type="Port" Display="always" Required="false" Mask="false">%s</Config>\n' "$c" "$c" "$h" "$proto" "$h"
        done
        for item in ${DOCKER_VOLUMES//,/ }; do
            IFS=: read -r h c proto <<<"$item"
            printf '  <Config Name="Path %s" Target="%s" Default="%s" Mode="%s" Description="" Type="Path" Display="always" Required="false" Mask="false">%s</Config>\n' \
                "$(xml_esc "$c")" "$(xml_esc "$c")" "$(xml_esc "$h")" "${proto:-rw}" "$(xml_esc "$h")"
        done
        for item in "TZ=${DET_TZ}" "PUID=${DOCKER_PUID}" "PGID=${DOCKER_PGID}" "UMASK=022" ${DOCKER_ENV//,/ }; do
            printf '  <Config Name="%s" Target="%s" Default="%s" Mode="" Description="" Type="Variable" Display="always" Required="false" Mask="false">%s</Config>\n' \
                "$(xml_esc "${item%%=*}")" "$(xml_esc "${item%%=*}")" "$(xml_esc "${item#*=}")" "$(xml_esc "${item#*=}")"
        done
        echo "</Container>"
    })"
    write_file "$f" <<<"$tpl"
    [[ "$DRY_RUN" == 1 ]] || add_created "dockerMan template: $f"
}

deploy_docker() {
    step "Deploying Docker container '$CONTAINER_NAME'"
    local args=() item cid status

    ensure_dir "$APPDATA_PATH" "Docker appdata share"
    ensure_dir "$DOCKER_APPDATA" "Container appdata folder"

    info "Pulling $DOCKER_IMAGE ..."
    run docker pull "$DOCKER_IMAGE"

    args=(run -d --name "$CONTAINER_NAME" --hostname "$CONTAINER_NAME" --init
          --restart "$DOCKER_RESTART" --network "$DOCKER_NETWORK"
          -e "TZ=${DET_TZ}" -e "PUID=${DOCKER_PUID}" -e "PGID=${DOCKER_PGID}" -e "UMASK=022"
          -v "${DOCKER_APPDATA}:${DOCKER_CONFIG_TARGET}:rw"
          -l "net.unraid.docker.quickdeploy=${QD_VERSION}")
    for item in ${DOCKER_PORTS//,/ }; do args+=(-p "$item"); done
    for item in ${DOCKER_VOLUMES//,/ }; do args+=(-v "$item"); done
    for item in ${DOCKER_ENV//,/ }; do args+=(-e "$item"); done
    if is_yes "$DOCKER_TEMPLATE"; then
        args+=(-l "net.unraid.docker.managed=dockerman")
        write_docker_template
    fi
    args+=("$DOCKER_IMAGE")
    # DOCKER_CMD is intentionally word-split into the container command + args.
    read -r -a cmd_words <<<"$DOCKER_CMD"
    args+=("${cmd_words[@]}")

    info "Starting container..."
    if [[ "$DRY_RUN" == 1 ]]; then
        run docker "${args[@]}"
        cid="(dry-run)"; status="(dry-run)"
    else
        _log CMD "$(printf '%q ' docker "${args[@]}")"
        cid="$(docker "${args[@]}" 2>>"$LOG_FILE")" || die "docker run failed (see $LOG_FILE)."
        cid="$(printf '%s' "$cid" | tail -n1)"
        add_created "Container: $CONTAINER_NAME (${cid:0:12})"
        sleep 2
        status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
        [[ "$status" == running ]] || die "Container is '$status' instead of running. Check: docker logs $CONTAINER_NAME"
        ok "Container is running (${cid:0:12})."
    fi

    add_summary "Container name" "$CONTAINER_NAME"
    add_summary "Container ID" "${cid:0:12}"
    add_summary "Container status" "$status"
    add_summary "Image" "$DOCKER_IMAGE"
    add_summary "Appdata" "$DOCKER_APPDATA -> $DOCKER_CONFIG_TARGET"
    add_summary "Ports" "${DOCKER_PORTS:-none}"
    add_summary "Network / restart" "$DOCKER_NETWORK / $DOCKER_RESTART"
    add_next "Docker: open a shell with: docker exec -it $CONTAINER_NAME $( [[ "$D_SHELL" == /bin/sh ]] && echo sh || echo bash )"
    if is_yes "$DOCKER_TEMPLATE"; then
        add_next "Docker: edit it from the DOCKER tab (template: my-${CONTAINER_NAME}.xml)"
    else
        add_next "Docker: manage it under the DOCKER tab in the Unraid web UI"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    if [[ "$LIST_ONLY" == 1 ]]; then
        printf '%sUnraid Quick Deploy v%s - what each menu entry resolves to right now%s\n\n' "$C_BOLD" "$QD_VERSION" "$C_RESET"
        detect_downloader >/dev/null
        list_sources || { warn "Some entries could not be resolved (see [!] above)."; exit 1; }
        exit 0
    fi
    banner
    _log START "unraid-quick-deploy v${QD_VERSION} dry_run=${DRY_RUN} assume_yes=${ASSUME_YES} user=$(id -un 2>/dev/null || echo "?")"
    detect_environment
    choose_deploy_type
    validate_deps
    choose_distro
    prepare_defaults
    review_settings
    confirm_plan

    add_summary "Deployment" "$DEPLOY_TYPE"
    [[ $DO_VM == 1 ]] && deploy_vm
    [[ $DO_DOCKER == 1 ]] && deploy_docker

    if [[ "$DRY_RUN" == 1 ]]; then
        [[ -n "$DRY_DIR" ]] && add_summary "Generated previews" "$DRY_DIR"
        print_summary "DRY-RUN"
    else
        print_summary "SUCCESS"
    fi
}

main "$@"

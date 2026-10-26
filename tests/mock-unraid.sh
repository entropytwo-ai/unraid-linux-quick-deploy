#!/bin/bash
#
# tests/mock-unraid.sh - run unraid-quick-deploy.sh against a fake Unraid
# server on any Linux box (no Unraid, libvirt daemon or Docker needed).
#
# It builds a throwaway root under $MOCK_ROOT with:
#   boot/config/{domain,docker,ident}.cfg, etc/unraid-version,
#   mnt/user/{domains,isos,appdata}, a fake docker socket,
# and stub 'virsh' / 'docker' commands that record what they are asked to do.
# Real 'qemu-img' (and genisoimage/xorriso if installed) are used as-is.
#
# Usage (must be root, like on Unraid):
#   sudo tests/mock-unraid.sh [script options]          # interactive
#   sudo DEPLOY_TYPE=both OS_CHOICE=1 tests/mock-unraid.sh --yes
#   sudo MOCK_VIRSH_BROKEN=1 DEPLOY_TYPE=vm tests/mock-unraid.sh --yes   # exercise failure path
#
# Afterwards inspect $MOCK_ROOT/state/ (virsh/docker call logs, defined XML).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${HERE}/../unraid-quick-deploy.sh"
MOCK_ROOT="${MOCK_ROOT:-/tmp/unraid-mock}"
STATE="${MOCK_ROOT}/state"

mkdir -p "$MOCK_ROOT"/{bin,boot/config/plugins/dynamix.vm.manager,etc,nvram,var/run} \
         "$MOCK_ROOT"/mnt/user/{domains,isos,appdata,system} "$STATE"

echo 'version="7.1.4"' >"$MOCK_ROOT/etc/unraid-version"
cat >"$MOCK_ROOT/boot/config/domain.cfg" <<EOF
SERVICE="enable"
DOMAINDIR="$MOCK_ROOT/mnt/user/domains/"
MEDIADIR="$MOCK_ROOT/mnt/user/isos/"
BRNAME="br0"
EOF
cat >"$MOCK_ROOT/boot/config/docker.cfg" <<EOF
DOCKER_ENABLED="yes"
DOCKER_IMAGE_FILE="$MOCK_ROOT/mnt/user/system/docker/docker.img"
DOCKER_APP_CONFIG_PATH="$MOCK_ROOT/mnt/user/appdata/"
DOCKER_BACKINGFS="btrfs"
EOF
echo 'timeZone="America/New_York"' >"$MOCK_ROOT/boot/config/ident.cfg"

# Fake docker socket (the script checks it with [[ -S ]]).
SOCK="$MOCK_ROOT/var/run/docker.sock"
[[ -S "$SOCK" ]] || python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$SOCK"

# A tiny fake "cloud image" served via file://
[[ -f "$MOCK_ROOT/fake-cloud.qcow2" ]] || qemu-img create -q -f qcow2 "$MOCK_ROOT/fake-cloud.qcow2" 2G
[[ -f "$MOCK_ROOT/mnt/user/isos/custom.iso" ]] || head -c 1048576 /dev/zero >"$MOCK_ROOT/mnt/user/isos/custom.iso"

cat >"$MOCK_ROOT/bin/virsh" <<'EOF'
#!/bin/bash
STATE="${MOCK_STATE:?}"
echo "virsh $*" >>"$STATE/virsh.calls"
[[ "${MOCK_VIRSH_BROKEN:-0}" == 1 ]] && { echo "error: failed to connect to the hypervisor" >&2; exit 1; }
case "$1" in
  version) echo "Compiled against library: libvirt 10.7.0"; echo "Running hypervisor: QEMU 9.2.0" ;;
  capabilities) cat <<XML
<capabilities><guest><os_type>hvm</os_type><arch name='x86_64'><wordsize>64</wordsize>
<emulator>/usr/local/sbin/qemu</emulator><machine maxCpus='255'>pc-i440fx-9.2</machine>
<machine maxCpus='255'>pc-i440fx-8.1</machine><machine maxCpus='4096'>pc-q35-9.2</machine>
<machine maxCpus='4096'>pc-q35-10.0</machine></arch></guest></capabilities>
XML
  ;;
  define) n=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$2" | head -1); cp "$2" "$STATE/defined-$n.xml"
          sed -n 's:.*<uuid>\(.*\)</uuid>.*:\1:p' "$2" >"$STATE/uuid-$n"; echo "Domain '$n' defined from $2" ;;
  dominfo|domuuid) [[ -f "$STATE/uuid-$2" ]] || { echo "error: failed to get domain '$2'" >&2; exit 1; }
          if [[ $1 == domuuid ]]; then cat "$STATE/uuid-$2"; else echo "Name: $2"; fi ;;
  start) touch "$STATE/running-$2"; echo "Domain '$2' started" ;;
  domstate) [[ -f "$STATE/running-$2" ]] && echo running || echo "shut off" ;;
  vncdisplay) echo "127.0.0.1:3" ;;
  autostart) echo "Domain '$2' marked as autostarted" ;;
  *) echo "mock virsh: unsupported '$*'" >&2; exit 1 ;;
esac
EOF

cat >"$MOCK_ROOT/bin/docker" <<'EOF'
#!/bin/bash
STATE="${MOCK_STATE:?}"
echo "docker $*" >>"$STATE/docker.calls"
[[ "${MOCK_DOCKER_BROKEN:-0}" == 1 && "$1" != --version ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1" in
  --version) echo "Docker version 27.5.1, build 9f9e405" ;;
  info) if [[ "$*" == *"{{.Driver}}'"* || "$3" == "{{.Driver}}" ]]; then echo btrfs; else echo "27.5.1 (driver: btrfs)"; fi ;;
  ps) cat "$STATE/containers" 2>/dev/null || true ;;
  network) printf 'bridge\nhost\nnone\nbr0\n' ;;
  pull) echo "$2: Pulling from library"; echo "Status: Downloaded newer image for $2" ;;
  run) shift; while [[ $# -gt 0 ]]; do [[ "$1" == --name ]] && name="$2"; shift; done
       echo "$name" >>"$STATE/containers"; echo "running" >"$STATE/status-$name"
       echo "f00dbabe1234567890abcdef$(date +%s)" ;;
  inspect) cat "$STATE/status-${!#}" ;;
  *) echo "mock docker: unsupported '$*'" >&2; exit 1 ;;
esac
EOF
chmod +x "$MOCK_ROOT"/bin/*

export MOCK_STATE="$STATE"
export PATH="$MOCK_ROOT/bin:$PATH"
export UNRAID_BOOT_CONFIG="$MOCK_ROOT/boot/config"
export UNRAID_USER_SHARE="$MOCK_ROOT/mnt/user"
export UNRAID_VERSION_FILE="$MOCK_ROOT/etc/unraid-version"
export NVRAM_DIR="$MOCK_ROOT/nvram"
export DOCKER_SOCK="$SOCK"
export CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL-file://$MOCK_ROOT/fake-cloud.qcow2}"
export VM_BRIDGE="${VM_BRIDGE:-br0}"
exec bash "$SCRIPT" "$@"

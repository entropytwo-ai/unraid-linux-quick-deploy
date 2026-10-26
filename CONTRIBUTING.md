# Contributing

Thanks for helping improve **unraid-linux-quick-deploy**! The most useful contributions are new distros, fixes for upstream URLs that have moved, and fixes for quirks in specific Unraid versions.

## Adding a new distro

Distros are defined in three places in `unraid-quick-deploy.sh`:

1. **`distro_load()`**: add a numbered `case` branch and extend the menu loop in `choose_distro()` (`for i in 1 … 13`).

   ```bash
   13) D_KEY=opensuse; D_NAME="openSUSE Leap 16"; D_ICONS="opensuse.png linux.png"
       D_DOCKER="opensuse/leap:16" ;;
   ```

   | Variable | Meaning |
   |---|---|
   | `D_KEY` | Short id, used for default VM and container names and in the resolvers. |
   | `D_NAME` | Menu label. |
   | `D_ICONS` | Icon filenames to try, in order, from Unraid's VM icon dir. `linux.png` is the fallback. |
   | `D_DOCKER` | Default Docker image. Leave it empty if the distro can't run as a container. |
   | `D_CLOUD` / `D_ISO` | Set to `0` if there's no cloud image or no installer ISO. |
   | `D_CLOUD_BIOS_ONLY` | Set to `1` if the cloud image only boots with SeaBIOS. |
   | `D_MIN_MEM` / `D_MIN_DISK` | Raise defaults the user didn't override (see Omarchy). |
   | `D_OS_TYPE` | `standard`, or a new value if cloud-init needs extra steps (see `omarchy` in `build_seed`). |
   | `D_SHELL` | Login shell (`/bin/sh` on Alpine). |

2. **`resolve_cloud_url()`**: return a stable cloud image URL. Prefer `latest`/`current` symlinks. If the filename is versioned, use `latest_match <index-url> <regex>`.
3. **`resolve_iso_url()`**: same idea for the installer ISO.

Then add a row to the *Supported distributions* table in `README.md`.

## Testing

### Static checks (required)

```bash
bash -n unraid-quick-deploy.sh
shellcheck unraid-quick-deploy.sh tests/mock-unraid.sh
```

### Mock Unraid (any Linux box)

`tests/mock-unraid.sh` fakes Unraid's config files, shares, Docker socket, `virsh`, and `docker`. It uses the real `qemu-img`.

```bash
sudo apt-get install -y qemu-utils genisoimage libvirt-clients   # libvirt-clients gives virt-xml-validate
sudo DEPLOY_TYPE=both OS_CHOICE=1 tests/mock-unraid.sh --yes
sudo virt-xml-validate /tmp/unraid-mock/state/defined-ubuntu2404-1.xml domain
sudo CLOUD_IMAGE_URL= DEPLOY_TYPE=vm OS_CHOICE=13 VM_MODE=cloud tests/mock-unraid.sh --yes --dry-run   # real URL resolution
sudo rm -rf /tmp/unraid-mock
```

### On a real Unraid server

Use a test server, or at least a test VM name, and not production data:

```bash
bash unraid-quick-deploy.sh --dry-run     # check the detection table and generated XML first
bash unraid-quick-deploy.sh
# clean up
virsh destroy <vm>; virsh undefine <vm> --nvram; rm -rf /mnt/user/domains/<vm>
docker rm -f <ct>; rm -rf /mnt/user/appdata/<ct> /boot/config/plugins/dockerMan/templates-user/my-<ct>.xml
```

Checklist before opening a PR:

- [ ] `shellcheck` passes with no warnings.
- [ ] The mock run works for VM, Docker, and Both.
- [ ] Generated XML passes `virt-xml-validate`.
- [ ] On real Unraid: the VM appears in the VMS tab with an icon, *VNC Remote* works, and the cloud login works.
- [ ] The container appears in the DOCKER tab, and if a template was written it can be edited there.
- [ ] Mention your Unraid version and the storage layout you tested on (array/pool, btrfs/zfs/xfs).

## Code style

- Bash with `set -Eeuo pipefail`. Quote every expansion.
- Every setting can be overridden from the environment (`VAR="${VAR:-default}"`) and is shown at a prompt.
- Run mutating commands through `run` / `run_q` / `write_file`, so `--dry-run` and logging keep working.
- Probe tools with `check_tool` (which runs them). Never just test `command -v`.
- Messages: `info`, `ok`, `warn`, `err`, `die`. Nothing should print raw `echo` output except tables and the banner.
- Never commit downloaded images, ISOs, or logs (`.gitignore` covers them).

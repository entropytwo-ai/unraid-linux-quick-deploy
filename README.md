# unraid-linux-quick-deploy

> Quickly deploy Linux on **Unraid** as a **VM**, a **Docker container**, or **both**, from one interactive script. It supports Ubuntu, Debian, Fedora, Arch, Omarchy, NixOS, Rocky, Alpine and CentOS Stream, plus your own ISO or image.

`unraid-quick-deploy.sh` is the Unraid version of [proxmox-linux-quick-deploy](https://github.com/entropytwo-ai/proxmox-linux-quick-deploy). It follows Unraid's own layout: VM disks go in the `domains` share, ISOs and cloud images in the `isos` share, and container config in the `appdata` share. The libvirt XML includes Unraid's `<vmtemplate>` metadata, so new VMs show up in the **VMS** tab. Containers can optionally get a dockerMan template so you can edit them from the **DOCKER** tab.

The script reads your Unraid configuration first. It shows **every detected setting** and lets you accept each one with <kbd>Enter</kbd> or type a new value before anything is created.

<table><tr>
<td><img src=".github/donate-bitcoin-qr.png" width="96" alt="Bitcoin donation QR code"></td>
<td><sub>💛 If you find this project useful, I'd be grateful for any donation. Thank you!<br>
<b>Bitcoin:</b> <code>bc1qu6dkcchurnutgc40y6n53s3zm588z9nnkm2ygq</code></sub></td>
</tr></table>

---

## Table of Contents

- [What it does](#what-it-does)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Walkthrough](#walkthrough)
- [Deployment types](#deployment-types)
- [Supported distributions](#supported-distributions)
- [Unraid auto-detection](#unraid-auto-detection)
- [Configuration reference](#configuration-reference)
- [Where things are stored](#where-things-are-stored)
- [Validation & safety](#validation--safety)
- [Logging & summary](#logging--summary)
- [Troubleshooting / FAQ](#troubleshooting--faq)
- [Testing without Unraid](#testing-without-unraid)
- [Security notice](#security-notice)
- [Contributing](#contributing)
- [License](#license)

---

## What it does

1. **Detects your Unraid setup.** It reads the Unraid version, CPU threads, RAM, KVM support, VM Manager settings (`/boot/config/domain.cfg`), Docker settings (`/boot/config/docker.cfg`), share paths, the VM network bridge, the Docker storage driver, and the time zone. Everything is shown in a table.
2. **Asks how to deploy:** `[1] VM (QEMU/KVM)`, `[2] Docker container`, or `[3] Both`.
3. **Checks that the tools actually work**, not just that they're installed. It runs `virsh version`, `virsh capabilities`, `qemu-img --version`, `docker info`, and `curl --version`. If something is missing it stops with a clear message.
4. **Lets you pick a distro** from a numbered menu, or use a custom ISO or image.
5. **Walks through every setting.** Each detected or default value is shown and you can press <kbd>Enter</kbd> to keep it or type a new one. Then it shows the full plan and asks you to confirm: `[y]es / [e]dit / [q]uit`.
6. **Deploys:**
   - **VM:** downloads the cloud image or installer ISO, creates the vDisk with `qemu-img`, builds a cloud-init seed (cloud mode), generates Unraid-style libvirt XML, runs `virsh define`, and optionally `virsh start` and `virsh autostart`. It prints the VNC address.
   - **Docker:** runs `docker pull` and `docker run` with config in `/mnt/user/appdata/<name>`, plus Unraid's PUID/PGID/TZ conventions. It can optionally save a dockerMan user template.
7. **Logs everything** to `/tmp/unraid-quick-deploy-<timestamp>.log` and finishes with a summary of what was created, IDs, paths, and next steps.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Prerequisites

| Requirement | Needed for | Notes |
|---|---|---|
| **Unraid 6.10+** (6.12 / 7.x recommended) | everything | Run it from the Unraid web terminal (`>_` icon) or SSH as `root`. |
| **Array started** | everything | `/mnt/user/...` shares exist only while the array is running. |
| **VM Manager enabled** | VM | *Settings → VM Manager → Enable VMs: Yes*. This provides `libvirtd`, `virsh`, and `qemu-img`. |
| **HW virtualization (VT-x / AMD-V)** | VM | Must be on in the BIOS so `/dev/kvm` exists. The script warns if it's missing. |
| **Docker enabled** | Docker | *Settings → Docker → Enable Docker: Yes*. The script checks `/var/run/docker.sock` and `docker info`. |
| **Internet access** | downloads | Images come from the official distro mirrors and Docker Hub / Quay. |
| **Free space** | VM | About 0.5–1 GB per cached cloud image or ISO, plus the vDisk (sparse/thin). |

You don't need to install anything extra. The script only uses tools that ship with Unraid (`bash`, `curl`/`wget`, `virsh`, `qemu-img`, `docker`, `openssl`). It checks each one before using it. To build the cloud-init seed it uses `genisoimage`, `mkisofs` or `xorriso` if one is installed. If none of them is there, it builds a small VFAT seed disk with the `dosfstools` tools that ship with Unraid.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Quick start

From the Unraid terminal:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/entropytwo-ai/unraid-linux-quick-deploy/main/unraid-quick-deploy.sh)
```

Or keep a copy on the flash drive so it survives reboots:

```bash
mkdir -p /boot/config/scripts
curl -fsSL -o /boot/config/scripts/unraid-quick-deploy.sh \
  https://raw.githubusercontent.com/entropytwo-ai/unraid-linux-quick-deploy/main/unraid-quick-deploy.sh
bash /boot/config/scripts/unraid-quick-deploy.sh
```

> The flash drive is mounted `noexec`, so always start the script with `bash <script>`, not `./script`.

To preview everything without changing anything:

```bash
bash unraid-quick-deploy.sh --dry-run
```

Fully unattended (accept every detected default):

```bash
DEPLOY_TYPE=both OS_CHOICE=4 VM_MEMORY=4096 DOCKER_PORTS=2222:22 \
DEFAULT_USER=alice DEFAULT_PASS='S3cure!' bash unraid-quick-deploy.sh --yes
```

| Flag | Meaning |
|---|---|
| `-y`, `--yes` | Accept every detected or preset value without prompting. |
| `-n`, `--dry-run` | Detect, prompt, and generate XML / cloud-init / template previews, but don't create, download, define, or run anything. |
| `-h`, `--help` | Show help. |
| `-V`, `--version` | Show version. |

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Walkthrough

> 📸 *Screenshot placeholders: drop real captures into `docs/` and link them here.*

**1. Detection table**

```
━━ Step 1: Detecting Unraid environment ━━━━━━━━━━━━━━━━━━━━━━
  SETTING                      DETECTED VALUE                     SOURCE
  ──────────────────────────────────────────────────────────────────────────────
  Unraid version               7.1.4                              /etc/unraid-version
  CPU threads                  16                                 AMD Ryzen 7 5700G
  RAM total / available        64215 / 51022 MiB                  /proc/meminfo
  HW virtualization / KVM      yes / present                      /proc/cpuinfo, /dev/kvm
  VM Manager                   enabled                            /boot/config/domain.cfg
  VM disk share (domains)      /mnt/user/domains                  DOMAINDIR
  ISO share (isos)             /mnt/user/isos                     MEDIADIR
  VM network bridge            br0                                BRNAME / /sys/class/net
  Docker service               enabled                            /boot/config/docker.cfg
  Docker storage driver        btrfs                              docker info / DOCKER_BACKINGFS
  Docker appdata share         /mnt/user/appdata                  DOCKER_APP_CONFIG_PATH
  ...
```

**2. Deployment type, tool checks, and distro**

```
  Deploy as:  [1] VM (QEMU/KVM)   [2] Docker container   [3] Both
  Select 1-3 [1]: 3
[✓] virsh (libvirt): /usr/bin/virsh  (Compiled against library: libvirt 10.7.0)
[✓] qemu-img: /usr/bin/qemu-img  (qemu-img version 9.2.0)
[✓] docker daemon: /usr/bin/docker  (27.5.1 (driver: btrfs))
  [ 1] Ubuntu 24.04 LTS (Noble)           cloud iso docker
  ...
```

**3. Settings review (Enter = accept)**

```
  These are the detected Unraid settings. Press Enter to accept each or type a new value.
  VM disk share (domains) [/mnt/user/domains]:
  ISO share (isos) [/mnt/user/isos]:
  VM name [debian13-1]: webserver
  vCPUs [2]: 4
  RAM (MiB) [2048]:
  Machine type (q35/i440fx) [q35]:
  ...
  Proceed? [y]es / [e]dit / [q]uit [y]:
```

**4. Summary**

```
════════════════════════════════════════════════════════════════
  Unraid Quick Deploy - SUCCESS
════════════════════════════════════════════════════════════════
  VM name                webserver
  VM UUID                8c1e0f2e-...
  VNC                    192.168.1.10:5900  (display :0)
  Container ID           3f9a1c2b7d10
  ...
  Next steps:
    → VM: wait ~1 min for cloud-init, then find the IP with: virsh domifaddr 'webserver' --source agent
    → Docker: open a shell with: docker exec -it debian13-1 bash
  Log file: /tmp/unraid-quick-deploy-20261026-170237.log
```

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Deployment types

### `[1]` VM (QEMU/KVM via libvirt)

You can pick one of two install methods:

| Method | What happens | Best for |
|---|---|---|
| **Cloud image** (default) | Downloads the official cloud image to `isos/cloud-images/` once, converts it to a vDisk, resizes it, and attaches a cloud-init **NoCloud** seed. The VM boots straight into a working system with your user, password, sudo, SSH password login, and `qemu-guest-agent`. | Fast, repeatable servers. Works like the Proxmox version. |
| **Installer ISO** | Downloads the distro's installer ISO to the `isos` share (or uses one you already have), creates an empty vDisk, and boots from the ISO. You finish the install over VNC. | Desktops, custom partitioning, distros without cloud images. |

The generated XML follows what Unraid's VM Manager writes:

- `<vmtemplate xmlns="unraid" name="Linux" icon="…" os="linux"/>` metadata, so the VM gets a distro icon in the VMS tab when Unraid has one.
- vDisk `vdisk1.img` on the **VirtIO** bus (`hdc`), with `cache='writeback'` and `discard='unmap'`.
- Installer ISO and cloud-init seed as SATA CD-ROMs (q35) or IDE CD-ROMs (i440fx).
- **Machine type:** you choose `q35` or `i440fx`. The newest version this server's QEMU supports is used, e.g. `pc-q35-9.2`.
- **BIOS:** SeaBIOS or OVMF (UEFI). The OVMF vars are copied to `/etc/libvirt/qemu/nvram/<uuid>_VARS-pure-efi.fd`, the same place Unraid keeps them.
- `host-passthrough` CPU, optional **CPU pinning** (`<vcpupin>`), `memballoon` off, and `nosharepages`.
- Bridged VirtIO network on `br0` (or whatever `BRNAME` / `virbr0` your server uses).
- **VNC** with autoport, websocket, and your choice of keymap, so *VNC Remote* in the web UI works right away.
- QEMU guest-agent channel and a serial console.

### `[2]` Docker container

- Uses the distro's official image (e.g. `debian:13`) or any image you enter.
- Config and data are stored in **`/mnt/user/appdata/<container>/`**, mounted at `/config`.
- Unraid conventions are applied: `PUID=99` (nobody), `PGID=100` (users), `UMASK=022`, and `TZ` from your Unraid settings.
- Prompts for port mappings, extra volume mounts, extra env vars, network (`bridge`, `host`, `br0`, …), and restart policy (default **`unless-stopped`**).
- Runs with `--init` and `tail -f /dev/null` so a plain distro container stays up. You can change the command.
- Optionally writes a **dockerMan user template** (`/boot/config/plugins/dockerMan/templates-user/my-<name>.xml`), so the container can be edited, updated, and re-created from the DOCKER tab.
- Prints the container ID and checks that the container is actually `running`.

### `[3]` Both

Deploys the same distro as a VM **and** as a container, each with its own settings. If the prerequisites for only one side fail, the script asks whether to continue with the other.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Supported distributions

| # | Distribution | Cloud image (VM) | Installer ISO (VM) | Docker image |
|---|---|:-:|:-:|---|
| 1 | Ubuntu 24.04 LTS (Noble) | ✅ | ✅ live-server (latest point release) | `ubuntu:24.04` |
| 2 | Ubuntu 26.04 LTS (Resolute) | ✅ | ✅ live-server | `ubuntu:26.04` |
| 3 | Debian 12 (Bookworm) | ✅ | ✅ netinst (oldstable) | `debian:12` |
| 4 | Debian 13 (Trixie) | ✅ | ✅ netinst (stable) | `debian:13` |
| 5 | Fedora (newest release, auto-detected) | ✅ Cloud Base | ✅ Server netinst | `fedora:<version>` |
| 6 | Arch Linux | ✅ | ✅ | `archlinux:latest` |
| 7 | Omarchy (Arch + Omarchy ready) | ✅ 4 GB RAM / 32 GB disk | – | – (needs a VM) |
| 8 | NixOS (unstable) | – | ✅ minimal | `nixos/nix:latest` |
| 9 | Rocky Linux 9 | ✅ GenericCloud | ✅ minimal | `rockylinux/rockylinux:9` |
| 10 | Alpine Linux (latest stable) | ✅ BIOS cloud-init | ✅ virt | `alpine:latest` |
| 11 | CentOS Stream 10 | ✅ GenericCloud | ✅ boot | `quay.io/centos/centos:stream10` |
| 12 | Rocky Linux 10 | ✅ GenericCloud-Base | ✅ minimal | `rockylinux/rockylinux:10` |
| 13 | Ubuntu LTS (newest, looked up live) | ✅ | ✅ live-server | `ubuntu:<version>` |
| 14 | Ubuntu newest release (incl. interim) | ✅ | ✅ live-server | `ubuntu:<version>` |
| 15 | Debian stable (looked up live) | ✅ | ✅ netinst | `debian:<version>` |
| 16 | Debian oldstable (looked up live) | ✅ | ✅ netinst | `debian:<version>` |
| c | **Custom** | – | ✅ any local ISO path or URL | any image you enter |

**Nothing is pinned.** Each time the script runs, it reads the distro's own release metadata or mirror listing and picks the newest dated or versioned build. It never uses a moving `latest` alias, so a newer release is downloaded fresh instead of reusing an old cached copy. Entries 13–16 also look up *which release* is current (from Canonical's `meta-release` and Debian's `stable`/`oldstable` suites), so they move to a new LTS or stable release on their own. Menu numbers never change meaning. New entries are added at the end, and every entry also has a stable id (e.g. `OS_CHOICE=debian-stable`).

To see what each entry points to right now, run this. It needs no root and changes nothing:

```bash
./unraid-quick-deploy.sh --list
```

**Checksums.** Every looked-up image and ISO is checked against the SHA-256/SHA-512 file its mirror publishes. A cached copy is re-checked before reuse and downloaded again if it no longer matches. A mismatch after a fresh download deletes the file and stops the script. For your own `CLOUD_IMAGE_URL` / `ISO_URL`, point `CLOUD_IMAGE_SUM_URL` / `ISO_SUM_URL` at a checksum file; otherwise the download is reported as *not verified*.

**Omarchy:** cloud-init puts `~/install-omarchy.sh` in your home directory and adds a login reminder. After the first boot, log in and run `./install-omarchy.sh`.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Unraid auto-detection

| What | Where it comes from | Fallback |
|---|---|---|
| Unraid version | `/etc/unraid-version` | Warns and asks before continuing on non-Unraid hosts. |
| VM Manager on/off | `SERVICE` in `/boot/config/domain.cfg`, plugin dir `/boot/config/plugins/dynamix.vm.manager/` | `virsh` availability |
| VM disk share | `DOMAINDIR` in `domain.cfg` | `/mnt/user/domains` |
| ISO share | `MEDIADIR` in `domain.cfg` | `/mnt/user/isos` |
| VM bridge | `BRNAME` in `domain.cfg` → `br0` → `virbr0` → first bridge | `br0` |
| Docker on/off | `DOCKER_ENABLED` in `/boot/config/docker.cfg`, `/var/run/docker.sock` | – |
| Docker storage driver | `docker info` → `DOCKER_BACKINGFS` in `docker.cfg` | – |
| Docker vDisk/dir | `DOCKER_IMAGE_FILE` in `docker.cfg` | – |
| Appdata share | `DOCKER_APP_CONFIG_PATH` in `docker.cfg` | `/mnt/user/appdata` |
| CPU / RAM | `nproc`, `/proc/meminfo` | – |
| KVM | `vmx`/`svm` CPU flags, `/dev/kvm` | – |
| QEMU emulator & machine types | `virsh capabilities` | `/usr/local/sbin/qemu`, `q35` / `pc` |
| OVMF firmware | `/usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd` (Unraid) and common distro paths | Falls back to SeaBIOS |
| Time zone | `timeZone` in `/boot/config/ident.cfg` | `/etc/localtime`, `Etc/UTC` |

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Configuration reference

Every setting can be **preset from the environment**. Presets become the defaults shown at each prompt; with `--yes` they're used as-is.

### General

| Variable | Default | Description |
|---|---|---|
| `DEPLOY_TYPE` | *(prompt)* | `vm` / `docker` / `both` (or `1` / `2` / `3`). |
| `OS_CHOICE` | *(prompt)* | `1`–`16`, `c` (custom), or an id such as `ubuntu-lts` / `debian-stable` (see `--list`). |
| `ASSUME_YES` | `0` | `1` is the same as `--yes`. |
| `DRY_RUN` | `0` | `1` is the same as `--dry-run`. |
| `LOG_DIR` | `/tmp` | Where `unraid-quick-deploy-<timestamp>.log` is written. |
| `UNRAID_BOOT_CONFIG` | `/boot/config` | Unraid flash config directory. |
| `UNRAID_USER_SHARE` | `/mnt/user` | User share root. |

### Storage

| Variable | Default | Description |
|---|---|---|
| `DOMAINS_PATH` | `DOMAINDIR` or `/mnt/user/domains` | VM share. Each VM gets its own `<name>/` subfolder. |
| `ISO_PATH` | `MEDIADIR` or `/mnt/user/isos` | Where installer ISOs are stored or looked up. |
| `CLOUD_CACHE` | `<ISO_PATH>/cloud-images` | Cloud image cache, downloaded once per distro. |
| `APPDATA_PATH` | `DOCKER_APP_CONFIG_PATH` or `/mnt/user/appdata` | Docker appdata share. |

### VM

| Variable | Default | Description |
|---|---|---|
| `VM_MODE` | *(prompt)* / `cloud` | `cloud` or `iso`. |
| `VM_NAME` | `<distro>-N` (first free) | Libvirt domain name and folder name. |
| `VM_CPUS` | `2` | vCPUs (capped to the host's threads). |
| `VM_CPU_PIN` | *(none)* | Comma list of host cores, e.g. `2,3,10,11`. Sets `VM_CPUS` to match. Leave core 0 for Unraid. |
| `VM_MEMORY` | `2048` (`4096` Omarchy) | RAM in MiB. |
| `VM_DISK_SIZE` | `20G` (`32G` Omarchy) | vDisk size (`M`/`G`/`T`). |
| `VM_DISK_FORMAT` | `qcow2` | `qcow2` or `raw`. |
| `VM_DISK_NAME` | `vdisk1.img` | Unraid's standard vDisk filename. |
| `VM_MACHINE` | `q35` | `q35` or `i440fx`. The newest version available is used. |
| `VM_BIOS` | `seabios` | `seabios` or `ovmf` (UEFI). |
| `VM_BRIDGE` | detected (`br0`) | Network bridge. |
| `VM_VNC_LISTEN` | `0.0.0.0` | VNC listen address. |
| `VM_VNC_KEYMAP` | `en-us` | VNC keyboard layout. |
| `VM_ISO_FILE` | `<ISO_PATH>/<iso name>` | Installer ISO: an existing path, a download target, or a URL. |
| `VM_START` | `yes` | Start the VM after defining it. |
| `VM_AUTOSTART` | `no` | `virsh autostart` (starts with the array). |
| `DEFAULT_USER` | `admin` | Cloud-init sudo user. |
| `DEFAULT_PASS` | `password123` | Password for the user **and root**. **Change it.** |
| `CLOUD_IMAGE_URL` | *(per distro)* | Override the cloud image URL. |
| `ISO_URL` | *(per distro)* | Override the installer ISO URL. |
| `CLOUD_IMAGE_SUM_URL` | *(empty)* | Checksum file for a `CLOUD_IMAGE_URL` override. |
| `ISO_SUM_URL` | *(empty)* | Checksum file for an `ISO_URL` override. |
| `VERIFY_CHECKSUMS` | `yes` | `no` skips checksum verification (not recommended). |
| `FEDORA_VERSION` | newest | Pin a Fedora release, e.g. `43`. |
| `NVRAM_DIR` | `/etc/libvirt/qemu/nvram` | Where OVMF vars files go. |

### Docker

| Variable | Default | Description |
|---|---|---|
| `CONTAINER_NAME` | `<distro>-N` (first free) | Container name and hostname. |
| `DOCKER_IMAGE` | *(per distro)* | `image:tag`. |
| `DOCKER_APPDATA` | `<APPDATA_PATH>/<CONTAINER_NAME>` | Host folder for config/data. |
| `DOCKER_CONFIG_TARGET` | `/config` | Where appdata is mounted in the container. |
| `DOCKER_PORTS` | *(none)* | `host:container[/tcp\|udp]`, comma separated, e.g. `8080:80,5353:53/udp`. |
| `DOCKER_VOLUMES` | *(none)* | `/host:/container[:ro\|rw]`, comma separated. |
| `DOCKER_ENV` | *(none)* | `KEY=value`, comma separated. |
| `DOCKER_NETWORK` | `bridge` | Any existing Docker network (`host`, `br0`, …). |
| `DOCKER_RESTART` | `unless-stopped` | `no`, `always`, `unless-stopped`, `on-failure[:N]`. |
| `DOCKER_CMD` | `tail -f /dev/null` | Command that keeps the container running. |
| `DOCKER_PUID` / `DOCKER_PGID` | `99` / `100` | Unraid `nobody:users`. |
| `DOCKER_TEMPLATE` | `yes` | Write a dockerMan user template. |

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Where things are stored

```
/mnt/user/
├── domains/
│   └── <vm-name>/
│       ├── vdisk1.img            # VM disk (qcow2 or raw)
│       ├── <vm-name>.xml         # copy of the libvirt definition
│       ├── cloud-init.iso|.img   # NoCloud seed (cloud mode)
│       └── cloud-init/           # user-data / meta-data sources
├── isos/
│   ├── <installer>.iso           # downloaded installer ISOs
│   └── cloud-images/             # cached cloud images (one per distro)
└── appdata/
    └── <container-name>/         # mounted at /config in the container

/boot/config/plugins/dockerMan/templates-user/my-<container>.xml   # optional template
/etc/libvirt/qemu/nvram/<uuid>_VARS-pure-efi.fd                    # OVMF vars (UEFI VMs)
/tmp/unraid-quick-deploy-<timestamp>.log                           # run log
```

The VM definition itself is stored by libvirt, inside Unraid's `libvirt.img`, through `virsh define`. That's the same place the VM Manager keeps VMs created in the web UI.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Validation & safety

- **Tools are actually run, not just located.** Each one has to be on `PATH`, be executable, and pass a real command: `virsh version`, `virsh capabilities`, `qemu-img --version`, `docker --version`, `docker info`, `curl --version` / `wget --version`.
- **Service checks.** It makes sure the VM Manager / Docker service is enabled in Unraid's config and that the Docker socket exists.
- **Paths.** Target directories must exist or be creatable, and must be **writable**. This is tested with a real write. Creating a new top-level folder under `/mnt/user` makes a new share, and the script warns you about that first.
- **No overwrites.** VM and container names must be unused, and an existing vDisk is never overwritten.
- **Safe downloads.** Files download to `*.part` and are renamed only after they complete. Every looked-up download is checked against its mirror's published SHA-256/SHA-512 checksum. Cached ISOs and cloud images are re-checked before they are reused.
- **Post-checks.** After `virsh define`, the VM must show up in `virsh dominfo`. After `virsh start`, it must be `running`. After `docker run`, the container must be `running`.
- **Errors.** Any failure stops the script with a clear message, a list of what was already created, and the log path.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Logging & summary

All detections, prompt answers, commands, and command output go to `/tmp/unraid-quick-deploy-<timestamp>.log`. Passwords are masked in the answer log. The final summary lists:

- deployment type and distro
- VM name, **UUID**, vDisk, resources, network/MAC, **VNC address**, XML path, guest login
- **container ID**, status, image, appdata, ports, network/restart
- everything that was created
- next steps (find the VM's IP, VNC, `docker exec`, where to manage it in the web UI)

> `/tmp` is in RAM on Unraid. Copy the log to a share if you want to keep it after a reboot.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Troubleshooting / FAQ

<details>
<summary><b>"virsh (libvirt): 'virsh version' failed"</b></summary>

libvirt isn't running. Go to *Settings → VM Manager*, set **Enable VMs: Yes**, and apply. The array must be started, because `libvirt.img` lives on a share.
</details>

<details>
<summary><b>"/dev/kvm is missing"</b></summary>

Turn on Intel VT-x / AMD-V (SVM) in the motherboard BIOS. *Tools → System Devices* and the VM Manager settings page show whether HVM is available.
</details>

<details>
<summary><b>"docker daemon: 'docker info' failed" / socket not found</b></summary>

Go to *Settings → Docker*, set **Enable Docker: Yes**, and make sure the Docker vDisk/directory is mounted (array started).
</details>

<details>
<summary><b>The cloud VM boots, but I can't log in over SSH</b></summary>

- Give it a minute. cloud-init installs `qemu-guest-agent` and restarts SSH on first boot.
- Get the IP with `virsh domifaddr <vm> --source agent`, or check your router's DHCP leases.
- Use *VNC Remote* in the VMS tab, or the serial console: `virsh console <vm>`.
- The seed is attached as `cloud-init.iso` (or `cloud-init.img`). Don't remove it before the first boot finishes.
</details>

<details>
<summary><b>How do I remove the installer ISO after installing?</b></summary>

Edit the VM in the VMS tab, clear the *OS Install ISO* field, and save. Or run `virsh edit <vm>` and delete the CD-ROM `<disk>` block.
</details>

<details>
<summary><b>A download fails (404)</b></summary>

Run `./unraid-quick-deploy.sh --list` to see which entries currently resolve. Mirrors sometimes change their layout. Rerun with `CLOUD_IMAGE_URL=...` or `ISO_URL=...` (plus `*_SUM_URL` for verification), and please open an issue or PR. Partial downloads are kept as `*.part` and never reused.
</details>

<details>
<summary><b>CHECKSUM MISMATCH</b></summary>

The file did not match the hash its mirror publishes, usually because of a corrupted transfer or a mirror that is mid-sync. The bad file has already been deleted. Rerun the script to download it again.
</details>

<details>
<summary><b>The container exits immediately</b></summary>

Plain distro images have no long-running service. Keep the default command (`tail -f /dev/null`) or set `DOCKER_CMD` to your own service, then check `docker logs <name>`.
</details>

<details>
<summary><b>How do I undo a deployment?</b></summary>

```bash
virsh destroy <vm>; virsh undefine <vm> --nvram; rm -rf /mnt/user/domains/<vm>
docker rm -f <container>; rm -rf /mnt/user/appdata/<container>
rm -f /boot/config/plugins/dockerMan/templates-user/my-<container>.xml
```
</details>

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Testing without Unraid

`tests/mock-unraid.sh` creates a fake Unraid server under `/tmp/unraid-mock`: `domain.cfg`, `docker.cfg`, shares, a Docker socket, and stub `virsh`/`docker` commands. It then runs the real script against it. The real `qemu-img` (and `genisoimage`/`xorriso` if installed) is used.

```bash
sudo tests/mock-unraid.sh                                        # interactive
sudo DEPLOY_TYPE=both OS_CHOICE=1 tests/mock-unraid.sh --yes     # unattended
sudo MOCK_VIRSH_BROKEN=1 DEPLOY_TYPE=vm tests/mock-unraid.sh -y  # failure path
sudo MOCK_BAD_CHECKSUM=1 DEPLOY_TYPE=vm OS_CHOICE=1 VM_MODE=cloud tests/mock-unraid.sh -y  # checksum mismatch path
ls /tmp/unraid-mock/state                                        # recorded virsh/docker calls + defined XML
```

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Security notice

The cloud-image defaults are meant for **homelab convenience**: a well-known password, root SSH login, and password authentication are all on. Before a VM touches anything important:

- Set a strong `DEFAULT_PASS`, or change passwords right after first login.
- Switch to SSH keys and disable `PasswordAuthentication` and `PermitRootLogin`.
- Don't port-forward these VMs or containers to the internet.

<sub>[↑ Back to contents](#table-of-contents)</sub>

## Contributing

PRs are welcome, especially new distros, updated mirror URLs, and Unraid version quirks. See [CONTRIBUTING.md](CONTRIBUTING.md).

<sub>[↑ Back to contents](#table-of-contents)</sub>

## License

MIT

<sub>[↑ Back to contents](#table-of-contents)</sub>

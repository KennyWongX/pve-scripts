### AI Generated Script and README
### Run it

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/KennyWongX/pve-scripts/master/vm-deploy-linux/vm/vm-deploy.sh)"
```

Run as root on the PVE host console (or over SSH with a real TTY — not
`curl | bash`, which breaks the interactive prompts; see
[Requirements](#requirements)).

### What it does

1. Prompts for guest OS, VM ID, hostname, CPU/RAM, disk size, and storage
   target
2. Prompts for one or more network interfaces — bridge, DHCP or static
   IP/CIDR, and an **optional** gateway per interface (skip it for
   gateway-less networks like a storage/backup VLAN)
3. Prompts for an admin username/password, optional SSH public key, and any
   optional guest packages (e.g. NFS client tools)
4. Downloads and caches the selected cloud image
5. Builds the VM: UEFI (OVMF), q35 machine type, VirtIO SCSI single
   controller, SPICE display, `qemu-guest-agent` pre-installed via
   cloud-init
6. If anything fails partway through, automatically rolls back — destroys
   the partial VM and removes its leftover cloud-init snippet, so a failed
   run never leaves orphaned fragments behind

### Requirements

- Runs on Proxmox VE (needs `qm`, `pvesm`, `pvesh`)
- `whiptail` and `curl` (both present on a stock PVE install)
- A real TTY on stdin — this is why the run command is
  `bash -c "$(curl ...)"` rather than `curl ... | bash`. Piping into `bash`
  hands the script's own bytes to whiptail's stdin instead of your
  keyboard, and it will fail or behave oddly.
- Nothing else. The script is a single self-contained file — no `git`, no
  second file to fetch, no dependency beyond what's already on a stock PVE
  node.

### Supported OS images

| Key | OS |
|---|---|
| `debian12` | Debian 12 (Bookworm) |
| `debian13` | Debian 13 (Trixie) |
| `ubuntu2204` | Ubuntu 22.04 LTS |
| `ubuntu2404` | Ubuntu 24.04 LTS |
| `rocky9` | Rocky Linux 9 |

To add another OS: add a `declare -A OS_URL` entry and a matching menu line
in `prompt_os()`, both near the top of the script under `[1] CONFIG`.

### Configuration

Everything worth adjusting lives in the `[1] CONFIG` block at the top of
the script, with inline comments explaining each variable — hardware
profile (machine type, BIOS, CPU type, SCSI controller), prompt defaults
(cores, memory, disk size), NIC count and gateway defaults, and which guest
packages are offered. No need to read past that block to customize the
script for a different environment.

### Maintenance

Downloaded cloud images are cached in `/var/lib/vz/template/iso/*.qcow2`
and reused across runs — they are **not** deleted automatically, since
they're shared across every VM built from that OS, not tied to any single
VM's lifecycle. Removing a cached image doesn't affect VMs already built
from it.

Manual cleanup:
```bash
rm /var/lib/vz/template/iso/*.qcow2 /var/lib/vz/template/iso/*.img
```

Automatic cleanup (prune anything unused for 90 days — add to `crontab -e`):
```
0 3 * * 0 find /var/lib/vz/template/iso -name '*.qcow2' -mtime +90 -delete
```

### Troubleshooting

- **`git is required` / any error mentioning `REPO_RAW`** — you're running
  a stale or partially-merged copy. The current script is fully
  self-contained; if you see either of these, re-fetch the file from
  GitHub and fully replace your local copy rather than hand-editing it.
- **`<!DOCTYPE html>` / bash syntax errors right after `curl`** — the URL
  being fetched is a `github.com/.../blob/` or `.../tree/` page (HTML),
  not a `raw.githubusercontent.com` URL (plain text). Only raw URLs work
  with this run pattern.
- **Stale content after pushing a fix** — `raw.githubusercontent.com` is
  CDN-cached and can lag a few minutes behind a push. Cache-bust with a
  throwaway query string if you need to verify immediately:
  `curl -fsSL "<url>?x=$(date +%s)"`
- **`zfs create ... failed: got timeout` during disk creation** — usually
  a transient pool/host load spike, not a sign of a failing disk. Check
  `zpool status` (should be `ONLINE`, no errors) and `zpool list` (should
  have healthy free space), then just retry the deploy.

### Roadmap

- Windows Server deploy script (ISO + VirtIO driver injection + sysprep —
  a materially different pipeline from the Linux cloud-image approach, so
  likely a separate `vm-deploy-windows.sh` rather than a shared code path)
- Optional VLAN tag per NIC
- Optional "start on boot" toggle
- Silent `--tags` on created VMs for at-a-glance provenance in the PVE UI

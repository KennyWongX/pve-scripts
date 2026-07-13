#!/usr/bin/env bash
# ============================================================================
# vm-deploy.sh - Interactive Proxmox VE VM builder (cloud-image based)
#
# SINGLE-FILE, SELF-CONTAINED: helpers are inlined, nothing else is fetched.
# Requires only bash + curl + whiptail (all present on a stock PVE install).
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/KennyWongX/pve-scripts/master/vm-deploy-linux/vm/vm-deploy.sh)"
#
# Structure:
#   [1] CONFIG      - everything you'd ever want to tweak lives here
#   [2] HELPERS     - shared functions (prompts, pickers, validators, rollback)
#   [3] PROMPTS     - one function per question group
#   [4] BUILD       - one function per build stage
#   [5] main        - just calls the functions in order
# ============================================================================


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ [1] CONFIG - edit this section, leave the rest alone                      ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# --- OS catalog. Add a line here + a menu entry in prompt_os() to add an OS.
#     Key = short id (no spaces), value = cloud image URL.
declare -A OS_URL=(
  [debian12]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  [debian13]="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  [ubuntu2204]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  [ubuntu2404]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  [rocky9]="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
)

# --- Prompt defaults (what's pre-filled in each whiptail box) ----------------
DEF_CORES="2"                  # CPU cores
DEF_MEMORY="2048"              # RAM in MB
DEF_DISK="20G"                 # disk size after resize
DEF_USER="admin"               # cloud-init admin username
DEF_DNS="1.1.1.1"              # DNS server(s), space separated

# --- Hardware profile (applied to every VM this script builds) ---------------
VM_MACHINE="q35"               # machine type
VM_BIOS="ovmf"                 # "ovmf" (UEFI) or "seabios"
VM_VGA="qxl"                   # "qxl" = SPICE. Use "std" or "virtio" otherwise
VM_SCSIHW="virtio-scsi-single" # SCSI controller
VM_CPU="host"                  # CPU type. "host" = best perf, breaks live
                               # migration between different CPU generations -
                               # use "x86-64-v2-AES" for a mixed cluster
VM_OSTYPE="l26"                # guest OS type hint (l26 = Linux 2.6+)
EFI_OPTS="efitype=4m,pre-enrolled-keys=0"  # pre-enrolled-keys=0 avoids Secure
                               # Boot failures on Debian/Rocky images

# --- Networking ---------------------------------------------------------------
MAX_NICS=2                     # how many NICs the script offers. NIC 1 is
                               # mandatory; NICs 2..MAX_NICS are optional.
GW_DEFAULT_NIC1="yes"          # gateway prompt default on NIC 1 ("yes"/"no")
GW_DEFAULT_OTHER="no"          # gateway prompt default on NIC 2+ - a second
                               # default route is usually a mistake
NIC_MODEL="virtio"             # NIC model for every interface

# --- Guest packages (installed on first boot via cloud-init) -----------------
# Always installed:
BASE_PACKAGES=("qemu-guest-agent")
# Offered as a yes/no prompt. Format: "Prompt text|debian_pkg|rhel_pkg"
# Add lines to offer more optional packages; remove to stop asking.
OPTIONAL_PACKAGES=(
  "Install NFS client tools?|nfs-common|nfs-utils"
)

# --- Paths / storage ----------------------------------------------------------
IMG_CACHE_DIR="/var/lib/vz/template/iso"   # where cloud images are cached
SNIPPET_DIR="/var/lib/vz/snippets"         # must be on a storage with
SNIPPET_STORE="local:snippets"             # 'Snippets' content type enabled

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ End of CONFIG - no user-serviceable parts below                          ║
# ╚══════════════════════════════════════════════════════════════════════════╝



# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ SHARED HELPERS (inlined from build.func - single-file, no second fetch)   ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# ----------------------------- output --------------------------------------
RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; BL=$'\033[36m'; CL=$'\033[m'
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"

msg()  { echo -e " ${CM} ${GN}$*${CL}"; }
info() { echo -e " ${BL}ℹ${CL} $*"; }
warn() { echo -e " ${YW}⚠${CL} ${YW}$*${CL}"; }
die()  { echo -e " ${CROSS} ${RD}$*${CL}" >&2; exit 1; }

header_info() {
  # header_info "Debian 12 VM"
  clear
  cat <<EOF
${BL}
  ╔═══════════════════════════════════════════╗
  ║           PVE VM Deployment               ║
  ╚═══════════════════════════════════════════╝
${CL}
  ${GN}${1:-}${CL}

EOF
}

# ----------------------------- environment checks --------------------------
init_pve() {
  [[ $EUID -eq 0 ]] || die "Must run as root on the PVE host."
  command -v qm       >/dev/null 2>&1 || die "'qm' not found - run this on a Proxmox VE node."
  command -v pvesm    >/dev/null 2>&1 || die "'pvesm' not found - run this on a Proxmox VE node."
  command -v whiptail >/dev/null 2>&1 || die "'whiptail' not found (apt install whiptail)."
  command -v curl     >/dev/null 2>&1 || die "'curl' not found (apt install curl)."

  local ver
  ver=$(pveversion | grep -oP 'pve-manager/\K[0-9]+' || echo 0)
  [[ "$ver" -ge 8 ]] || warn "Tested on PVE 8+. Detected major version: ${ver}."

  # whiptail needs a real TTY. Catches the classic `curl ... | bash` mistake.
  [[ -t 0 ]] || die "No TTY on stdin. Use: bash -c \"\$(curl -fsSL <url>)\" - not curl | bash"
}

# ----------------------------- rollback / trap -----------------------------
# Any script that creates a VM sets VMID and flips VM_CREATED=1 immediately
# after `qm create` succeeds. If the script then dies, we tear the VM down so
# no orphaned/half-built VMIDs are left behind.
VM_CREATED=0
VMID=""

_on_error() {
  local rc=$?
  [[ $rc -eq 0 ]] && exit 0
  echo
  warn "Script failed (exit ${rc})."
  if [[ "$VM_CREATED" -eq 1 && -n "$VMID" ]]; then
    warn "Rolling back partially-created VM ${VMID}..."
    qm stop "$VMID" &>/dev/null || true
    qm destroy "$VMID" --purge --destroy-unreferenced-disks 1 &>/dev/null \
      && msg "VM ${VMID} removed." \
      || warn "Could not fully remove VM ${VMID} - check manually."
  fi
  # The cloud-init snippet is written before `qm create` runs, so it can be
  # orphaned even when VM_CREATED never got set. Safe to always attempt -
  # rm -f is a no-op if it was never written or already cleaned up above.
  if [[ -n "$VMID" && -f "/var/lib/vz/snippets/vendor-${VMID}.yaml" ]]; then
    rm -f "/var/lib/vz/snippets/vendor-${VMID}.yaml" \
      && msg "Removed leftover cloud-init snippet for ${VMID}." \
      || warn "Could not remove snippet for ${VMID} - check manually."
  fi
  exit "$rc"
}

set_error_trap() {
  set -euo pipefail
  trap _on_error EXIT
}

# Call on success so the EXIT trap doesn't second-guess a clean finish.
clear_error_trap() { trap - EXIT; }

# ----------------------------- whiptail wrappers ---------------------------
# Every prompt exits cleanly on Cancel/Esc instead of returning an empty string
# that silently poisons a later qm call.
ask() {
  # ask "Title" "Prompt" "default" -> echoes the answer
  local out
  out=$(whiptail --title "$1" --inputbox "$2" 9 68 "${3:-}" 3>&1 1>&2 2>&3) || die "Cancelled."
  [[ -n "$out" ]] || die "A value is required for: $2"
  echo "$out"
}

ask_secret() {
  local out
  out=$(whiptail --title "$1" --passwordbox "$2" 9 68 3>&1 1>&2 2>&3) || die "Cancelled."
  [[ -n "$out" ]] || die "A value is required for: $2"
  echo "$out"
}

confirm() {
  # confirm "Title" "Question" [defaultno]  -> returns 0 = yes, 1 = no
  local extra=()
  [[ "${3:-}" == "defaultno" ]] && extra+=(--defaultno)
  whiptail --title "$1" --yesno "$2" 10 68 "${extra[@]}"
}

# ----------------------------- pickers -------------------------------------
select_storage() {
  # select_storage [content_type]  (default: images) -> echoes storage id
  local content="${1:-images}" menu=() tag free
  while read -r tag _ _ _ free _; do
    [[ -n "$tag" ]] || continue
    menu+=("$tag" "$(numfmt --from-unit=K --to=iec --format '%.1f' "$free" 2>/dev/null || echo '?') free")
  done < <(pvesm status -content "$content" | awk 'NR>1 && $3=="active" {print $1, $2, $3, $4, $6, $7}')

  [[ ${#menu[@]} -gt 0 ]] || die "No active storage with content type '${content}'."

  # Only one option? Don't make the user click through a one-item menu.
  if [[ ${#menu[@]} -eq 2 ]]; then
    echo "${menu[0]}"
    return
  fi
  whiptail --title "Storage" --menu "Select storage (content: ${content}):" 18 60 8 \
    "${menu[@]}" 3>&1 1>&2 2>&3 || die "Cancelled."
}

select_bridge() {
  # select_bridge "NIC 1" -> echoes vmbrX
  # Shows IP + the PVE "Comment" field (Datacenter > Node > Network > Edit),
  # so a bridge tagged e.g. "10Gbe Uplink" is identifiable without leaving the script.
  local menu=() br ip comment desc node
  node=$(hostname -s)

  for br in $(find /sys/class/net -mindepth 1 -maxdepth 1 -name 'vmbr*' -printf '%f\n' | sort); do
    ip=$(ip -4 -o addr show "$br" 2>/dev/null | awk '{print $4}' | paste -sd, -)
    [[ -n "$ip" ]] || ip="no ip"

    comment=""
    if command -v pvesh >/dev/null 2>&1; then
      comment=$(pvesh get "/nodes/${node}/network/${br}" --output-format json 2>/dev/null \
        | perl -MJSON::PP -0777 -ne 'eval { print decode_json($_)->{comments} // ""; };' 2>/dev/null)
      comment=${comment//$'\n'/ }   # flatten multi-line comments to one menu line
    fi

    desc="$ip"
    [[ -n "$comment" ]] && desc="${ip}  |  ${comment}"
    menu+=("$br" "$desc")
  done

  [[ ${#menu[@]} -gt 0 ]] || die "No vmbr bridges found. (Bonds must sit under a bridge to be used by a VM.)"
  whiptail --title "${1:-Network}" --menu "Select bridge:" 18 74 8 \
    "${menu[@]}" 3>&1 1>&2 2>&3 || die "Cancelled."
}

get_free_vmid() { pvesh get /cluster/nextid; }

validate_vmid() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "VMID must be numeric: $1"
  [[ "$1" -ge 100 ]]     || die "VMID must be >= 100."
  qm status "$1" &>/dev/null && die "VMID $1 is already in use."
  pct status "$1" &>/dev/null && die "VMID $1 is already used by a container."
  return 0
}

validate_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Expected IP with CIDR (e.g. 10.0.10.50/24), got: $1"
}

validate_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Expected a plain IP address, got: $1"
}

# ----------------------------- misc ----------------------------------------
ensure_snippets() {
  # Snippets content type must be enabled on 'local' for --cicustom to work.
  pvesm status -content snippets 2>/dev/null | awk 'NR>1' | grep -q . \
    || die "No storage has the 'Snippets' content type enabled.
Enable it: Datacenter > Storage > local > Edit > Content > check Snippets."
  mkdir -p /var/lib/vz/snippets
}

download_image() {
  # download_image <url> <dest>  - caches, resumes, verifies non-empty
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then
    info "Using cached image: $(basename "$dest")"
    return 0
  fi
  info "Downloading $(basename "$dest")..."
  curl -fL --progress-bar -C - -o "$dest" "$url" || { rm -f "$dest"; die "Download failed: $url"; }
  [[ -s "$dest" ]] || { rm -f "$dest"; die "Downloaded image is empty."; }
  msg "Image ready."
}

# Answers collected by the prompt functions (globals by design - each
# prompt_* fills its own, build_* reads them).
OS_CHOICE="" VMHOST="" CORES="" MEMORY="" DISK_SIZE="" STORAGE=""
CIUSER="" CIPASS="" SSHKEY="" DNS=""
declare -a NET_BRIDGE=() NET_IPCFG=()   # index 0 = NIC 1
declare -a CHOSEN_PKGS=()               # extra packages the user opted into


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ [2] PROMPTS                                                              ║
# ╚══════════════════════════════════════════════════════════════════════════╝

prompt_os() {
  OS_CHOICE=$(whiptail --title "OS Selection" --menu "Choose the guest OS:" 18 70 6 \
    "debian12"   "Debian 12 (Bookworm)" \
    "debian13"   "Debian 13 (Trixie)" \
    "ubuntu2204" "Ubuntu 22.04 LTS" \
    "ubuntu2404" "Ubuntu 24.04 LTS" \
    "rocky9"     "Rocky Linux 9" \
    3>&1 1>&2 2>&3) || die "Cancelled."
  [[ -n "${OS_URL[$OS_CHOICE]:-}" ]] || die "No image URL configured for '${OS_CHOICE}'."
}

prompt_vm_basics() {
  VMID=$(ask "VM ID" "VM ID:" "$(get_free_vmid)")
  validate_vmid "$VMID"
  VMHOST=$(ask    "Hostname"   "VM hostname:"          "vm-${VMID}")
  CORES=$(ask     "Processors" "CPU cores:"            "$DEF_CORES")
  MEMORY=$(ask    "Memory"     "Memory (MB):"          "$DEF_MEMORY")
  DISK_SIZE=$(ask "Hard Disk"  "Disk size (e.g. 20G):" "$DEF_DISK")
  STORAGE=$(select_storage images)
}

# prompt_one_nic <nic_number>
# Fills NET_BRIDGE[n-1] and NET_IPCFG[n-1]. Gateway is optional on EVERY nic;
# only the prompt's default answer differs (see GW_DEFAULT_* in CONFIG).
prompt_one_nic() {
  local n="$1" idx=$(( $1 - 1 ))
  local bridge ipcfg ip gw gw_default extra

  bridge=$(select_bridge "Network Interface ${n}")

  if confirm "NIC ${n}" "Use DHCP on NIC ${n}?\n(No = static)" defaultno; then
    ipcfg="ip=dhcp"
  else
    ip=$(ask "NIC ${n} - IP" "IP with CIDR (e.g. 10.0.10.50/24):"); validate_cidr "$ip"
    ipcfg="ip=${ip}"

    gw_default="$GW_DEFAULT_OTHER"
    [[ "$n" -eq 1 ]] && gw_default="$GW_DEFAULT_NIC1"
    extra=""; [[ "$gw_default" == "no" ]] && extra="defaultno"

    if confirm "NIC ${n} - Gateway" \
      "Set a gateway on NIC ${n}?\n(Skip for gateway-less networks, e.g. storage/backup VLANs.)" $extra; then
      gw=$(ask "NIC ${n} - Gateway" "Gateway:"); validate_ip "$gw"
      ipcfg="${ipcfg},gw=${gw}"
    fi
  fi

  NET_BRIDGE[$idx]="$bridge"
  NET_IPCFG[$idx]="$ipcfg"
}

prompt_network() {
  prompt_one_nic 1
  local n
  for (( n=2; n<=MAX_NICS; n++ )); do
    confirm "NIC ${n}" "Add network interface ${n}?" defaultno || break
    prompt_one_nic "$n"
  done
  DNS=$(ask "DNS" "DNS server(s), space separated:" "$DEF_DNS")
}

prompt_credentials() {
  CIUSER=$(ask        "SSH User"     "Admin username to create:" "$DEF_USER")
  CIPASS=$(ask_secret "SSH Password" "Password for ${CIUSER}:")
  if confirm "SSH Key" "Add an SSH public key for ${CIUSER}? (recommended)"; then
    SSHKEY=$(ask "SSH Public Key" "Paste public key:")
  fi
}

prompt_packages() {
  local entry text deb rhel
  for entry in "${OPTIONAL_PACKAGES[@]}"; do
    IFS='|' read -r text deb rhel <<< "$entry"
    if confirm "Optional Package" "$text" defaultno; then
      case "$OS_CHOICE" in
        rocky*|alma*|centos*) CHOSEN_PKGS+=("$rhel") ;;
        *)                    CHOSEN_PKGS+=("$deb")  ;;
      esac
    fi
  done
}

prompt_confirm_build() {
  local nic_lines="" i
  for i in "${!NET_BRIDGE[@]}"; do
    nic_lines+="NIC$((i+1)):     ${NET_BRIDGE[$i]} (${NET_IPCFG[$i]})
"
  done
  confirm "Confirm Build" "OS:       ${OS_CHOICE}
VMID:     ${VMID}   Host: ${VMHOST}
CPU/RAM:  ${CORES} cores / ${MEMORY} MB
Disk:     ${DISK_SIZE} on ${STORAGE}
${nic_lines}DNS:      ${DNS}
User:     ${CIUSER}
Extras:   ${CHOSEN_PKGS[*]:-none}

Proceed?" || die "Cancelled."
}


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ [3] BUILD                                                                ║
# ╚══════════════════════════════════════════════════════════════════════════╝

fetch_image() {
  IMG="${IMG_CACHE_DIR}/${OS_CHOICE}-cloud.qcow2"
  download_image "${OS_URL[$OS_CHOICE]}" "$IMG"
}

write_snippet() {
  local pkg pkg_lines=""
  for pkg in "${BASE_PACKAGES[@]}" "${CHOSEN_PKGS[@]}"; do
    pkg_lines+="  - ${pkg}
"
  done
  cat > "${SNIPPET_DIR}/vendor-${VMID}.yaml" <<EOF
#cloud-config
package_update: true
packages:
${pkg_lines}ssh_pwauth: true
runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now ssh || systemctl enable --now sshd
EOF
}

create_vm() {
  info "Creating VM ${VMID}..."
  qm create "$VMID" \
    --name "$VMHOST" --ostype "$VM_OSTYPE" \
    --machine "$VM_MACHINE" --bios "$VM_BIOS" \
    --cores "$CORES" --cpu "$VM_CPU" --memory "$MEMORY" \
    --scsihw "$VM_SCSIHW" --vga "$VM_VGA" \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --net0 "${NIC_MODEL},bridge=${NET_BRIDGE[0]}"
  VM_CREATED=1   # from here on, any failure triggers rollback

  local i
  for i in "${!NET_BRIDGE[@]}"; do
    [[ "$i" -eq 0 ]] && continue
    qm set "$VMID" --net${i} "${NIC_MODEL},bridge=${NET_BRIDGE[$i]}"
  done

  [[ "$VM_BIOS" == "ovmf" ]] && qm set "$VMID" --efidisk0 "${STORAGE}:0,${EFI_OPTS}"
}

attach_disk() {
  info "Importing disk..."
  qm importdisk "$VMID" "$IMG" "$STORAGE" >/dev/null
  local unused
  unused=$(qm config "$VMID" | awk -F': ' '/^unused0/ {print $2}')
  [[ -n "$unused" ]] || die "Disk import produced no unused0 entry."
  qm set "$VMID" --scsi0 "${unused},discard=on,ssd=1"
  qm set "$VMID" --boot order=scsi0
  qm resize "$VMID" scsi0 "$DISK_SIZE"
}

apply_cloudinit() {
  info "Applying cloud-init..."
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  local i
  for i in "${!NET_IPCFG[@]}"; do
    qm set "$VMID" --ipconfig${i} "${NET_IPCFG[$i]}"
  done
  qm set "$VMID" --nameserver "$DNS" --ciuser "$CIUSER" --cipassword "$CIPASS"
  if [[ -n "$SSHKEY" ]]; then
    local kf; kf=$(mktemp); echo "$SSHKEY" > "$kf"
    qm set "$VMID" --sshkeys "$kf"; rm -f "$kf"
  fi
  qm set "$VMID" --cicustom "vendor=${SNIPPET_STORE}/vendor-${VMID}.yaml"
}

finish() {
  clear_error_trap   # success - don't roll back on exit
  msg "VM ${VMID} (${VMHOST}) created."
  if confirm "Start VM" "Start VM ${VMID} now?"; then
    qm start "$VMID"
    msg "Started. First boot runs cloud-init - the guest agent needs a minute."
  else
    info "Start later:  qm start ${VMID}"
  fi
}


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ [4] MAIN                                                                 ║
# ╚══════════════════════════════════════════════════════════════════════════╝

main() {
  header_info "Cloud-Image VM Builder"
  set_error_trap
  init_pve
  ensure_snippets

  prompt_os
  prompt_vm_basics
  prompt_network
  prompt_credentials
  prompt_packages
  prompt_confirm_build

  fetch_image
  write_snippet
  create_vm
  attach_disk
  apply_cloudinit
  finish
}

main "$@"
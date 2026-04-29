#!/usr/bin/env bash
# =============================================================================
# STEP 00 — macOS: Deploy Lima VMs
# 3 VMs: mzcl01-cp (control plane), mzcl01-w1 (worker 1), mzcl01-w2 (worker 2)
# Run this ONLY on macOS host (Cray M5 Pro)
# Uses limactl CLI flags — no YAML manifest required
# =============================================================================

# When sourced, re-run as a subprocess so exit/set -e don't kill the terminal
(return 0 2>/dev/null) && { bash "${BASH_SOURCE[0]}" "$@"; return $?; }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOGDIR"
LOGDIR="$(cd "$LOGDIR" && pwd)"
LOGFILE="${LOGDIR}/00_macos_lima_vms_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOGFILE") 2>&1

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] [INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] [ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC}  $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] [FAIL]${NC}  $*"; exit 1; }
sep()  { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── VM sizing ─────────────────────────────────────────────────────────────
CP_NAME="mzcl01-cp";  CP_CPUS=2;  CP_MEM=4;  CP_DISK=20
W1_NAME="mzcl01-w1";  W1_CPUS=1;  W1_MEM=2;  W1_DISK=20
W2_NAME="mzcl01-w2";  W2_CPUS=1;  W2_MEM=2;  W2_DISK=20

# ── Preflight ─────────────────────────────────────────────────────────────
sep
log "STEP 00 — macOS Lima VM Deployment"
log "Logfile: $LOGFILE"
sep

log "Checking prerequisites..."

[[ "$(uname)" == "Darwin" ]] || err "This script must run on macOS. Detected: $(uname)"
ok "Running on macOS"

command -v brew &>/dev/null || err "Homebrew not found. Install from https://brew.sh"
ok "Homebrew available"

if ! command -v limactl &>/dev/null; then
  warn "lima not found — installing via brew..."
  brew install lima
fi
ok "limactl: $(limactl --version)"

if ! command -v jq &>/dev/null; then
  brew install jq
fi
ok "jq available"

# ── socket_vmnet — stable root-owned install ──────────────────────────────
# Lima requires the socket_vmnet binary AND every parent directory to be
# owned by root, with no symlinks anywhere in the path.
# Homebrew installs into /opt/homebrew/Cellar (user-owned) and uses symlinks
# in /opt/homebrew/opt — both violate Lima's security checks.
# Fix: copy the binary once to /opt/socket_vmnet/bin (fully root-owned, no
# symlinks) and point Lima's networks.yaml there. Survives brew upgrades.
SVMNET_DEST="/opt/socket_vmnet/bin/socket_vmnet"
log "Checking socket_vmnet stable install at ${SVMNET_DEST}..."

if ! brew list socket_vmnet &>/dev/null 2>&1; then
  warn "socket_vmnet not installed — installing via brew..."
  brew install socket_vmnet
fi

# Resolve the real binary (no symlinks) from the Cellar
SVMNET_SRC="$(brew --cellar socket_vmnet)/$(brew list --versions socket_vmnet \
  | awk '{print $2}')/bin/socket_vmnet"
[[ -f "$SVMNET_SRC" ]] || err "socket_vmnet source binary not found: $SVMNET_SRC"

NEEDS_COPY=false
if [[ ! -f "$SVMNET_DEST" ]]; then
  NEEDS_COPY=true
elif ! cmp -s "$SVMNET_SRC" "$SVMNET_DEST"; then
  warn "socket_vmnet binary has changed (brew upgrade?) — refreshing..."
  NEEDS_COPY=true
fi

if [[ "$NEEDS_COPY" == true ]]; then
  log "Installing socket_vmnet to ${SVMNET_DEST} (requires sudo)..."
  sudo mkdir -p "$(dirname "$SVMNET_DEST")"
  sudo cp "$SVMNET_SRC" "$SVMNET_DEST"
  sudo chown root:wheel "$(dirname "$SVMNET_DEST")" "$SVMNET_DEST"
  sudo chmod 755 "$(dirname "$SVMNET_DEST")"
  sudo chmod u+s "$SVMNET_DEST"   # setuid so Lima can exec it as root
  ok "socket_vmnet installed: ${SVMNET_DEST}"
else
  ok "socket_vmnet up to date at ${SVMNET_DEST}"
fi

# Point Lima's networks.yaml at the stable path (create if absent)
LIMA_NETWORKS_YAML="${HOME}/.lima/_config/networks.yaml"
mkdir -p "$(dirname "$LIMA_NETWORKS_YAML")"
if [[ ! -f "$LIMA_NETWORKS_YAML" ]] \
    || ! grep -q "$SVMNET_DEST" "$LIMA_NETWORKS_YAML" 2>/dev/null; then
  log "Updating Lima networks.yaml to use stable socket_vmnet path..."
  # Write a minimal networks.yaml that overrides just the socketVMNet path
  cat > "$LIMA_NETWORKS_YAML" << EOF
# Managed by 00_macos_lima_vms.sh
# socket_vmnet installed to a stable root-owned path outside Homebrew Cellar
paths:
  socketVMNet: "${SVMNET_DEST}"
  varRun: /private/var/run/lima
  sudoers: /private/etc/sudoers.d/lima
group: everyone
networks:
  shared:
    mode: shared
    gateway: 192.168.105.1
    dhcpEnd: 192.168.105.254
    netmask: 255.255.255.0
EOF
  ok "Lima networks.yaml updated: ${LIMA_NETWORKS_YAML}"
else
  ok "Lima networks.yaml already points to stable socket_vmnet"
fi

# ── Lima sudoers (allows Lima to call socket_vmnet without a password) ─────
if ! sudo grep -q "$SVMNET_DEST" /etc/sudoers.d/lima 2>/dev/null; then
  log "Configuring Lima sudoers (requires sudo)..."
  limactl sudoers | sudo tee /etc/sudoers.d/lima >/dev/null
  ok "Lima sudoers configured: /etc/sudoers.d/lima"
else
  ok "Lima sudoers already configured"
fi

# ── Helper: launch one VM via CLI flags only ──────────────────────────────
launch_vm() {
  local name="$1" cpus="$2" mem="$3" disk="$4"

  sep
  log "Processing VM: ${name}"
  log "  CPUs: ${cpus} | Memory: ${mem}GiB | Disk: ${disk}GiB"

  # Skip if already exists
  if limactl list --format json 2>/dev/null \
      | jq -e ".[] | select(.name == \"${name}\")" &>/dev/null; then
    local status
    status=$(limactl list --format json \
      | jq -r ".[] | select(.name == \"${name}\") | .status")
    warn "VM '${name}' already exists (status: ${status})"
    if [[ "$status" == "Running" ]]; then
      ok "VM '${name}' already running — skipping"
      return 0
    else
      warn "VM '${name}' stopped — starting..."
      limactl start "${name}" && ok "VM '${name}' started" || err "Failed to start '${name}'"
      return 0
    fi
  fi

  log "Launching VM '${name}' — first run downloads Ubuntu image, allow 5-10 min..."

  # vz = Apple Virtualization.framework (stable networking on Apple Silicon)
  limactl start \
    --name="${name}" \
    --vm-type=vz \
    --arch=aarch64 \
    --cpus="${cpus}" \
    --memory="${mem}" \
    --disk="${disk}" \
    --network=lima:shared \
    --containerd=none \
    -y \
    template:ubuntu-24.04

  ok "VM '${name}' started"

  # Post-launch provisioning — k8s prerequisites
  log "Provisioning k8s prerequisites on '${name}'..."
  limactl shell "${name}" -- sudo bash -c \
    'apt-get update -qq \
     && apt-get install -y -qq curl wget jq git vim htop net-tools \
     && swapoff -a \
     && sed -i "/swap/d" /etc/fstab \
     && modprobe overlay \
     && modprobe br_netfilter \
     && printf "overlay\nbr_netfilter\n" > /etc/modules-load.d/k8s.conf \
     && printf "net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n" \
          > /etc/sysctl.d/99-k8s.conf \
     && sysctl --system'

  ok "Provisioning complete on '${name}'"
}

# ── Launch all three VMs ──────────────────────────────────────────────────
launch_vm "$CP_NAME" "$CP_CPUS" "$CP_MEM" "$CP_DISK"
launch_vm "$W1_NAME" "$W1_CPUS" "$W1_MEM" "$W1_DISK"
launch_vm "$W2_NAME" "$W2_CPUS" "$W2_MEM" "$W2_DISK"

# ── Collect and save VM IPs ───────────────────────────────────────────────
sep
log "Collecting VM network info..."
echo ""
printf "%-15s %-12s %-22s %s\n" "VM NAME"        "STATUS"       "IP ADDRESS"             "ROLE"
printf "%-15s %-12s %-22s %s\n" "───────────────" "────────────" "──────────────────────" "──────────────"

# Bash 3.2 (macOS default) has no associative arrays — use a function instead
vm_role() {
  case "$1" in
    "$CP_NAME") echo "control-plane" ;;
    *)          echo "worker" ;;
  esac
}

IP_FILE="$(dirname "$LOGDIR")/vm_ips.env"
printf '# Generated by 00_macos_lima_vms.sh — %s\n' "$(date)" > "$IP_FILE"

for VM in "$CP_NAME" "$W1_NAME" "$W2_NAME"; do
  STATUS=$(limactl list --format json 2>/dev/null \
    | jq -r ".[] | select(.name == \"${VM}\") | .status" || echo "unknown")

  # Detect IP: use routing table to find the src address for external traffic
  # Works regardless of interface name (enp0s1, eth0, lima0, etc.)
  IP=$(limactl shell "${VM}" -- \
    bash -c 'ip -4 route get 1.1.1.1 2>/dev/null | grep -oP "src \K[0-9.]+" | head -1 \
             || ip -4 addr show scope global 2>/dev/null | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | grep -v "255$" | head -1 \
             || echo pending' 2>/dev/null || echo "pending")

  printf "%-15s %-12s %-22s %s\n" "$VM" "$STATUS" "$IP" "$(vm_role "$VM")"

  VARNAME="IP_${VM//-/_}"
  printf '%s=%s\n' "$VARNAME" "$IP" >> "$IP_FILE"
  log "  ${VARNAME}=${IP}"
done

echo ""
ok "IPs saved to: ${IP_FILE}"

sep
ok "STEP 00 COMPLETE — Lima VMs deployed"
log "Next step → run: 01_windows_multipass_vms.ps1 on Windows laptop"
log "Then        run: 02_k8s_control_plane.sh"
sep

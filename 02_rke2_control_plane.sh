#!/usr/bin/env bash
# =============================================================================
# STEP 02 — macOS host: Install RKE2 Server on Lima mzcl01-cp VM
# Installs and configures the RKE2 control plane inside the Lima VM.
# Run on macOS host — commands are proxied into the Lima VM via limactl shell.
# =============================================================================

# When sourced, re-run as a subprocess so exit/set -e don't kill the terminal
(return 0 2>/dev/null) && { bash "${BASH_SOURCE[0]}" "$@"; return $?; }

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOGDIR"
LOGDIR="$(cd "$LOGDIR" && pwd)"
LOGFILE="${LOGDIR}/02_rke2_control_plane_$(date +%Y%m%d_%H%M%S).log"
IPENV="$(dirname "$LOGDIR")/vm_ips.env"

exec > >(tee -a "$LOGFILE") 2>&1

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] [INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] [ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC}  $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] [FAIL]${NC}  $*"; exit 1; }
sep()  { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# Helper — run command inside mzcl01-cp Lima VM as root
lshell() { limactl shell mzcl01-cp -- sudo bash -c "$*"; }
lshell_user() { limactl shell mzcl01-cp -- bash -c "$*"; }

sep
log "STEP 02 — RKE2 Control Plane Installation"
log "Target VM: mzcl01-cp (Lima)"
log "Logfile: $LOGFILE"
sep

# ── Load IPs ───────────────────────────────────────────────────────────────
if [[ ! -f "$IPENV" ]]; then
  err "VM IPs file not found: $IPENV — run step 00 first"
fi
# shellcheck disable=SC1090
source "$IPENV"
CP_IP="${IP_mzcl01_cp:?IP_mzcl01_cp not set in $IPENV}"
log "Control plane VM IP: $CP_IP"

# ── Preflight ──────────────────────────────────────────────────────────────
log "Checking Lima VM 'mzcl01-cp' is running..."
STATUS=$(limactl list --format json | jq -r '.[] | select(.name=="mzcl01-cp") | .status')
[[ "$STATUS" == "Running" ]] || err "VM mzcl01-cp is not running (status: $STATUS) — run step 00 first"
ok "VM mzcl01-cp is running"

log "Checking VM connectivity..."
lshell_user "echo 'SSH OK'" | grep -q "SSH OK" || err "Cannot SSH into mzcl01-cp"
ok "VM connectivity confirmed"

# ── System prep inside VM ──────────────────────────────────────────────────
sep
log "Preparing VM system..."

lshell "swapoff -a && sed -i '/swap/d' /etc/fstab"
ok "Swap disabled"

lshell "modprobe overlay && modprobe br_netfilter"
lshell "cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF"
ok "Kernel modules loaded"

lshell "cat > /etc/sysctl.d/99-k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system"
ok "Sysctl applied"

# ── Install RKE2 ──────────────────────────────────────────────────────────
sep
log "Installing RKE2 server (latest stable)..."

lshell "curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=server sh -"
ok "RKE2 server binary installed"

# ── Write RKE2 config ─────────────────────────────────────────────────────
sep
log "Writing RKE2 server config..."

lshell "mkdir -p /etc/rancher/rke2"
lshell "cat > /etc/rancher/rke2/config.yaml << EOF
# RKE2 Control Plane Configuration
write-kubeconfig-mode: '0644'

tls-san:
  - ${CP_IP}
  - mzcl01-cp.local
  - localhost
  - 127.0.0.1

node-ip: ${CP_IP}
node-name: mzcl01-cp

# CNI — Flannel (simplest for local LAN cluster)
cni: flannel

# Cluster CIDR
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16

# Disable unused components
disable:
  - rke2-ingress-nginx

# Kubelet args for laptop resilience
kubelet-arg:
  - 'node-status-update-frequency=10s'
  - 'eviction-hard=memory.available<200Mi'
EOF"
ok "RKE2 config written to /etc/rancher/rke2/config.yaml"

# ── Start RKE2 ────────────────────────────────────────────────────────────
sep
log "Enabling and starting RKE2 server service..."

lshell "systemctl enable rke2-server.service"
lshell "systemctl start rke2-server.service"
ok "RKE2 server service started"

# ── Wait for RKE2 to become ready ─────────────────────────────────────────
sep
log "Waiting for RKE2 API server to become ready (up to 5 minutes)..."

TIMEOUT=300
ELAPSED=0
INTERVAL=10
until lshell "KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl get nodes 2>/dev/null | grep -q mzcl01-cp" 2>/dev/null; do
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
  log "  Waiting... ${ELAPSED}s / ${TIMEOUT}s"
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    lshell "systemctl status rke2-server.service --no-pager" || true
    err "RKE2 did not become ready within ${TIMEOUT}s"
  fi
done
ok "RKE2 API server is ready"

# ── Retrieve join token ───────────────────────────────────────────────────
sep
log "Retrieving node join token..."

JOIN_TOKEN=$(lshell "cat /var/lib/rancher/rke2/server/node-token")
[[ -n "$JOIN_TOKEN" ]] || err "Failed to retrieve join token"
ok "Join token retrieved"

# Save token for subsequent steps
TOKEN_FILE="$(dirname "$LOGDIR")/rke2_join_token.env"
cat > "$TOKEN_FILE" << EOF
# Generated by 02_rke2_control_plane.sh — $(date)
RKE2_JOIN_TOKEN=${JOIN_TOKEN}
RKE2_SERVER_URL=https://${CP_IP}:9345
RKE2_API_URL=https://${CP_IP}:6443
EOF
ok "Join token saved to: $TOKEN_FILE"

# ── Set up kubectl on macOS host ──────────────────────────────────────────
sep
log "Copying kubeconfig to macOS host..."

KUBECONFIG_DIR="$HOME/.kube"
mkdir -p "$KUBECONFIG_DIR"

limactl shell mzcl01-cp -- sudo cat /etc/rancher/rke2/rke2.yaml \
  | sed "s/127.0.0.1/${CP_IP}/g" \
  | sed "s/default/rke2-local/g" \
  > "${KUBECONFIG_DIR}/rke2-local.yaml"

ok "Kubeconfig saved to: ${KUBECONFIG_DIR}/rke2-local.yaml"

log "Adding rke2-local context to KUBECONFIG..."
if ! grep -q "rke2-local" "${KUBECONFIG_DIR}/config" 2>/dev/null; then
  KUBECONFIG="${KUBECONFIG_DIR}/config:${KUBECONFIG_DIR}/rke2-local.yaml" \
    kubectl config view --flatten > /tmp/merged-kubeconfig
  mv /tmp/merged-kubeconfig "${KUBECONFIG_DIR}/config"
  ok "Kubeconfig merged"
else
  warn "rke2-local context already exists in kubeconfig — skipping merge"
fi

# ── Verify from macOS host ────────────────────────────────────────────────
sep
log "Verifying cluster from macOS host..."
KUBECONFIG="${KUBECONFIG_DIR}/rke2-local.yaml" kubectl get nodes -o wide
ok "Cluster visible from macOS host"

# ── Node status ───────────────────────────────────────────────────────────
sep
log "Node status:"
lshell "KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl get nodes -o wide"

log "System pods status:"
lshell "KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl get pods -n kube-system"

sep
ok "STEP 02 COMPLETE — RKE2 control plane is running"
log ""
log "Join token saved to: $TOKEN_FILE"
log "Kubeconfig saved to: ${KUBECONFIG_DIR}/rke2-local.yaml"
log ""
log "Next step → run: 03_rke2_workers_lima.sh  (Lima worker VMs)"
log "            run: 04_rke2_workers_multipass.sh  (Windows Multipass workers)"
sep

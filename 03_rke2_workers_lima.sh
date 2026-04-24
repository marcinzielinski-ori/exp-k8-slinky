#!/usr/bin/env bash
# =============================================================================
# STEP 03 — macOS host: Install RKE2 Agent on Lima worker VMs (mzcl01-w1, mzcl01-w2)
# Run on macOS host after step 02 completes.
# =============================================================================

# When sourced, re-run as a subprocess so exit/set -e don't kill the terminal
(return 0 2>/dev/null) && { bash "${BASH_SOURCE[0]}" "$@"; return $?; }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOGDIR"
LOGDIR="$(cd "$LOGDIR" && pwd)"
LOGFILE="${LOGDIR}/03_rke2_workers_lima_$(date +%Y%m%d_%H%M%S).log"
IPENV="$(dirname "$LOGDIR")/vm_ips.env"
TOKENENV="$(dirname "$LOGDIR")/rke2_join_token.env"

exec > >(tee -a "$LOGFILE") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] [INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] [ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC}  $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] [FAIL]${NC}  $*"; exit 1; }
sep()  { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# Run command inside a Lima VM as root
lshell() { local vm="$1"; shift; limactl shell "$vm" -- sudo bash -c "$*"; }

WORKERS=(mzcl01-w1 mzcl01-w2)

sep
log "STEP 03 — RKE2 Agent Installation on Lima Worker VMs"
log "Target VMs: ${WORKERS[*]}"
log "Logfile: $LOGFILE"
sep

# ── Load IPs and token ────────────────────────────────────────────────────
[[ -f "$IPENV" ]]    || err "VM IPs file not found: $IPENV — run step 00 first"
[[ -f "$TOKENENV" ]] || err "Join token file not found: $TOKENENV — run step 02 first"
# shellcheck disable=SC1090
source "$IPENV"
source "$TOKENENV"

[[ -n "${RKE2_JOIN_TOKEN:-}" ]]  || err "RKE2_JOIN_TOKEN not set in $TOKENENV"
[[ -n "${RKE2_SERVER_URL:-}" ]]  || err "RKE2_SERVER_URL not set in $TOKENENV"

log "Server URL:   $RKE2_SERVER_URL"
log "Join token:   ${RKE2_JOIN_TOKEN:0:20}...[redacted]"

# ── Process each worker VM ────────────────────────────────────────────────
for VM in "${WORKERS[@]}"; do
  sep
  log "Processing worker VM: $VM"

  # Get IP var name dynamically
  IP_VAR="IP_${VM//-/_}"
  VM_IP="${!IP_VAR:?IP for $VM not set in $IPENV}"
  log "Worker IP: $VM_IP"

  # Check VM is running
  STATUS=$(limactl list --format json | jq -r ".[] | select(.name==\"${VM}\") | .status")
  [[ "$STATUS" == "Running" ]] || err "VM $VM is not running (status: $STATUS)"
  ok "VM $VM is running"

  # ── System prep ────────────────────────────────────────────────────────
  log "Preparing system on $VM..."

  lshell "$VM" "swapoff -a && sed -i '/swap/d' /etc/fstab"
  ok "Swap disabled"

  lshell "$VM" "modprobe overlay && modprobe br_netfilter"
  lshell "$VM" "cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF"

  lshell "$VM" "cat > /etc/sysctl.d/99-k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system"
  ok "Kernel modules and sysctl applied"

  # ── Install RKE2 agent ─────────────────────────────────────────────────
  log "Installing RKE2 agent on $VM..."
  lshell "$VM" "curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=agent sh -"
  ok "RKE2 agent binary installed"

  # ── Write agent config ─────────────────────────────────────────────────
  log "Writing RKE2 agent config on $VM..."
  lshell "$VM" "mkdir -p /etc/rancher/rke2"
  lshell "$VM" "cat > /etc/rancher/rke2/config.yaml << EOF
# RKE2 Agent Configuration — ${VM}
server: ${RKE2_SERVER_URL}
token: ${RKE2_JOIN_TOKEN}

node-ip: ${VM_IP}
node-name: ${VM}

kubelet-arg:
  - 'node-status-update-frequency=10s'
EOF"
  ok "Agent config written"

  # ── Start agent ────────────────────────────────────────────────────────
  log "Enabling and starting RKE2 agent service on $VM..."
  lshell "$VM" "systemctl enable rke2-agent.service"
  lshell "$VM" "systemctl start rke2-agent.service"
  ok "RKE2 agent service started"

  # ── Wait for node to join ──────────────────────────────────────────────
  log "Waiting for $VM to appear in cluster (up to 3 minutes)..."
  TIMEOUT=180; ELAPSED=0; INTERVAL=10
  KUBECONFIG_PATH="$HOME/.kube/rke2-local.yaml"

  until KUBECONFIG="$KUBECONFIG_PATH" kubectl get node "$VM" &>/dev/null 2>&1; do
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    log "  Waiting for node $VM... ${ELAPSED}s / ${TIMEOUT}s"
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      log "  Agent service status:"
      lshell "$VM" "systemctl status rke2-agent.service --no-pager" || true
      err "Node $VM did not join cluster within ${TIMEOUT}s"
    fi
  done
  ok "Node $VM joined the cluster"

  # Wait for Ready
  log "Waiting for $VM to reach Ready state..."
  ELAPSED=0
  until KUBECONFIG="$KUBECONFIG_PATH" kubectl get node "$VM" \
    | grep -q " Ready"; do
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      warn "Node $VM not Ready within timeout — may still be initializing"
      break
    fi
  done
  ok "Node $VM is Ready"
done

# ── Final cluster status ──────────────────────────────────────────────────
sep
log "Current cluster node status:"
KUBECONFIG="$HOME/.kube/rke2-local.yaml" kubectl get nodes -o wide

sep
ok "STEP 03 COMPLETE — Lima worker VMs joined the cluster"
log "Next step → run on Windows: 04_rke2_workers_multipass.ps1"
log "            then on macOS:  05_rancher_install.sh"
sep

#!/usr/bin/env bash
# =============================================================================
# STEP 03 — macOS host: Join Lima worker VMs to Kubernetes cluster (kubeadm)
# Installs containerd + kubeadm on mzcl01-w1 and mzcl01-w2, then runs join.
# Run on macOS host after step 02 completes.
# =============================================================================

# When sourced, re-run as a subprocess so exit/set -e don't kill the terminal
(return 0 2>/dev/null) && { bash "${BASH_SOURCE[0]}" "$@"; return $?; }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOGDIR"
LOGDIR="$(cd "$LOGDIR" && pwd)"
LOGFILE="${LOGDIR}/03_k8s_workers_lima_$(date +%Y%m%d_%H%M%S).log"
IPENV="$(dirname "$LOGDIR")/vm_ips.env"
TOKENENV="$(dirname "$LOGDIR")/k8s_join_token.env"

exec > >(tee -a "$LOGFILE") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] [INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] [ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC}  $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] [FAIL]${NC}  $*"; exit 1; }
sep()  { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

lshell() { local vm="$1"; shift; limactl shell "$vm" -- sudo bash -c "$*"; }

K8S_MINOR="1.34"
WORKERS=(mzcl01-w1 mzcl01-w2)

sep
log "STEP 03 — Kubernetes Worker Nodes (kubeadm join)"
log "Target VMs: ${WORKERS[*]}"
log "Logfile: $LOGFILE"
sep

# ── Load IPs and join command ──────────────────────────────────────────────
[[ -f "$IPENV" ]]    || err "VM IPs file not found: $IPENV — run step 00 first"
[[ -f "$TOKENENV" ]] || err "Join token file not found: $TOKENENV — run step 02 first"
# shellcheck disable=SC1090
source "$IPENV"
source "$TOKENENV"

[[ -n "${K8S_JOIN_COMMAND:-}" ]] || err "K8S_JOIN_COMMAND not set in $TOKENENV"
[[ -n "${K8S_CP_IP:-}" ]]        || err "K8S_CP_IP not set in $TOKENENV"

log "Control plane: $K8S_CP_IP:6443"

# ── Process each worker VM ────────────────────────────────────────────────
for VM in "${WORKERS[@]}"; do
  sep
  log "Processing worker VM: $VM"

  IP_VAR="IP_${VM//-/_}"
  VM_IP="${!IP_VAR:?IP for $VM not set in $IPENV}"
  log "Worker IP: $VM_IP"

  STATUS=$(limactl list --format json | jq -r ".[] | select(.name==\"${VM}\") | .status")
  [[ "$STATUS" == "Running" ]] || err "VM $VM is not running (status: $STATUS)"
  ok "VM $VM is running"

  # ── System prep ────────────────────────────────────────────────────────
  log "System prep on $VM..."
  lshell "$VM" "swapoff -a && sed -i '/swap/d' /etc/fstab"
  lshell "$VM" "modprobe overlay && modprobe br_netfilter"
  lshell "$VM" "printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf"
  lshell "$VM" "printf 'net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-k8s.conf && sysctl --system"
  ok "System prep complete"

  # ── Install containerd ──────────────────────────────────────────────────
  log "Installing containerd on $VM..."
  lshell "$VM" "apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg"
  lshell "$VM" "mkdir -p /etc/apt/keyrings"
  lshell "$VM" "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  lshell "$VM" "echo 'deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list"
  lshell "$VM" "apt-get update -qq && apt-get install -y -qq containerd.io"
  lshell "$VM" "containerd config default > /etc/containerd/config.toml && sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml"
  lshell "$VM" "systemctl enable containerd && systemctl restart containerd"
  ok "containerd installed on $VM"

  # ── Install kubelet + kubeadm ───────────────────────────────────────────
  log "Installing kubelet, kubeadm (v${K8S_MINOR}) on $VM..."
  lshell "$VM" "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
  lshell "$VM" "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list"
  lshell "$VM" "apt-get update -qq && apt-get install -y -qq kubelet kubeadm"
  lshell "$VM" "apt-mark hold kubelet kubeadm && systemctl enable kubelet"
  ok "Kubernetes packages installed on $VM"

  # ── kubeadm join ───────────────────────────────────────────────────────
  if lshell "$VM" "test -f /etc/kubernetes/kubelet.conf" 2>/dev/null; then
    warn "$VM already joined cluster — skipping join"
  else
    log "Running kubeadm join on $VM..."
    lshell "$VM" "$K8S_JOIN_COMMAND"
    ok "kubeadm join complete on $VM"
  fi

  # ── Wait for Ready ─────────────────────────────────────────────────────
  log "Waiting for $VM to be Ready (up to 3 min)..."
  TIMEOUT=180; ELAPSED=0; INTERVAL=10
  until KUBECONFIG="$HOME/.kube/k8s-local.yaml" kubectl get node "$VM" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
    | grep -q "True"; do
    sleep $INTERVAL; ELAPSED=$((ELAPSED + INTERVAL))
    log "  Waiting for $VM... ${ELAPSED}s / ${TIMEOUT}s"
    [[ $ELAPSED -ge $TIMEOUT ]] && { warn "Timeout waiting for $VM"; break; }
  done
  ok "Node $VM is Ready"
done

# ── Final cluster status ──────────────────────────────────────────────────
sep
log "Current cluster node status:"
KUBECONFIG="$HOME/.kube/k8s-local.yaml" kubectl get nodes -o wide

sep
ok "STEP 03 COMPLETE — Lima worker VMs joined the cluster"
log "Next step → run on Windows: 04_k8s_workers_multipass.ps1"
log "            then on macOS:  05_ingress_nginx.sh"
sep

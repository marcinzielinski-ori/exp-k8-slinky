#!/usr/bin/env bash
# =============================================================================
# STEP 02 — macOS host: Bootstrap Kubernetes control plane on Lima mzcl01-cp
# Installs containerd + kubeadm and runs kubeadm init inside the Lima VM.
# Run on macOS host — commands are proxied into the Lima VM via limactl shell.
# =============================================================================

# When sourced, re-run as a subprocess so exit/set -e don't kill the terminal
(return 0 2>/dev/null) && { bash "${BASH_SOURCE[0]}" "$@"; return $?; }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOGDIR"
LOGDIR="$(cd "$LOGDIR" && pwd)"
LOGFILE="${LOGDIR}/02_k8s_control_plane_$(date +%Y%m%d_%H%M%S).log"
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

K8S_MINOR="1.34"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

sep
log "STEP 02 — Kubernetes Control Plane (kubeadm)"
log "Target VM: mzcl01-cp (Lima)"
log "Kubernetes: v${K8S_MINOR}.x  CNI: Flannel  Pod CIDR: ${POD_CIDR}"
log "Logfile: $LOGFILE"
sep

# ── Load IPs ───────────────────────────────────────────────────────────────
[[ -f "$IPENV" ]] || err "VM IPs file not found: $IPENV — run step 00 first"
# shellcheck disable=SC1090
source "$IPENV"
CP_IP="${IP_mzcl01_cp:?IP_mzcl01_cp not set in $IPENV}"
log "Control plane VM IP: $CP_IP"

# ── Preflight ──────────────────────────────────────────────────────────────
STATUS=$(limactl list --format json | jq -r '.[] | select(.name=="mzcl01-cp") | .status')
[[ "$STATUS" == "Running" ]] || err "VM mzcl01-cp is not running (status: $STATUS)"
ok "VM mzcl01-cp is running"

# ── System prep ────────────────────────────────────────────────────────────
sep
log "System prep..."
lshell "swapoff -a && sed -i '/swap/d' /etc/fstab"
lshell "modprobe overlay && modprobe br_netfilter"
lshell "printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf"
lshell "printf 'net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-k8s.conf && sysctl --system"
ok "System prep complete"

# ── Install containerd ────────────────────────────────────────────────────
sep
log "Installing containerd..."
lshell "apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg"
lshell "mkdir -p /etc/apt/keyrings"
lshell "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
lshell "echo 'deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list"
lshell "apt-get update -qq && apt-get install -y -qq containerd.io"
lshell "containerd config default > /etc/containerd/config.toml && sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml"
lshell "systemctl enable containerd && systemctl restart containerd"
ok "containerd installed and configured"

# ── Install kubeadm, kubelet, kubectl ─────────────────────────────────────
sep
log "Installing kubeadm, kubelet, kubectl (v${K8S_MINOR})..."
lshell "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
lshell "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list"
lshell "apt-get update -qq && apt-get install -y -qq kubelet kubeadm kubectl"
lshell "apt-mark hold kubelet kubeadm kubectl"
lshell "systemctl enable kubelet"
ok "Kubernetes packages installed"

# ── kubeadm init ─────────────────────────────────────────────────────────
sep
log "Running kubeadm init (pod-cidr: ${POD_CIDR})..."
if lshell "test -f /etc/kubernetes/admin.conf" 2>/dev/null; then
  warn "Cluster already initialised — skipping kubeadm init"
else
  lshell "kubeadm init \
    --apiserver-advertise-address=${CP_IP} \
    --pod-network-cidr=${POD_CIDR} \
    --service-cidr=${SERVICE_CIDR} \
    --node-name=mzcl01-cp"
  lshell "mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config"
fi
ok "Control plane initialised"

# ── Install Flannel CNI ───────────────────────────────────────────────────
sep
log "Installing Flannel CNI..."
lshell "kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f \
  https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
ok "Flannel CNI applied"

# ── Wait for node Ready ───────────────────────────────────────────────────
sep
log "Waiting for control-plane node to be Ready (up to 5 min)..."
TIMEOUT=300; ELAPSED=0; INTERVAL=10
until lshell "kubectl --kubeconfig /etc/kubernetes/admin.conf get node mzcl01-cp \
  -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null" \
  | grep -q "True"; do
  sleep $INTERVAL; ELAPSED=$((ELAPSED + INTERVAL))
  log "  Waiting... ${ELAPSED}s / ${TIMEOUT}s"
  [[ $ELAPSED -ge $TIMEOUT ]] && err "Control plane not Ready within ${TIMEOUT}s"
done
ok "Control plane node is Ready"

# ── Save join command ─────────────────────────────────────────────────────
sep
log "Generating worker join command..."
JOIN_CMD=$(lshell "kubeadm token create --print-join-command")
[[ -n "$JOIN_CMD" ]] || err "Failed to generate join command"

TOKEN_FILE="$(dirname "$LOGDIR")/k8s_join_token.env"
cat > "$TOKEN_FILE" << EOF
# Generated by 02_k8s_control_plane.sh — $(date)
K8S_JOIN_COMMAND="${JOIN_CMD}"
K8S_CP_IP=${CP_IP}
K8S_API_URL=https://${CP_IP}:6443
EOF
ok "Join command saved to: $TOKEN_FILE"

# ── Export kubeconfig to macOS ────────────────────────────────────────────
sep
log "Copying kubeconfig to macOS host..."
mkdir -p "$HOME/.kube"
limactl shell mzcl01-cp -- sudo cat /etc/kubernetes/admin.conf \
  | sed "s|server: https://127.0.0.1:6443|server: https://${CP_IP}:6443|g" \
  > "$HOME/.kube/k8s-local.yaml"
chmod 600 "$HOME/.kube/k8s-local.yaml"
ok "Kubeconfig saved to: $HOME/.kube/k8s-local.yaml"

# ── Verify ────────────────────────────────────────────────────────────────
sep
log "Verifying cluster from macOS host..."
KUBECONFIG="$HOME/.kube/k8s-local.yaml" kubectl get nodes -o wide
ok "Cluster visible from macOS host"

sep
ok "STEP 02 COMPLETE — Kubernetes control plane is running"
log ""
log "Join command saved to: $TOKEN_FILE"
log "Kubeconfig:            ~/.kube/k8s-local.yaml"
log ""
log "Next step → run: 03_k8s_workers_lima.sh  (Lima worker VMs)"
log "            run: 04_k8s_workers_multipass.ps1  (Windows Multipass workers)"
sep

#!/usr/bin/env bash
# =============================================================================
# STEP 05 — macOS host: Install cert-manager and ingress-nginx via Helm
# Run on macOS host after steps 02-04 complete and all nodes are Ready.
# =============================================================================

# When sourced, re-run as a subprocess so exit/set -e don't kill the terminal
(return 0 2>/dev/null) && { bash "${BASH_SOURCE[0]}" "$@"; return $?; }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOGDIR"
LOGDIR="$(cd "$LOGDIR" && pwd)"
LOGFILE="${LOGDIR}/05_ingress_nginx_$(date +%Y%m%d_%H%M%S).log"
IPENV="$(dirname "$LOGDIR")/vm_ips.env"
KUBECONFIG_PATH="$HOME/.kube/k8s-local.yaml"

exec > >(tee -a "$LOGFILE") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] [INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] [ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC}  $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] [FAIL]${NC}  $*"; exit 1; }
sep()  { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

kube()     { KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"; }
helm_cmd() { KUBECONFIG="$KUBECONFIG_PATH" helm "$@"; }

CERT_MANAGER_VERSION="v1.14.4"

sep
log "STEP 05 — cert-manager + ingress-nginx"
log "Logfile: $LOGFILE"
sep

# ── Load IPs ──────────────────────────────────────────────────────────────
[[ -f "$IPENV" ]] || err "VM IPs file not found: $IPENV"
# shellcheck disable=SC1090
source "$IPENV"
CP_IP="${IP_mzcl01_cp:?IP_mzcl01_cp not set}"

# ── Preflight ─────────────────────────────────────────────────────────────
[[ -f "$KUBECONFIG_PATH" ]] || err "Kubeconfig not found at $KUBECONFIG_PATH — run step 02 first"
for tool in kubectl helm; do
  command -v "$tool" &>/dev/null || { warn "$tool not found — installing via brew..."; brew install "$tool"; }
  ok "$tool: $(command -v "$tool")"
done
kube cluster-info || err "Cannot connect to cluster — check kubeconfig"
ok "Cluster reachable"

kube get nodes -o wide
NOT_READY=$(kube get nodes --no-headers | grep -v " Ready" | wc -l | tr -d ' ')
[[ "$NOT_READY" -gt 0 ]] && warn "$NOT_READY node(s) not yet Ready"

# ── cert-manager ──────────────────────────────────────────────────────────
sep
log "Installing cert-manager ${CERT_MANAGER_VERSION}..."
helm_cmd repo add jetstack https://charts.jetstack.io --force-update
helm_cmd repo update

if helm_cmd list -n cert-manager | grep -q cert-manager; then
  warn "cert-manager already installed — skipping"
else
  helm_cmd install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set installCRDs=true \
    --wait --timeout 5m
  ok "cert-manager installed"
fi

kube rollout status deployment/cert-manager -n cert-manager --timeout=3m
kube rollout status deployment/cert-manager-webhook -n cert-manager --timeout=3m
kube rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=3m
ok "cert-manager pods ready"

# ── ingress-nginx ─────────────────────────────────────────────────────────
sep
log "Installing ingress-nginx (hostNetwork on mzcl01-cp)..."
helm_cmd repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm_cmd repo update

if helm_cmd list -n ingress-nginx | grep -q ingress-nginx; then
  warn "ingress-nginx already installed — skipping"
else
  helm_cmd install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.hostNetwork=true \
    --set controller.hostPort.enabled=true \
    --set controller.service.type=ClusterIP \
    --set "controller.nodeSelector.kubernetes\.io/hostname"=mzcl01-cp \
    --set controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
    --set controller.tolerations[0].operator=Exists \
    --set controller.tolerations[0].effect=NoSchedule \
    --wait --timeout 5m
  ok "ingress-nginx installed"
fi

kube rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=3m
ok "ingress-nginx controller ready"

log "ingress-nginx pods:"
kube get pods -n ingress-nginx -o wide

sep
ok "STEP 05 COMPLETE — cert-manager + ingress-nginx running"
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           INGRESS ACCESS                                ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  HTTP/HTTPS port:  ${CP_IP}  (hostNetwork on CP)         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Add to /etc/hosts: ${CP_IP}  <your-hostname>         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Kubeconfig:  ~/.kube/k8s-local.yaml                    ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
log "Next step → run: 06_verify_cluster.sh"
sep

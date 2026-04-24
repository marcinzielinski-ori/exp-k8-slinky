#!/usr/bin/env bash
# =============================================================================
# STEP 05 — macOS host: Install Rancher UI via Helm
# Installs cert-manager and Rancher on the RKE2 cluster.
# Run on macOS host after steps 02-04 complete and all nodes are Ready.
# =============================================================================

# When sourced, re-run as a subprocess so exit/set -e don't kill the terminal
(return 0 2>/dev/null) && { bash "${BASH_SOURCE[0]}" "$@"; return $?; }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOGDIR"
LOGDIR="$(cd "$LOGDIR" && pwd)"
LOGFILE="${LOGDIR}/05_rancher_install_$(date +%Y%m%d_%H%M%S).log"
IPENV="$(dirname "$LOGDIR")/vm_ips.env"
KUBECONFIG_PATH="$HOME/.kube/rke2-local.yaml"

exec > >(tee -a "$LOGFILE") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] [INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] [ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC}  $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] [FAIL]${NC}  $*"; exit 1; }
sep()  { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# kubectl shortcut
kube() { KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"; }
helm_cmd() { KUBECONFIG="$KUBECONFIG_PATH" helm "$@"; }

# ── Versions ──────────────────────────────────────────────────────────────
CERT_MANAGER_VERSION="v1.14.4"
RANCHER_NAMESPACE="cattle-system"
RANCHER_HOSTNAME="rancher.local"
RANCHER_BOOTSTRAP_PW="admin"          # change after first login

sep
log "STEP 05 — Rancher UI Installation"
log "Logfile: $LOGFILE"
sep

# ── Load IPs ──────────────────────────────────────────────────────────────
[[ -f "$IPENV" ]] || err "VM IPs file not found: $IPENV"
# shellcheck disable=SC1090
source "$IPENV"
CP_IP="${IP_mzcl01_cp:?IP_mzcl01_cp not set}"

# ── Preflight checks ──────────────────────────────────────────────────────
log "Checking prerequisites..."

[[ -f "$KUBECONFIG_PATH" ]] || err "Kubeconfig not found at $KUBECONFIG_PATH — run step 02 first"

for tool in kubectl helm; do
  if ! command -v $tool &>/dev/null; then
    warn "$tool not found — installing via brew..."
    brew install $tool
  fi
  ok "$tool: $(command -v $tool)"
done

log "Testing cluster connectivity..."
kube cluster-info || err "Cannot connect to cluster — check kubeconfig and VPN/network"
ok "Cluster reachable"

# ── Check all nodes are Ready ─────────────────────────────────────────────
sep
log "Checking node readiness..."
kube get nodes -o wide

NOT_READY=$(kube get nodes --no-headers | grep -v " Ready" | wc -l | tr -d ' ')
if [[ "$NOT_READY" -gt 0 ]]; then
  warn "$NOT_READY node(s) not yet Ready — listing:"
  kube get nodes | grep -v " Ready" || true
  warn "Continuing anyway — Rancher may still install but some nodes may not schedule pods"
fi
ok "Node check complete"

# ── Install cert-manager ──────────────────────────────────────────────────
sep
log "Installing cert-manager ${CERT_MANAGER_VERSION}..."

helm_cmd repo add jetstack https://charts.jetstack.io --force-update
helm_cmd repo update

if helm_cmd list -n cert-manager | grep -q cert-manager; then
  warn "cert-manager already installed — checking version..."
  INSTALLED=$(helm_cmd list -n cert-manager -o json | jq -r '.[0].app_version')
  log "  Installed: $INSTALLED | Required: $CERT_MANAGER_VERSION"
else
  log "Installing cert-manager Helm chart..."
  helm_cmd install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set installCRDs=true \
    --set global.leaderElection.namespace=cert-manager \
    --wait \
    --timeout 5m
  ok "cert-manager installed"
fi

# Wait for cert-manager pods
log "Waiting for cert-manager pods to be ready..."
kube rollout status deployment/cert-manager -n cert-manager --timeout=3m
kube rollout status deployment/cert-manager-webhook -n cert-manager --timeout=3m
kube rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=3m
ok "cert-manager pods ready"

# ── Install Rancher ───────────────────────────────────────────────────────
sep
log "Installing Rancher..."

helm_cmd repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update
helm_cmd repo update

if helm_cmd list -n "$RANCHER_NAMESPACE" | grep -q rancher; then
  warn "Rancher already installed — skipping"
else
  log "Creating namespace: $RANCHER_NAMESPACE"
  kube create namespace "$RANCHER_NAMESPACE" 2>/dev/null || true

  log "Installing Rancher Helm chart..."
  helm_cmd install rancher rancher-latest/rancher \
    --namespace "$RANCHER_NAMESPACE" \
    --set hostname="${RANCHER_HOSTNAME}" \
    --set bootstrapPassword="${RANCHER_BOOTSTRAP_PW}" \
    --set replicas=1 \
    --set ingress.tls.source=rancher \
    --set global.cattle.psp.enabled=false \
    --wait \
    --timeout 10m
  ok "Rancher Helm chart installed"
fi

# ── Wait for Rancher deployment ───────────────────────────────────────────
sep
log "Waiting for Rancher deployment to roll out (up to 10 minutes)..."

TIMEOUT=600; ELAPSED=0; INTERVAL=15
until kube rollout status deployment/rancher -n "$RANCHER_NAMESPACE" --timeout=30s &>/dev/null; do
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
  READY=$(kube get deployment rancher -n "$RANCHER_NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  log "  Rancher pods ready: ${READY}/1 — ${ELAPSED}s / ${TIMEOUT}s"
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    log "Pod status:"
    kube get pods -n "$RANCHER_NAMESPACE" || true
    log "Events:"
    kube get events -n "$RANCHER_NAMESPACE" --sort-by='.lastTimestamp' | tail -20 || true
    err "Rancher did not become ready within ${TIMEOUT}s"
  fi
done
ok "Rancher deployment is ready"

# ── Configure /etc/hosts on macOS ─────────────────────────────────────────
sep
log "Adding ${RANCHER_HOSTNAME} to /etc/hosts..."

if grep -q "${RANCHER_HOSTNAME}" /etc/hosts; then
  warn "${RANCHER_HOSTNAME} already in /etc/hosts"
else
  echo "${CP_IP}  ${RANCHER_HOSTNAME}" | sudo tee -a /etc/hosts
  ok "Added: ${CP_IP}  ${RANCHER_HOSTNAME}"
fi

# Also add to Lima VM /etc/hosts
limactl shell mzcl01-cp -- sudo bash -c \
  "grep -q '${RANCHER_HOSTNAME}' /etc/hosts || echo '${CP_IP}  ${RANCHER_HOSTNAME}' >> /etc/hosts"
ok "Added to mzcl01-cp /etc/hosts"

# ── Get Rancher service info ───────────────────────────────────────────────
sep
log "Rancher service info:"
kube get svc -n "$RANCHER_NAMESPACE"

log "Rancher pods:"
kube get pods -n "$RANCHER_NAMESPACE" -o wide

# ── Final summary ─────────────────────────────────────────────────────────
sep
ok "STEP 05 COMPLETE — Rancher UI installed"
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           RANCHER ACCESS DETAILS                        ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  URL:       https://${RANCHER_HOSTNAME}                       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Alt URL:   https://${CP_IP}                         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Username:  admin                                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Password:  ${RANCHER_BOOTSTRAP_PW}   (change on first login!) ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
log "Accept the self-signed certificate warning in your browser."
log "You will be prompted to set a new admin password on first login."
echo ""
log "Next step → run: 06_verify_cluster.sh"
sep

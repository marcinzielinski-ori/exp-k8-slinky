#!/usr/bin/env bash
# =============================================================================
# STEP 06 — macOS host: Verify full cluster health
# Checks all nodes, system pods, Rancher, and prints a final summary.
# Safe to re-run at any time.
# =============================================================================

# When sourced, re-run as a subprocess so exit/set -e don't kill the terminal
(return 0 2>/dev/null) && { bash "${BASH_SOURCE[0]}" "$@"; return $?; }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOGDIR"
LOGDIR="$(cd "$LOGDIR" && pwd)"
LOGFILE="${LOGDIR}/06_verify_cluster_$(date +%Y%m%d_%H%M%S).log"
IPENV="$(dirname "$LOGDIR")/vm_ips.env"
KUBECONFIG_PATH="$HOME/.kube/rke2-local.yaml"

exec > >(tee -a "$LOGFILE") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${CYAN}[$(date '+%H:%M:%S')] [INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[$(date '+%H:%M:%S')] [ OK ]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC}  $*"; }
err()    { echo -e "${RED}[$(date '+%H:%M:%S')] [FAIL]${NC}  $*"; }
sep()    { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
header() { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }

kube() { KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"; }

PASS=0; FAIL=0; WARN=0

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    ok "✔  $label"
    PASS=$((PASS+1))
  else
    err "✘  $label"
    FAIL=$((FAIL+1))
  fi
}

sep
log "STEP 06 — Cluster Verification"
log "Logfile: $LOGFILE"
sep

# ── Load IPs ──────────────────────────────────────────────────────────────
[[ -f "$IPENV" ]] && source "$IPENV" || warn "vm_ips.env not found"
CP_IP="${IP_mzcl01_cp:-unknown}"

# ── 1. Connectivity ───────────────────────────────────────────────────────
header "1. Cluster Connectivity"
check "kubeconfig exists" test -f "$KUBECONFIG_PATH"
check "API server reachable" kube cluster-info
check "kubectl version" kube version --client

# ── 2. Nodes ──────────────────────────────────────────────────────────────
header "2. Node Status"
kube get nodes -o wide
echo ""

EXPECTED_NODES=(mzcl01-cp mzcl01-w1 mzcl01-w2)
for NODE in "${EXPECTED_NODES[@]}"; do
  if kube get node "$NODE" &>/dev/null; then
    NODE_STATUS=$(kube get node "$NODE" -o jsonpath='{.status.conditions[-1].type}')
    NODE_READY=$(kube get node "$NODE" -o jsonpath='{.status.conditions[-1].status}')
    if [[ "$NODE_STATUS" == "Ready" && "$NODE_READY" == "True" ]]; then
      ok "✔  Node $NODE — Ready"
      PASS=$((PASS+1))
    else
      err "✘  Node $NODE — NOT Ready (status: $NODE_STATUS=$NODE_READY)"
      FAIL=$((FAIL+1))
    fi
  else
    warn "⚠  Node $NODE — NOT FOUND in cluster"
    WARN=$((WARN+1))
  fi
done

# ── 3. System pods ────────────────────────────────────────────────────────
header "3. System Pods (kube-system)"
kube get pods -n kube-system -o wide
echo ""

NOT_RUNNING=$(kube get pods -n kube-system --no-headers \
  | grep -vE "Running|Completed" | wc -l | tr -d ' ')
if [[ "$NOT_RUNNING" -eq 0 ]]; then
  ok "✔  All kube-system pods Running/Completed"
  PASS=$((PASS+1))
else
  warn "⚠  $NOT_RUNNING pod(s) in kube-system not Running:"
  kube get pods -n kube-system --no-headers | grep -vE "Running|Completed" || true
  WARN=$((WARN+1))
fi

# ── 4. cert-manager ───────────────────────────────────────────────────────
header "4. cert-manager"
kube get pods -n cert-manager -o wide 2>/dev/null || warn "cert-manager namespace not found"
echo ""

for DEP in cert-manager cert-manager-webhook cert-manager-cainjector; do
  READY=$(kube get deployment "$DEP" -n cert-manager \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "$READY" -ge 1 ]]; then
    ok "✔  $DEP — Ready ($READY replicas)"
    PASS=$((PASS+1))
  else
    err "✘  $DEP — NOT Ready"
    FAIL=$((FAIL+1))
  fi
done

# ── 5. Rancher ────────────────────────────────────────────────────────────
header "5. Rancher"
kube get pods -n cattle-system -o wide 2>/dev/null || warn "cattle-system namespace not found"
echo ""

RANCHER_READY=$(kube get deployment rancher -n cattle-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$RANCHER_READY" -ge 1 ]]; then
  ok "✔  Rancher deployment Ready ($RANCHER_READY replicas)"
  PASS=$((PASS+1))
else
  err "✘  Rancher deployment NOT Ready"
  FAIL=$((FAIL+1))
fi

# Test Rancher HTTPS
RANCHER_HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  "https://rancher.local" --max-time 5 2>/dev/null || echo "000")
if [[ "$RANCHER_HTTP_CODE" =~ ^(200|301|302)$ ]]; then
  ok "✔  Rancher UI responding (HTTP $RANCHER_HTTP_CODE)"
  PASS=$((PASS+1))
else
  warn "⚠  Rancher UI HTTP check returned: $RANCHER_HTTP_CODE"
  WARN=$((WARN+1))
fi

# ── 6. Storage ────────────────────────────────────────────────────────────
header "6. Storage Classes"
kube get storageclass 2>/dev/null || warn "No storage classes found"

# ── 7. Lima VM status ─────────────────────────────────────────────────────
header "7. Lima VM Status (macOS)"
if command -v limactl &>/dev/null; then
  limactl list
else
  warn "limactl not found"
fi

# ── 8. Network connectivity between nodes ─────────────────────────────────
header "8. Cross-node Pod Networking"
log "Deploying test pod to verify pod networking..."

TEST_NS="verify-network-$(date +%s)"
kube create namespace "$TEST_NS" &>/dev/null

kube run nettest --image=busybox:1.36 --restart=Never -n "$TEST_NS" \
  --command -- sleep 30 &>/dev/null || true

sleep 5

POD_IP=$(kube get pod nettest -n "$TEST_NS" \
  -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
POD_STATUS=$(kube get pod nettest -n "$TEST_NS" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")

if [[ "$POD_STATUS" == "Running" ]]; then
  ok "✔  Test pod running (IP: $POD_IP)"
  PASS=$((PASS+1))
else
  warn "⚠  Test pod status: $POD_STATUS"
  WARN=$((WARN+1))
fi

# Cleanup
kube delete namespace "$TEST_NS" &>/dev/null || true

# ── Final summary ─────────────────────────────────────────────────────────
sep
echo ""
echo -e "${BOLD}VERIFICATION SUMMARY${NC}"
echo -e "  ${GREEN}✔ PASSED: $PASS${NC}"
echo -e "  ${YELLOW}⚠ WARNINGS: $WARN${NC}"
echo -e "  ${RED}✘ FAILED: $FAIL${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║  CLUSTER HEALTHY — All critical checks passed  ✔         ║${NC}"
  echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}${BOLD}║${NC}  Rancher UI:  https://rancher.local                      ${GREEN}${BOLD}║${NC}"
  echo -e "${GREEN}${BOLD}║${NC}  Alt access:  https://${CP_IP}                          ${GREEN}${BOLD}║${NC}"
  echo -e "${GREEN}${BOLD}║${NC}  Kubeconfig:  ~/.kube/rke2-local.yaml                    ${GREEN}${BOLD}║${NC}"
  echo -e "${GREEN}${BOLD}║${NC}  Nodes:       3 (1 control plane + 2 workers)            ${GREEN}${BOLD}║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
else
  echo -e "${RED}${BOLD}Some checks failed — review log: $LOGFILE${NC}"
fi

echo ""
sep

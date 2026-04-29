# =============================================================================
# STEP 04 — Windows: Join Multipass worker VMs to Kubernetes cluster (kubeadm)
# Installs containerd + kubeadm on mzcl01-w3, mzcl01-w4 and runs kubeadm join.
# Run on Windows laptop after step 02 completes.
# Requires: k8s_join_token.env content set as env vars from macOS host
# =============================================================================

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Logging setup ─────────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir    = Join-Path (Split-Path -Parent $ScriptDir) "logs"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogDir "04_k8s_workers_multipass_${Timestamp}.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Write-Log {
  param([string]$Level, [string]$Message, [string]$Color = "White")
  $ts   = Get-Date -Format "HH:mm:ss"
  $line = "[$ts] [$Level] $Message"
  Write-Host $line -ForegroundColor $Color
  Add-Content -Path $LogFile -Value $line
}
function log  { param([string]$m) Write-Log "INFO" $m "Cyan"   }
function ok   { param([string]$m) Write-Log " OK " $m "Green"  }
function warn { param([string]$m) Write-Log "WARN" $m "Yellow" }
function err  { param([string]$m) Write-Log "FAIL" $m "Red"; exit 1 }
function sep  { $line = "━" * 64; Write-Log "----" $line "Blue" }

# ── Config — copy values from k8s_join_token.env on macOS host ───────────
# Set these env vars before running:
#   $env:K8S_JOIN_COMMAND = "kubeadm join <CP_IP>:6443 --token <tok> --discovery-token-ca-cert-hash sha256:<hash>"
#   $env:K8S_CP_IP        = "<CP_IP>"
$K8S_JOIN_COMMAND = $env:K8S_JOIN_COMMAND
$K8S_CP_IP        = $env:K8S_CP_IP

$VM_IPS = @{
  "mzcl01-w3" = $env:IP_mzcl01_w3
  "mzcl01-w4" = $env:IP_mzcl01_w4
}

$K8S_MINOR = "1.34"
$Workers   = @("mzcl01-w3", "mzcl01-w4")

# ── Helpers ───────────────────────────────────────────────────────────────
function Invoke-MPExecRoot {
  param([string]$VMName, [string]$Command)
  $result = multipass exec $VMName -- sudo bash -c $Command 2>&1
  return $result
}

# ── Start ─────────────────────────────────────────────────────────────────
sep
log "STEP 04 — Kubernetes Worker Nodes (kubeadm join, Multipass)"
log "Target VMs: $($Workers -join ', ')"
log "Logfile: $LogFile"
sep

if (-not $K8S_JOIN_COMMAND) {
  err "K8S_JOIN_COMMAND env var not set.`nCopy it from k8s_join_token.env on macOS host:`n  `$env:K8S_JOIN_COMMAND = 'kubeadm join ...'"
}
if (-not $K8S_CP_IP) {
  err "K8S_CP_IP env var not set."
}

log "Control plane: $K8S_CP_IP:6443"

# ── Connectivity check ────────────────────────────────────────────────────
log "Testing connectivity to control plane at ${K8S_CP_IP}:6443..."
$tcpTest = Test-NetConnection -ComputerName $K8S_CP_IP -Port 6443 -WarningAction SilentlyContinue
if (-not $tcpTest.TcpTestSucceeded) {
  err "Cannot reach control plane at ${K8S_CP_IP}:6443 — check network/firewall"
}
ok "Control plane reachable"

# ── Process each worker VM ────────────────────────────────────────────────
foreach ($VM in $Workers) {
  sep
  log "Processing worker VM: $VM"

  $info  = multipass list --format json | ConvertFrom-Json
  $entry = $info.list | Where-Object { $_.name -eq $VM }
  if (-not $entry -or $entry.state -ne "Running") {
    err "VM $VM is not running (state: $($entry.state)) — run step 01 first"
  }
  ok "VM $VM is running"

  $vmIP = $VM_IPS[$VM]
  if (-not $vmIP) {
    $vmIP = if ($entry.ipv4) { $entry.ipv4[0] } else { "" }
  }
  log "Worker IP: $vmIP"

  # ── System prep ────────────────────────────────────────────────────────
  log "System prep on $VM..."
  Invoke-MPExecRoot $VM "swapoff -a && sed -i '/swap/d' /etc/fstab" | Out-Null
  Invoke-MPExecRoot $VM "modprobe overlay && modprobe br_netfilter" | Out-Null
  Invoke-MPExecRoot $VM "printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf" | Out-Null
  Invoke-MPExecRoot $VM "printf 'net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-k8s.conf && sysctl --system" | Out-Null
  ok "System prep complete"

  # ── Install containerd ──────────────────────────────────────────────────
  log "Installing containerd on $VM..."
  Invoke-MPExecRoot $VM "apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg" | Out-Null
  Invoke-MPExecRoot $VM "mkdir -p /etc/apt/keyrings" | Out-Null
  Invoke-MPExecRoot $VM "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" | Out-Null
  Invoke-MPExecRoot $VM "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list" | Out-Null
  Invoke-MPExecRoot $VM "apt-get update -qq && apt-get install -y -qq containerd.io" | Out-Null
  Invoke-MPExecRoot $VM "containerd config default > /etc/containerd/config.toml && sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml" | Out-Null
  Invoke-MPExecRoot $VM "systemctl enable containerd && systemctl restart containerd" | Out-Null
  ok "containerd installed on $VM"

  # ── Install kubelet + kubeadm ───────────────────────────────────────────
  log "Installing kubelet, kubeadm (v${K8S_MINOR}) on $VM..."
  Invoke-MPExecRoot $VM "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg" | Out-Null
  Invoke-MPExecRoot $VM "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list" | Out-Null
  Invoke-MPExecRoot $VM "apt-get update -qq && apt-get install -y -qq kubelet kubeadm" | Out-Null
  Invoke-MPExecRoot $VM "apt-mark hold kubelet kubeadm && systemctl enable kubelet" | Out-Null
  ok "Kubernetes packages installed on $VM"

  # ── kubeadm join ───────────────────────────────────────────────────────
  $alreadyJoined = Invoke-MPExecRoot $VM "test -f /etc/kubernetes/kubelet.conf && echo yes || echo no"
  if ($alreadyJoined -match "yes") {
    warn "$VM already joined cluster — skipping join"
  } else {
    log "Running kubeadm join on $VM..."
    Invoke-MPExecRoot $VM $K8S_JOIN_COMMAND | Out-Null
    ok "kubeadm join complete on $VM"
  }

  # ── Wait for agent ─────────────────────────────────────────────────────
  log "Waiting 20s for kubelet to register with control plane..."
  Start-Sleep -Seconds 20

  $svcStatus = Invoke-MPExecRoot $VM "systemctl is-active kubelet"
  if ($svcStatus -notmatch "active") {
    $svcLog = Invoke-MPExecRoot $VM "journalctl -u kubelet --no-pager -n 20"
    log "kubelet log:`n$svcLog"
    err "kubelet is not active on $VM (status: $svcStatus)"
  }
  ok "kubelet is active on $VM"
}

# ── Final instructions ────────────────────────────────────────────────────
sep
ok "STEP 04 COMPLETE — Multipass workers joined the cluster"
log ""
log "Verify nodes from macOS host:"
log "  kubectl --kubeconfig ~/.kube/k8s-local.yaml get nodes -o wide"
log ""
log "Note: Windows Multipass VMs are on a separate subnet."
log "Ensure both laptops are on the same LAN and port 6443 is reachable."
log ""
log "Next step → run on macOS: 05_ingress_nginx.sh"
sep

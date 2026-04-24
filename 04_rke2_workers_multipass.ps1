# =============================================================================
# STEP 04 — Windows: Install RKE2 Agent on Multipass worker VMs (mzcl01-w3, mzcl01-w4)
# Run on Windows laptop after step 02 completes.
# Requires: rke2_join_token.env content merged from macOS host
# =============================================================================

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Logging setup ─────────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir    = Join-Path (Split-Path -Parent $ScriptDir) "logs"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogDir "04_rke2_workers_multipass_${Timestamp}.log"

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

# ── Config — fill these in after copying from macOS ──────────────────────
# Copy values from rke2_join_token.env on your macOS host:
$RKE2_SERVER_URL  = $env:RKE2_SERVER_URL
$RKE2_JOIN_TOKEN  = $env:RKE2_JOIN_TOKEN

# Worker VM IPs from vm_ips_windows.env:
$VM_IPS = @{
  "mzcl01-w3" = $env:IP_mzcl01_w3
  "mzcl01-w4" = $env:IP_mzcl01_w4
}

$Workers = @("mzcl01-w3", "mzcl01-w4")

# ── Helper: run command in Multipass VM ──────────────────────────────────
function Invoke-MPExec {
  param([string]$VMName, [string]$Command)
  $result = multipass exec $VMName -- bash -c $Command 2>&1
  return $result
}

function Invoke-MPExecRoot {
  param([string]$VMName, [string]$Command)
  $result = multipass exec $VMName -- sudo bash -c $Command 2>&1
  return $result
}

# ── Start ─────────────────────────────────────────────────────────────────
sep
log "STEP 04 — RKE2 Agent Installation on Multipass Worker VMs"
log "Target VMs: $($Workers -join ', ')"
log "Logfile: $LogFile"
sep

# ── Validate required config ──────────────────────────────────────────────
if (-not $RKE2_SERVER_URL) {
  err "RKE2_SERVER_URL env var not set.`nSet it with: `$env:RKE2_SERVER_URL = 'https://<CP_IP>:9345'"
}
if (-not $RKE2_JOIN_TOKEN) {
  err "RKE2_JOIN_TOKEN env var not set.`nCopy the token from rke2_join_token.env on macOS host."
}

log "Server URL: $RKE2_SERVER_URL"
log "Token:      $($RKE2_JOIN_TOKEN.Substring(0, [Math]::Min(20, $RKE2_JOIN_TOKEN.Length)))...[redacted]"

# ── Connectivity check to control plane ──────────────────────────────────
$cpHost = $RKE2_SERVER_URL -replace 'https://','' -replace ':9345',''
log "Testing connectivity to control plane at ${cpHost}:9345..."
$tcpTest = Test-NetConnection -ComputerName $cpHost -Port 9345 -WarningAction SilentlyContinue
if (-not $tcpTest.TcpTestSucceeded) {
  err "Cannot reach control plane at ${cpHost}:9345 — check network/firewall"
}
ok "Control plane reachable"

# ── Process each worker VM ────────────────────────────────────────────────
foreach ($VM in $Workers) {
  sep
  log "Processing worker VM: $VM"

  $vmIP = $VM_IPS[$VM]
  if (-not $vmIP) {
    warn "IP for $VM not set in VM_IPS — will use auto-detected IP"
    $info  = multipass list --format json | ConvertFrom-Json
    $entry = $info.list | Where-Object { $_.name -eq $VM }
    $vmIP  = if ($entry.ipv4) { $entry.ipv4[0] } else { "" }
  }
  log "Worker IP: $vmIP"

  # Check VM is running
  $info  = multipass list --format json | ConvertFrom-Json
  $entry = $info.list | Where-Object { $_.name -eq $VM }
  if (-not $entry -or $entry.state -ne "Running") {
    err "VM $VM is not running (state: $($entry.state)) — run step 01 first"
  }
  ok "VM $VM is running"

  # ── System prep ──────────────────────────────────────────────────────
  log "Preparing system on $VM..."

  Invoke-MPExecRoot $VM "swapoff -a && sed -i '/swap/d' /etc/fstab" | Out-Null
  ok "Swap disabled"

  Invoke-MPExecRoot $VM "modprobe overlay && modprobe br_netfilter" | Out-Null
  Invoke-MPExecRoot $VM "printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf" | Out-Null
  Invoke-MPExecRoot $VM @"
cat > /etc/sysctl.d/99-k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
"@ | Out-Null
  ok "Kernel modules and sysctl applied"

  # ── Install RKE2 agent ──────────────────────────────────────────────
  log "Installing RKE2 agent on $VM (downloading ~60MB)..."
  $installOut = Invoke-MPExecRoot $VM "curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=agent sh -"
  log "  $installOut"
  ok "RKE2 agent binary installed"

  # ── Write agent config ──────────────────────────────────────────────
  log "Writing RKE2 agent config on $VM..."
  $configContent = @"
# RKE2 Agent Configuration — ${VM}
server: ${RKE2_SERVER_URL}
token: ${RKE2_JOIN_TOKEN}

node-ip: ${vmIP}
node-name: ${VM}

kubelet-arg:
  - node-status-update-frequency=10s
  - node-monitor-grace-period=40s
"@

  Invoke-MPExecRoot $VM "mkdir -p /etc/rancher/rke2" | Out-Null
  # Write config via heredoc through multipass exec
  $escapedConfig = $configContent -replace '"','\"'
  multipass exec $VM -- sudo tee /etc/rancher/rke2/config.yaml | Out-Null
  # Use transfer instead for reliability
  $tmpConfig = Join-Path $env:TEMP "rke2-agent-config-${VM}.yaml"
  Set-Content -Path $tmpConfig -Value $configContent -Encoding UTF8
  multipass transfer $tmpConfig "${VM}:/tmp/rke2-agent-config.yaml"
  Invoke-MPExecRoot $VM "cp /tmp/rke2-agent-config.yaml /etc/rancher/rke2/config.yaml" | Out-Null
  Remove-Item $tmpConfig -ErrorAction SilentlyContinue
  ok "Agent config written"

  # ── Start agent ────────────────────────────────────────────────────
  log "Enabling and starting RKE2 agent service on $VM..."
  Invoke-MPExecRoot $VM "systemctl enable rke2-agent.service" | Out-Null
  Invoke-MPExecRoot $VM "systemctl start rke2-agent.service" | Out-Null
  ok "RKE2 agent service started"

  # ── Wait for agent to register ─────────────────────────────────────
  log "Waiting 30s for agent to register with control plane..."
  Start-Sleep -Seconds 30

  # Check agent service is still alive
  $svcStatus = Invoke-MPExecRoot $VM "systemctl is-active rke2-agent.service"
  if ($svcStatus -notmatch "active") {
    $svcLog = Invoke-MPExecRoot $VM "journalctl -u rke2-agent.service --no-pager -n 30"
    log "Agent service log:`n$svcLog"
    err "RKE2 agent service is not active on $VM (status: $svcStatus)"
  }
  ok "RKE2 agent service is active on $VM"
}

# ── Final instructions ────────────────────────────────────────────────────
sep
ok "STEP 04 COMPLETE — Multipass worker agents started"
log ""
log "Verify nodes joined from macOS host:"
log "  KUBECONFIG=~/.kube/rke2-local.yaml kubectl get nodes -o wide"
log ""
log "Note: Windows Multipass VMs are on a separate subnet."
log "If nodes don't appear, ensure:"
log "  1. Both laptops are on the same LAN"
log "  2. Control plane port 9345 is reachable from Windows laptop"
log "  3. macOS firewall allows inbound on 9345, 6443"
log ""
log "Next step → run on macOS: 05_rancher_install.sh"
sep

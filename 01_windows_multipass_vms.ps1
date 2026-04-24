# =============================================================================
# STEP 01 — Windows: Deploy Multipass VMs
# 2 VMs: mzcl01-w3 (worker 3), mzcl01-w4 (worker 4)
# Run this ONLY on Windows laptop (PowerShell 5.1+ or PowerShell 7+)
# =============================================================================

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Paths: safe for both piped stdin AND file execution ───────────────────
# $MyInvocation.MyCommand.Path is $null when piped via stdin — use TEMP fallback
$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir     = Join-Path $env:TEMP "mzcl01-logs"
$LogFile    = Join-Path $LogDir "01_windows_multipass_vms_${Timestamp}.log"
$IpFile     = Join-Path $env:TEMP "vm_ips_windows.env"
$CloudInitFile = Join-Path $env:TEMP "mzcl01-cloud-init.yaml"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Write-Log {
  param([string]$Level, [string]$Message, [string]$Color = "White")
  $ts   = Get-Date -Format "HH:mm:ss"
  $line = "[$ts] [$Level] $Message"
  Write-Host $line -ForegroundColor $Color
  Add-Content -Path $LogFile -Value $line
}
function log  { param([string]$m) Write-Log "INFO" $m "Cyan"    }
function ok   { param([string]$m) Write-Log " OK " $m "Green"   }
function warn { param([string]$m) Write-Log "WARN" $m "Yellow"  }
function err  { param([string]$m) Write-Log "FAIL" $m "Red"; exit 1 }
function sep  { $line = "━" * 64; Write-Log "----" $line "Blue" }

# ── VM definitions ─────────────────────────────────────────────────────────
$VMs = @(
  @{ Name = "mzcl01-w3"; CPUs = 1; Memory = "2G"; Disk = "20G"; Role = "worker" },
  @{ Name = "mzcl01-w4"; CPUs = 1; Memory = "2G"; Disk = "20G"; Role = "worker" }
)

# ── Cloud-init for each VM ─────────────────────────────────────────────────
$CloudInit = @"
#cloud-config
package_update: true
packages:
  - curl
  - wget
  - jq
  - git
  - vim
  - htop
  - net-tools

runcmd:
  # Disable swap
  - swapoff -a
  - sed -i '/swap/d' /etc/fstab
  # Kernel modules
  - modprobe overlay
  - modprobe br_netfilter
  - echo -e "overlay\nbr_netfilter" > /etc/modules-load.d/k8s.conf
  # Sysctl
  - |
    cat > /etc/sysctl.d/99-k8s.conf <<EOF
    net.bridge.bridge-nf-call-iptables  = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward                 = 1
    EOF
  - sysctl --system
"@

# ── Start ──────────────────────────────────────────────────────────────────
sep
log "STEP 01 — Windows Multipass VM Deployment"
log "Logfile: $LogFile"
sep

# ── OS check ──────────────────────────────────────────────────────────────
if ($env:OS -ne "Windows_NT") {
  err "This script must run on Windows. Detected OS: $($env:OS)"
}
ok "Running on Windows"

# ── Multipass check ────────────────────────────────────────────────────────
log "Checking for Multipass..."
$multipass = Get-Command multipass -ErrorAction SilentlyContinue
if (-not $multipass) {
  warn "Multipass not found. Attempting install via winget..."
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install Canonical.Multipass --silent
    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
  } else {
    err "winget not available. Install Multipass from: https://multipass.run/install"
  }
}
$mpVersion = multipass version 2>&1 | Select-Object -First 1
ok "Multipass available: $mpVersion"

# ── Write cloud-init to temp file ─────────────────────────────────────────
$CloudInitFile = Join-Path $env:TEMP "rke2-cloud-init.yaml"
log "Writing cloud-init config → $CloudInitFile"
Set-Content -Path $CloudInitFile -Value $CloudInit -Encoding UTF8
ok "Cloud-init written"

# ── Deploy each VM ─────────────────────────────────────────────────────────
foreach ($VM in $VMs) {
  sep
  log "Processing VM: $($VM.Name) (role: $($VM.Role))"
  log "  CPUs: $($VM.CPUs) | Memory: $($VM.Memory) | Disk: $($VM.Disk)"

  # Check if already exists
  $existing = multipass list --format json 2>$null | ConvertFrom-Json
  $found = $existing.list | Where-Object { $_.name -eq $VM.Name }

  if ($found) {
    warn "VM '$($VM.Name)' already exists (state: $($found.state))"
    if ($found.state -eq "Running") {
      ok "VM '$($VM.Name)' is already running — skipping"
      continue
    } else {
      warn "VM '$($VM.Name)' exists but stopped — starting..."
      multipass start $VM.Name
      ok "VM '$($VM.Name)' started"
      continue
    }
  }

  log "Launching VM '$($VM.Name)' — this may take 3-5 minutes..."
  multipass launch `
    --name    $VM.Name `
    --cpus    $VM.CPUs `
    --memory  $VM.Memory `
    --disk    $VM.Disk `
    --cloud-init $CloudInitFile `
    22.04

  if ($LASTEXITCODE -ne 0) {
    err "Failed to launch VM '$($VM.Name)'"
  }
  ok "VM '$($VM.Name)' launched successfully"

  # Wait for cloud-init to complete
  log "Waiting for cloud-init to finish on '$($VM.Name)'..."
  $timeout = 120
  $elapsed = 0
  do {
    Start-Sleep -Seconds 10
    $elapsed += 10
    $status = multipass exec $VM.Name -- cloud-init status 2>&1
    log "  cloud-init status: $status (${elapsed}s elapsed)"
  } while ($status -notmatch "done" -and $elapsed -lt $timeout)

  if ($status -notmatch "done") {
    warn "cloud-init may not have completed fully on '$($VM.Name)' — continuing anyway"
  } else {
    ok "cloud-init complete on '$($VM.Name)'"
  }
}

# ── Post-deploy: collect VM info ───────────────────────────────────────────
sep
log "Collecting VM network info..."

$ipInfo = @{}
Write-Host ""
Write-Host ("{0,-15} {1,-12} {2,-20} {3}" -f "VM NAME","STATE","IP ADDRESS","ROLE") -ForegroundColor Blue
Write-Host ("{0,-15} {1,-12} {2,-20} {3}" -f "───────────────","────────────","────────────────────","──────────────")

foreach ($VM in $VMs) {
  $info  = multipass list --format json | ConvertFrom-Json
  $entry = $info.list | Where-Object { $_.name -eq $VM.Name }
  $ip    = if ($entry.ipv4) { $entry.ipv4[0] } else { "pending" }
  $state = if ($entry) { $entry.state } else { "unknown" }
  Write-Host ("{0,-15} {1,-12} {2,-20} {3}" -f $VM.Name, $state, $ip, $VM.Role)
  $ipInfo[$VM.Name] = $ip
}

# ── Save IPs ───────────────────────────────────────────────────────────────
Write-Host ""
$IpFile = Join-Path (Split-Path -Parent $ScriptDir) "vm_ips_windows.env"
$lines  = @("# Generated by 01_windows_multipass_vms.ps1 — $(Get-Date)")
foreach ($VM in $VMs) {
  $varName = "IP_$($VM.Name -replace '-','_')"
  $lines  += "${varName}=$($ipInfo[$VM.Name])"
  log "  ${varName}=$($ipInfo[$VM.Name])"
}
Set-Content -Path $IpFile -Value ($lines -join "`n") -Encoding UTF8
ok "IPs saved to: $IpFile"

# ── Cleanup ────────────────────────────────────────────────────────────────
Remove-Item -Path $CloudInitFile -ErrorAction SilentlyContinue

sep
ok "STEP 01 COMPLETE — Multipass VMs deployed"
log "Copy vm_ips_windows.env content to your macOS host and append to vm_ips.env"
log "Next step → run on macOS: 02_rke2_control_plane.sh"
sep

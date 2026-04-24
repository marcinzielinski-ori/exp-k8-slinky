#!/usr/bin/env bash
# Copies per-VM Lima SSH configs into a single combined file for Ansible.
# Run once before the playbooks, or after restarting Lima VMs.
set -euo pipefail

COMBINED="$HOME/.ssh/lima_rke2.conf"
VMS=(mzcl01-cp mzcl01-w1 mzcl01-w2)

for vm in "${VMS[@]}"; do
  cfg="$HOME/.lima/${vm}/ssh.config"
  [[ -f "$cfg" ]] || { echo "ERROR: $cfg not found — is $vm running?"; exit 1; }
done

: > "$COMBINED"
for vm in "${VMS[@]}"; do
  cat "$HOME/.lima/${vm}/ssh.config" >> "$COMBINED"
done

echo "SSH config written to $COMBINED"
echo "Test: ssh -F $COMBINED lima-mzcl01-cp hostname"

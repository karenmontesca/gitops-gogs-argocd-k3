#!/usr/bin/env bash
# Runs ON vm-proxy-git. Does everything, in order:
#   1. 10-proxy-host.sh   (this machine)
#   2. 20-k3-host.sh      (vm-k3-git, copied and started over SSH)
#   3. 30-deploy.sh       (this machine)
#   4. 40-verify.sh
#
# Tip: run it inside tmux so an SSH drop does not kill it:  tmux new -s lab
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_vars

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)

"$SCRIPT_DIR/10-proxy-host.sh"

log "Setting up SSH access to vm-k3-git (${K3_IP})"
[[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
if ! ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 "root@${K3_IP}" true 2>/dev/null; then
  info "Enter the root password of vm-k3-git once, to copy the SSH key:"
  ssh-copy-id -o StrictHostKeyChecking=accept-new "root@${K3_IP}"
fi
ssh "${SSH_OPTS[@]}" "root@${K3_IP}" true || die "SSH to vm-k3-git still fails. Is root login over SSH enabled there?"

log "Running 20-k3-host.sh on vm-k3-git"
scp "${SSH_OPTS[@]}" "$SCRIPT_DIR/20-k3-host.sh" "root@${K3_IP}:/root/20-k3-host.sh"
ssh "${SSH_OPTS[@]}" "root@${K3_IP}" \
  "K3_IP='${K3_IP}' PROXY_INT_IP='${PROXY_INT_IP}' K3_IFACE='${K3_IFACE}' bash /root/20-k3-host.sh"

"$SCRIPT_DIR/30-deploy.sh"
"$SCRIPT_DIR/40-verify.sh"

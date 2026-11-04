#!/usr/bin/env bash
# Runs ON vm-proxy-git. Read-only checks, safe to run any time.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_vars
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
RK="kubectl --kubeconfig /root/vmk8s.yaml"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0

log "ArgoCD Application"
kubectl get application instana-agent -n argocd \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null \
  || fail "Application instana-agent not found"

log "Pods on vm-k3-git"
$RK get pods -n instana-agent 2>&1

log "Checks"
n=$($RK get ds instana-agent -n instana-agent -o jsonpath='{.status.numberReady}' 2>/dev/null)
[[ ${n:-0} -ge 1 ]] && ok "Instana agent DaemonSet is ready" || fail "Instana agent DaemonSet is not ready"

if grep "$K3_IP" /var/log/squid/access.log 2>/dev/null | grep -q TCP_TUNNEL; then
  ok "Squid log shows tunnels from $K3_IP"
else
  fail "No TCP_TUNNEL entries from $K3_IP in the Squid log"
fi

denied=$(grep "$K3_IP" /var/log/squid/access.log 2>/dev/null | grep TCP_DENIED | awk '{print $7}' | sort -u | head -5)
if [[ -n $denied ]]; then
  fail "Blocked requests seen (add the domains to squid.conf if a pod is stuck):"
  echo "$denied" | sed 's/^/         /'
else
  ok "No blocked requests in the Squid log"
fi

if ssh "${SSH_OPTS[@]}" "root@${K3_IP}" 'ping -c 2 -W 3 8.8.8.8' >/dev/null 2>&1; then
  fail "vm-k3-git CAN ping 8.8.8.8: isolation is broken"
else
  ok "vm-k3-git cannot reach the internet directly (isolation intact)"
fi

echo
(( FAILED == 0 )) && log "All checks passed." || { warn "Some checks failed."; exit 1; }

#!/usr/bin/env bash
# Runs ON vm-proxy-git, after 10 and 20.
# Registers vm-k3-git in ArgoCD, fills the Gogs repo, creates the Application
# and waits for the Instana agent. Safe to re-run.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_vars

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
REMOTE_KUBECONFIG=/root/vmk8s.yaml
RK="kubectl --kubeconfig $REMOTE_KUBECONFIG"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)
GOGS_URL="http://${PROXY_NAT_IP}:3000"
REPO_URL="${GOGS_URL}/${GOGS_ADMIN_USER}/${GOGS_REPO}.git"

# ---------------------------------------------------------------- remote kubeconfig
log "1/6 Fetching the vm-k3-git kubeconfig"
scp "${SSH_OPTS[@]}" "root@${K3_IP}:/etc/rancher/k3s/k3s.yaml" "$REMOTE_KUBECONFIG"
sed -i "s#127.0.0.1#${K3_IP}#" "$REMOTE_KUBECONFIG"
chmod 600 "$REMOTE_KUBECONFIG"
if ! $RK get nodes >/tmp/k3-nodes.log 2>&1; then
  cat /tmp/k3-nodes.log
  if grep -qi 'x509' /tmp/k3-nodes.log; then
    die "x509 error: the vm-k3-git certificate does not include ${K3_IP}. See README step 8.2."
  fi
  die "Cannot reach the vm-k3-git API on ${K3_IP}:6443."
fi

# ---------------------------------------------------------------- argocd cli
log "2/6 ArgoCD CLI and login"
if ! command -v argocd >/dev/null; then
  curl -sSL -o /usr/local/bin/argocd \
    https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  chmod +x /usr/local/bin/argocd
fi
ARGOPW=${ARGOCD_ADMIN_PASSWORD:-$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)}
[[ -n $ARGOPW ]] || die "Could not read the ArgoCD admin password. If you changed it, set ARGOCD_ADMIN_PASSWORD in vars.env."
argocd login "${PROXY_NAT_IP}:30443" --username admin --password "$ARGOPW" --insecure

# ---------------------------------------------------------------- register cluster
log "3/6 Registering vm-k3-git in ArgoCD"
if argocd cluster list -o json | jq -e '.[] | select(.name=="vm-k8s")' >/dev/null 2>&1; then
  info "Cluster vm-k8s is already registered."
else
  argocd cluster add default --kubeconfig "$REMOTE_KUBECONFIG" --name vm-k8s --yes
fi
argocd cluster list

# ---------------------------------------------------------------- gogs repo
log "4/6 Filling the Gogs repository"
api() { curl -s -u "${GOGS_ADMIN_USER}:${GOGS_ADMIN_PASSWORD}" "$@"; }

status=$(api -o /dev/null -w '%{http_code}' "${GOGS_URL}/api/v1/repos/${GOGS_ADMIN_USER}/${GOGS_REPO}")
if [[ $status != 200 ]]; then
  info "Creating private repo ${GOGS_REPO}"
  api -f -o /dev/null -X POST "${GOGS_URL}/api/v1/user/repos" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg n "$GOGS_REPO" '{name:$n, private:true, auto_init:true}')" \
    || die "Could not create the repo in Gogs. Check the admin credentials in vars.env."
else
  info "Repo ${GOGS_REPO} already exists."
fi
BRANCH=$(api "${GOGS_URL}/api/v1/repos/${GOGS_ADMIN_USER}/${GOGS_REPO}" | jq -r '.default_branch // "master"')
info "Default branch: $BRANCH"

WORK=$(mktemp -d)
ASKPASS=$(mktemp)
trap 'rm -rf "$WORK" "$ASKPASS"' EXIT
cat > "$ASKPASS" <<'EOA'
#!/bin/sh
printf '%s\n' "$GOGS_ADMIN_PASSWORD"
EOA
chmod 700 "$ASKPASS"
export GIT_ASKPASS=$ASKPASS GIT_TERMINAL_PROMPT=0 GOGS_ADMIN_PASSWORD

git clone -q "http://${GOGS_ADMIN_USER}@${PROXY_NAT_IP}:3000/${GOGS_ADMIN_USER}/${GOGS_REPO}.git" "$WORK/repo"
render "$FILES_DIR/values.yaml.tpl" \
  INSTANA_AGENT_KEY INSTANA_ENDPOINT_HOST INSTANA_ENDPOINT_PORT \
  PROXY_INT_IP CLUSTER_NAME ZONE_NAME > "$WORK/repo/values.yaml"
mkdir -p "$WORK/repo/hooks"
cp "$FILES_DIR"/hooks/*.yaml "$WORK/repo/hooks/"

cd "$WORK/repo"
git config user.name  "lab-bootstrap"
git config user.email "lab@lab.local"
git add -A
if git diff --cached --quiet; then
  info "Repo content is already up to date."
else
  git commit -q -m "Add Instana agent values and PostSync hook"
  git push -q origin "HEAD:${BRANCH}"
  info "Pushed values.yaml and hooks/ to ${BRANCH}."
fi
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------- register repo
log "5/6 Registering the repo in ArgoCD and creating the Application"
argocd repo add "$REPO_URL" --username "$GOGS_ADMIN_USER" --password "$GOGS_ADMIN_PASSWORD" \
  --insecure-skip-server-verification --upsert
argocd repo list

render "$FILES_DIR/instana-application.yaml.tpl" REPO_URL BRANCH > /tmp/instana-application.yaml
kubectl apply -f /tmp/instana-application.yaml
kubectl get application -n argocd

# ---------------------------------------------------------------- wait for the agent
log "6/6 Waiting for the Instana agent on vm-k3-git (a few minutes)"
agent_ready() {
  local n
  n=$($RK get ds instana-agent -n instana-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
  [[ ${n:-0} -ge 1 ]]
}
for attempt in $(seq 1 12); do
  agent_ready && break
  info "Attempt ${attempt}/12: agent not ready yet. Syncing and waiting 90 s..."
  # The first pass often leaves the app OutOfSync (the Operator is not ready yet). A second sync fixes it.
  argocd app sync instana-agent --timeout 120 >/dev/null 2>&1 || true
  sleep 90
done
agent_ready || die "The agent did not become ready. Run ./40-verify.sh and see the troubleshooting table in the README."

log "Done: the Instana agent is running on vm-k3-git."
info "Check Instana in 2 to 5 minutes for the cluster '${CLUSTER_NAME}'. Run ./40-verify.sh for a full check."

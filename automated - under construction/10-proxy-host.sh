#!/usr/bin/env bash
# Runs ON vm-proxy-git.
# Installs and configures: Squid, k3s, the isolation rule, ArgoCD and Gogs.
# Safe to re-run.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_vars
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ---------------------------------------------------------------- preflight
log "Preflight checks"
ip -br addr show "$INT_IFACE" | grep -q "$PROXY_INT_IP" \
  || die "$INT_IFACE does not have $PROXY_INT_IP. Finish the network setup first (README step 1.3)."
ip -br addr show "$NAT_IFACE" | grep -q "$PROXY_NAT_IP" \
  || die "$NAT_IFACE does not have $PROXY_NAT_IP. Check NAT_IFACE / PROXY_NAT_IP in vars.env."
curl -sfI --max-time 15 https://github.com >/dev/null \
  || die "vm-proxy-git has no internet access."
info "Network looks good."

# ---------------------------------------------------------------- packages
log "1/6 Installing packages"
dnf install -y squid podman tmux nftables git jq curl openssh-clients

# ---------------------------------------------------------------- squid
log "2/6 Configuring Squid"
[[ -f /etc/squid/squid.conf.orig ]] || cp /etc/squid/squid.conf /etc/squid/squid.conf.orig
install -m 644 "$FILES_DIR/squid.conf" /etc/squid/squid.conf
squid -k parse >/tmp/squid-parse.log 2>&1 || { cat /tmp/squid-parse.log; die "squid.conf has a syntax error."; }
systemctl enable --now squid
systemctl reload squid || systemctl restart squid
wait_for "Squid listening on 3128" 30 bash -c "ss -lnt | grep -q ':3128'"

# ---------------------------------------------------------------- k3s
log "3/6 Installing k3s (direct internet, no proxy)"
systemctl disable --now firewalld 2>/dev/null || true
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOC
node-ip: ${PROXY_NAT_IP}
flannel-iface: ${NAT_IFACE}
disable:
  - traefik
EOC

if ! systemctl is-active --quiet k3s; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_SELINUX_RPM=true sh -
else
  info "k3s is already running, skipping install."
fi
wait_for "k3s node Ready" 300 bash -c "kubectl get nodes --no-headers | grep -qw Ready"

if ! grep -qs 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml' /root/.bashrc; then
  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /root/.bashrc
fi

# ---------------------------------------------------------------- isolation
log "4/6 Blocking internet access for the internal network"
render "$FILES_DIR/nft-labiso.conf.tpl" INT_IFACE NAT_IFACE > /etc/nft-labiso.conf
install -m 644 "$FILES_DIR/lab-isolate.service" /etc/systemd/system/lab-isolate.service
systemctl daemon-reload
systemctl enable lab-isolate
systemctl restart lab-isolate
nft list table inet labiso >/dev/null || die "The isolation rule was not loaded."
info "Isolation rule active."

# ---------------------------------------------------------------- argocd
log "5/6 Installing ArgoCD"
kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
info "Waiting for ArgoCD pods (this can take a few minutes)..."
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"nodePort":30443}]}}'
wait_for "ArgoCD UI on https://${PROXY_NAT_IP}:30443" 120 curl -ksf -o /dev/null "https://${PROXY_NAT_IP}:30443"

# ---------------------------------------------------------------- gogs
log "6/6 Starting Gogs"
mkdir -p /opt/gogs/gogs/conf
APPINI=/opt/gogs/gogs/conf/app.ini
if [[ ! -f $APPINI ]]; then
  # Pre-seeding app.ini with INSTALL_LOCK=true skips Gogs' web installer.
  # shellcheck disable=SC2034  # used by render() via indirect expansion
  SECRET_KEY=$(openssl rand -hex 16)
  render "$FILES_DIR/gogs-app.ini.tpl" PROXY_NAT_IP SECRET_KEY > "$APPINI"
  info "Wrote $APPINI"
else
  info "$APPINI already exists, keeping it."
fi

if ! podman container exists gogs; then
  podman run -d --name gogs --restart=always \
    -p 3000:3000 -v /opt/gogs:/data:Z \
    docker.io/gogs/gogs:latest
else
  podman start gogs >/dev/null 2>&1 || true
fi
systemctl enable --now podman-restart.service
wait_for "Gogs on http://${PROXY_NAT_IP}:3000" 180 curl -sf -o /dev/null "http://${PROXY_NAT_IP}:3000/"

if [[ $(curl -s -o /dev/null -w '%{http_code}' "http://${PROXY_NAT_IP}:3000/api/v1/users/${GOGS_ADMIN_USER}") != 200 ]]; then
  info "Creating Gogs admin user '${GOGS_ADMIN_USER}'"
  podman exec -u git -w /app/gogs gogs ./gogs admin create-user \
    --name "$GOGS_ADMIN_USER" --password "$GOGS_ADMIN_PASSWORD" \
    --email "${GOGS_ADMIN_USER}@lab.local" --admin \
    || die "Could not create the Gogs admin user. See the 'Gogs' note in scripts/README.md."
else
  info "Gogs user '${GOGS_ADMIN_USER}' already exists."
fi

log "Done: proxy host is ready."
info "ArgoCD UI: https://${PROXY_NAT_IP}:30443   Gogs: http://${PROXY_NAT_IP}:3000"

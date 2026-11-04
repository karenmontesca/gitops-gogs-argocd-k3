#!/usr/bin/env bash
# Runs ON vm-k3-git (run-all.sh copies it there and starts it over SSH).
# Installs k3s behind the Squid proxy. Safe to re-run.
#
# Needs these environment variables: K3_IP, PROXY_INT_IP, K3_IFACE
set -euo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
: "${K3_IP:?K3_IP is not set}" "${PROXY_INT_IP:?PROXY_INT_IP is not set}" "${K3_IFACE:?K3_IFACE is not set}"

PROXY_URL="http://${PROXY_INT_IP}:3128"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log "Checking the proxy"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -x "$PROXY_URL" -I https://github.com || true)
[[ $code =~ ^(200|301|302)$ ]] \
  || die "Could not reach github.com through $PROXY_URL (HTTP '$code'). Is Squid running on vm-proxy-git?"
info "Proxy works (github.com -> HTTP $code)."
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
  warn "vm-k3-git can reach the internet DIRECTLY. The isolation rule on vm-proxy-git is not working."
fi

log "Preparing the host"
systemctl disable --now firewalld 2>/dev/null || true
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOC
node-ip: ${K3_IP}
flannel-iface: ${K3_IFACE}
tls-san:
  - ${K3_IP}
disable:
  - traefik
EOC

log "Installing k3s through the proxy"
export HTTP_PROXY=$PROXY_URL HTTPS_PROXY=$PROXY_URL
export NO_PROXY="localhost,127.0.0.1,${K3_IP%.*}.0/24,10.42.0.0/16,10.43.0.0/16,.svc,.cluster.local"

if ! systemctl is-active --quiet k3s; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_SELINUX_RPM=true sh -
else
  info "k3s is already running, skipping install."
fi

# k3s and its containerd must keep using the proxy after a reboot.
ENVF=/etc/systemd/system/k3s.service.env
if ! grep -qs 'HTTPS_PROXY' "$ENVF"; then
  warn "$ENVF has no proxy settings, writing them."
  cat > "$ENVF" <<EOC
HTTP_PROXY=${HTTP_PROXY}
HTTPS_PROXY=${HTTPS_PROXY}
NO_PROXY=${NO_PROXY}
EOC
  chmod 0600 "$ENVF"
  systemctl restart k3s
fi

log "Waiting for the node to be Ready"
start=$SECONDS
until kubectl get nodes --no-headers 2>/dev/null | grep -qw Ready; do
  (( SECONDS - start > 300 )) && die "The node did not become Ready in 5 minutes. Check: journalctl -u k3s"
  sleep 5
done
kubectl get nodes

log "Waiting for CoreDNS (proves that images can be pulled through Squid)"
if ! kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=420s; then
  die "CoreDNS did not start. Probably a blocked domain: on vm-proxy-git run  grep TCP_DENIED /var/log/squid/access.log"
fi

log "Done: vm-k3-git is ready."

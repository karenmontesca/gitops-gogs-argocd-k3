# GitOps for an Isolated Host: Instana Agent + ArgoCD + Gogs + Squid

A hands-on lab that shows how to install and manage a monitoring agent on a server that **has no internet access**, using GitOps and a forward proxy.

I built this lab because a client had exactly this layout: a self-hosted Git server (Gogs), a host with no direct internet, and everything going out through a proxy. I couldn't find a single guide that put all the pieces together, so I wrote the one I wish I'd had. If you're learning this on your own and don't know where to start, this is for you.

> **Lab only.** This is a learning environment, not a production design. See [Security notes](#14-security-notes) before reusing anything.

---

## What you will learn

- How to run a host with **no internet** that can still reach a short list of approved domains through **Squid** (an allow-list proxy).
- How to set up **k3s** (lightweight Kubernetes) on both a connected and a disconnected machine.
- How **GitOps** works: you edit a file in Git, and **ArgoCD** applies the change to a remote cluster for you.
- How to host your own Git server (**Gogs**) so the whole flow stays local.
- How to deploy the **Instana agent** through its official Helm chart, and restart it automatically when the config changes.
- How to troubleshoot blocked traffic by reading the proxy log. This is the skill that will save you the most time.

## Who this is for

Anyone who is comfortable with a Linux terminal but new to Kubernetes, ArgoCD, or proxies. Every step explains *what* it does and *why*.

You will need: a hypervisor (VMware or VirtualBox), an ISO of AlmaLinux or Rocky Linux 9 or 10, and an Instana tenant with a valid **agent key** and **endpoint** (in Instana: *Settings > Agents > Installation > Kubernetes*). Plan for an afternoon.

---

## The scenario

Many companies run servers that cannot reach the internet directly. They can only go out through a proxy that allows specific domains. That makes installing software hard, because images, charts, and agents all need to be downloaded from somewhere.

This lab reproduces that situation with two virtual machines:

```
Your PC ──► vm-proxy-git (NAT 192.168.189.150 / internal 10.10.10.40)
           ├─ Squid   :3128   exit proxy (allow-list)
           ├─ Gogs    :3000   your local "GitHub"
           └─ k3s + ArgoCD :30443   has direct internet
                 │ Kubernetes API :6443 (internal network)
                 ▼
          vm-k3-git (10.10.10.60, NO internet)
           └─ k3s + Instana agent, reaches the outside only through Squid
```

| Component | Runs on | Goes through Squid? |
| --- | --- | --- |
| Squid | vm-proxy-git | No |
| Gogs (configuration repo) | vm-proxy-git | No |
| ArgoCD and its repo-server | vm-proxy-git | No (it already has internet) |
| k3s, container images, Instana agent | vm-k3-git | **Yes, everything** |

### How a change travels

1. You edit `values.yaml` in Gogs and commit.
2. ArgoCD detects the commit, downloads the official Instana Helm chart, and combines it with your `values.yaml`.
3. ArgoCD applies the result on vm-k3-git through the Kubernetes API (port 6443). **You never install the agent by hand.**
4. k3s on vm-k3-git pulls the images through Squid, and the agent sends its data to Instana through Squid as well.
5. A hook restarts the agent so it picks up the new configuration.

---

## Lab values used in this guide

The guide uses these example addresses everywhere. If yours differ, replace them consistently.

| Name | Example value | Meaning |
| --- | --- | --- |
| `PROXY_NAT_IP` | `192.168.189.150` | vm-proxy-git, internet-facing adapter (NAT) |
| `PROXY_INT_IP` | `10.10.10.40` | vm-proxy-git, internal adapter. Also the gateway and proxy address for vm-k3-git |
| `K3_IP` | `10.10.10.60` | vm-k3-git |

Interface names (`ens160`, `ens224`) can differ on your VMs. Check them with `nmcli device status`.

Every section starts with **Run on:** so you always know which machine to type in. Run everything as `root` unless stated otherwise.

### VM sizing

| VM | RAM | CPU | Disk | Network |
| --- | --- | --- | --- | --- |
| vm-proxy-git | 4 GB | 2 | 30 GB | Adapter 1: NAT. Adapter 2: LAN segment `labnet` |
| vm-k3-git | 4 GB | 2 | 30 GB | One adapter: LAN segment `labnet` |

| VM | Interface | IP | Gateway | DNS |
| --- | --- | --- | --- | --- |
| vm-proxy-git | ens160 (NAT) | 192.168.189.150/24 | 192.168.189.2 | 192.168.189.2 and 8.8.8.8 |
| vm-proxy-git | ens224 (internal) | 10.10.10.40/24 | none | none |
| vm-k3-git | ens160 (internal) | 10.10.10.60/24 | 10.10.10.40 | none |

---

## Step 1. Prepare vm-proxy-git

### 1.1 Static IP with internet

**Run on:** vm-proxy-git

Create the VM with only the NAT adapter for now. These commands make the IP static (so it survives reboots), set the gateway and DNS, and rename the server.

```bash
nmcli connection modify ens160 ipv4.addresses 192.168.189.150/24
nmcli connection modify ens160 ipv4.gateway 192.168.189.2
nmcli connection modify ens160 ipv4.dns '192.168.189.2 8.8.8.8'
nmcli connection modify ens160 ipv4.method manual
nmcli connection up ens160
hostnamectl set-hostname vm-proxy-git
systemctl reboot
```

After it reboots, log back in and confirm internet access:

```bash
ping -c 2 8.8.8.8
```

### 1.2 Install packages

**Run on:** vm-proxy-git

Squid is the proxy, Podman will run Gogs, tmux keeps your sessions alive, and nftables will isolate the internal network later (step 4.2). Install everything now, because vm-k3-git will not be able to install anything itself.

```bash
dnf install -y squid podman tmux nftables
```

### 1.3 Add the internal network

**Run on:** vm-proxy-git

Shut the VM down, add a second network adapter on the LAN segment `labnet`, power it on, and run:

```bash
nmcli device status

nmcli connection add type ethernet ifname ens224 con-name lab-interna \
  ipv4.addresses 10.10.10.40/24 ipv4.method manual ipv4.never-default yes

nmcli connection up lab-interna
ip -br addr
```

This creates the network that can see vm-k3-git. `never-default` stops this network from being used as a route to the internet.

---

## Step 2. Prepare vm-k3-git

### 2.1 Static IP with no internet

**Run on:** vm-k3-git (from the VM console)

Create the VM with a single adapter, attached to `labnet`.

```bash
nmcli connection modify ens160 ipv4.addresses 10.10.10.60/24
nmcli connection modify ens160 ipv4.gateway 10.10.10.40
nmcli connection modify ens160 ipv4.method manual
nmcli connection up ens160
hostnamectl set-hostname vm-k3-git
```

The gateway is vm-proxy-git's internal IP. k3s refuses to start without a default route (you would get `no default routes found`), so we give it one. Step 4.2 makes sure that route can never actually reach the internet.

### 2.2 Verify the network

**Run on:** vm-k3-git

```bash
ping -c 2 10.10.10.40     # must respond
ping -c 2 8.8.8.8         # must fail
```

If the first ping fails, the VMs are probably not on the same LAN segment.

---

## Step 3. Squid on vm-proxy-git

### 3.1 Configure

**Run on:** vm-proxy-git

```bash
cp /etc/squid/squid.conf /etc/squid/squid.conf.orig
vi /etc/squid/squid.conf
```

Delete everything and paste the following. Save with `Esc`, then `:wq`.

```
acl localnet src 10.10.10.0/24

acl allowed_domains dstdomain .instana.io
acl allowed_domains dstdomain .icr.io
acl allowed_domains dstdomain .k3s.io
acl allowed_domains dstdomain .rancher.io
acl allowed_domains dstdomain .docker.io
acl allowed_domains dstdomain .docker.com
acl allowed_domains dstdomain .quay.io
acl allowed_domains dstdomain ghcr.io
acl allowed_domains dstdomain registry.k8s.io
acl allowed_domains dstdomain .ecr.aws
acl allowed_domains dstdomain .cloudfront.net
acl allowed_domains dstdomain .github.com
acl allowed_domains dstdomain .githubusercontent.com

acl SSL_ports port 443
acl Safe_ports port 80 443
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localnet allowed_domains
http_access deny all

http_port 3128
```

What it means:

- `acl localnet` defines **who** can use the proxy: only the internal network.
- `acl allowed_domains` defines **where** they can go. A leading dot (`.instana.io`) includes every subdomain.
- `http_access` rules are evaluated in order. Anything not explicitly allowed is blocked (`deny all`).
- `http_port 3128` is the port Squid listens on.

### 3.2 Enable and test

**Run on:** vm-proxy-git

```bash
squid -k parse
systemctl enable --now squid
ss -lntp | grep 3128
```

`squid -k parse` checks the syntax without applying anything. `enable --now` starts Squid and keeps it enabled after reboots. A `Requiring client certificates` message during `parse` is informational.

**Run on:** vm-k3-git

```bash
curl -x http://10.10.10.40:3128 -I https://github.com      # must return 200
curl -x http://10.10.10.40:3128 -I https://www.google.com  # must fail with a 403 from the proxy
```

### 3.3 Your main diagnostic tool

Sooner or later a pod will get stuck in `ImagePullBackOff` and never become `Ready`. Almost always, the cause is that a domain it needs is blocked by Squid.

To find which one, on vm-proxy-git run:

```bash
tail -f /var/log/squid/access.log
```

- `TCP_TUNNEL/200` means the request was **allowed**.
- `TCP_DENIED/403` means the request was **blocked**.

Look for `TCP_DENIED`, add that domain to `squid.conf`, then apply it:

```bash
squid -k parse
systemctl reload squid
```

---

## Step 4. k3s on vm-proxy-git (the cluster that runs ArgoCD)

ArgoCD needs a Kubernetes cluster to live in. vm-proxy-git has direct internet access, so no proxy configuration is needed here.

### 4.1 Install k3s

**Run on:** vm-proxy-git

```bash
systemctl disable --now firewalld
setenforce 0
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
node-ip: 192.168.189.150
flannel-iface: ens160
disable:
  - traefik
EOF

curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_SELINUX_RPM=true sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```

What this does:

- The first three lines turn off the firewall and set SELinux to permissive permanently (lab only).
- `config.yaml` tells k3s which IP and interface to use. This matters because this VM has two network adapters. It also disables Traefik, which we don't need.
- The `curl` line installs k3s. `INSTALL_K3S_SKIP_SELINUX_RPM` skips an SELinux package that isn't needed in permissive mode.
- `kubectl get nodes` should show the node as `Ready`.

Tip: add `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` to `~/.bashrc` so you don't have to retype it in every new session.

### 4.2 Keep vm-k3-git isolated

**Run on:** vm-proxy-git

k3s turns on packet forwarding on vm-proxy-git, and vm-k3-git uses this VM as its gateway. Without a rule, vm-k3-git could reach the internet through it. This rule blocks that path explicitly:

```bash
cat > /etc/nft-labiso.conf <<'EOF'
table inet labiso
delete table inet labiso
table inet labiso {
  chain fwd {
    type filter hook forward priority -10; policy accept;
    iifname "ens224" oifname "ens160" drop
  }
}
EOF

cat > /etc/systemd/system/lab-isolate.service <<'EOF'
[Unit]
Description=Block internet access from the internal network
After=network-online.target k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nft-labiso.conf

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now lab-isolate
nft list table inet labiso
```

What it does: the rule drops traffic that enters from the internal network (`ens224`) and tries to leave toward the internet (`ens160`). The service reloads the rule after every reboot. It does not affect Squid or the ArgoCD pods, which leave through a different path. Adjust the interface names if yours differ.

---

## Step 5. ArgoCD on vm-proxy-git

### 5.1 Install

**Run on:** vm-proxy-git

```bash
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w
```

Wait until all pods are `Running` (press `Ctrl+C` to leave the watch). `--server-side` matters: without it, some CRDs are too large to apply and a pod such as `applicationset-controller` can end up in `CrashLoopBackOff`.

### 5.2 Expose it with a NodePort

**Run on:** vm-proxy-git

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"nodePort":30443}]}}'
kubectl get svc argocd-server -n argocd
curl -k -I https://192.168.189.150:30443
```

By default `argocd-server` is a `ClusterIP` service, which gives `connection refused` on port 30443. This patch turns it into a `NodePort` and opens port 30443 on the VM's IP. The service should show `443:30443/TCP`, and `curl` should answer `200`.

### 5.3 Get the admin password and log in

**Run on:** vm-proxy-git

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

From your PC, open `https://192.168.189.150:30443`. The user is `admin`, and the password is what the command printed.

---

## Step 6. Gogs on vm-proxy-git

**Run on:** vm-proxy-git

```bash
mkdir -p /opt/gogs
podman run -d --name gogs --restart=always \
  -p 3000:3000 -v /opt/gogs:/data:Z \
  docker.io/gogs/gogs:latest
systemctl enable --now podman-restart.service
```

Gogs is a lightweight Git server. It acts as your local "GitHub". The container stores its data in `/opt/gogs`, publishes port 3000, and restarts itself (`--restart=always` plus `podman-restart.service`).

Open `http://192.168.189.150:3000` and complete the initial setup:

- **Database Type:** SQLite3
- **Domain:** `192.168.189.150`
- **HTTP Port:** `3000`
- **Application URL:** `http://192.168.189.150:3000/`
- **Admin Account:** create one called `root`

Then create a **private** repository named `instana-gitops-lab`, initialized with a README (so the default branch exists).

---

## Step 7. k3s on vm-k3-git, behind the proxy

**Run on:** vm-k3-git

```bash
systemctl disable --now firewalld
setenforce 0
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
node-ip: 10.10.10.60
flannel-iface: ens160
tls-san:
  - 10.10.10.60
disable:
  - traefik
EOF

export HTTP_PROXY=http://10.10.10.40:3128
export HTTPS_PROXY=http://10.10.10.40:3128
export NO_PROXY=localhost,127.0.0.1,10.10.10.0/24,10.42.0.0/16,10.43.0.0/16,.svc,.cluster.local

curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_SELINUX_RPM=true sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
cat /etc/systemd/system/k3s.service.env
```

What this does:

- `HTTP_PROXY` and `HTTPS_PROXY` make the k3s download, and later every image pull, go through Squid (`10.10.10.40:3128`). The IP must be the **proxy VM's** internal IP.
- `NO_PROXY` keeps internal traffic (node network, pod network, service network) from going to the proxy.
- The installer saves these variables in `k3s.service.env`, so k3s and its containerd keep using the proxy after a reboot. If that file comes out empty, create it with the three variables and run `systemctl restart k3s`.
- `tls-san` makes the Kubernetes API certificate valid for `10.10.10.60`, which is the address ArgoCD will use. Without it you get an `x509` error when registering the cluster.

---

## Step 8. Register vm-k3-git in ArgoCD

Everything here runs on vm-proxy-git, except step 8.2.

### 8.1 Bring the kubeconfig over from vm-k3-git

**Run on:** vm-proxy-git

```bash
scp root@10.10.10.60:/etc/rancher/k3s/k3s.yaml /root/vmk8s.yaml
sed -i 's#127.0.0.1#10.10.10.60#' /root/vmk8s.yaml
kubectl --kubeconfig /root/vmk8s.yaml get nodes
```

`scp` downloads the remote cluster's credential file (this needs SSH login as `root` to be allowed on vm-k3-git). The `sed` replaces `127.0.0.1`, which only works inside vm-k3-git, with its internal IP.

### 8.2 Only if it fails with x509 (on vm-k3-git)

**Run on:** vm-k3-git

If the error says the certificate is not valid for `10.10.10.60`, the `tls-san` setting from step 7 is missing:

```bash
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
node-ip: 10.10.10.60
flannel-iface: ens160
tls-san:
  - 10.10.10.60
disable:
  - traefik
EOF
rm -f /var/lib/rancher/k3s/server/tls/dynamic-cert.json
systemctl restart k3s
```

This deletes the generated certificate and forces k3s to create a new one that includes that IP. Wait a minute, then repeat step 8.1.

### 8.3 Install the ArgoCD CLI and log in

**Run on:** vm-proxy-git

```bash
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
ARGOPW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
argocd login 192.168.189.150:30443 --username admin --password "$ARGOPW" --insecure
```

This downloads the CLI, reads the initial admin password into a variable, and logs in. You should see `'admin:login' logged in successfully`.

Remember: port 3000 is Gogs, not ArgoCD.

### 8.4 Register the remote cluster

**Run on:** vm-proxy-git

```bash
kubectl --kubeconfig /root/vmk8s.yaml config get-contexts
argocd cluster add default --kubeconfig /root/vmk8s.yaml --name vm-k8s --yes
argocd cluster list
```

`cluster add` creates a service account (`argocd-manager`) inside vm-k3-git and stores its credentials in ArgoCD. That is how ArgoCD can create resources there without you doing it manually. (`default` is the context name that k3s uses.)

---

## Step 9. Repository content in Gogs

In Gogs, open the repository and use **New file**. If you type `hooks/` at the start of the file name, Gogs creates the folder. Choose *Commit directly to the master branch* and click **Commit New File** for each file.

### 9.1 `values.yaml`

Goes in the root of the repository. This is the agent's configuration.

```yaml
agent:
  key: 'YOUR_AGENT_KEY'
  downloadKey: 'YOUR_AGENT_KEY'
  endpointHost: 'YOUR_INSTANA_ENDPOINT'   # copy it from your tenant, e.g. ingress-xxxx-saas.instana.io
  endpointPort: 443
  proxyHost: 10.10.10.40
  proxyPort: 3128
  proxyProtocol: 'HTTP'
  proxyUseDNS: true
  configuration_yaml: |
    com.instana.plugin.host:
      tags:
        - 'lab'

cluster:
  name: 'instana-lab'

zone:
  name: 'gogs-instana-lab-zone'
```

Notes:

- Get the key and endpoint from *Settings > Agents > Installation > Kubernetes* in Instana.
- `proxyUseDNS: true` lets the proxy resolve domain names. This matters because vm-k3-git has no DNS of its own.
- **Never commit your real agent key to a public repository.**

### 9.2 The PostSync hook (`hooks/` folder)

A pod reads its configuration only when it starts. This job runs after every successful sync and restarts the agent so it picks up the new configuration. It takes four files.

`hooks/serviceaccount.yaml` (the job's identity):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-instana-hook
  namespace: instana-agent
```

`hooks/role.yaml` (permission only to read and patch DaemonSets):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: restart-daemonset
  namespace: instana-agent
rules:
  - apiGroups: ['apps']
    resources: ['daemonsets']
    verbs: ['get', 'list', 'patch']
```

`hooks/rolebinding.yaml` (connects the identity to the role):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-instana-hook-binding
  namespace: instana-agent
subjects:
  - kind: ServiceAccount
    name: argocd-instana-hook
    namespace: instana-agent
roleRef:
  kind: Role
  name: restart-daemonset
  apiGroup: rbac.authorization.k8s.io
```

`hooks/job.yaml` (the job that restarts the agent):

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: restart-instana-agent
  namespace: instana-agent
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
spec:
  backoffLimit: 1
  template:
    spec:
      serviceAccountName: argocd-instana-hook
      restartPolicy: Never
      containers:
        - name: kubectl
          image: rancher/kubectl:v1.30.0
          args:
            - rollout
            - restart
            - daemonset
            - instana-agent
            - -n
            - instana-agent
```

---

## Step 10. Connect the repo and create the Application

### 10.1 Register the repo in ArgoCD

**Run on:** vm-proxy-git

```bash
argocd repo add http://192.168.189.150:3000/root/instana-gitops-lab.git \
  --username root --password 'YOUR_GOGS_PASSWORD' --insecure-skip-server-verification
argocd repo list
```

This gives ArgoCD the credentials to read your Gogs repository. (The password ends up in your shell history. Fine for a lab, not for anything real.)

### 10.2 Create the Application

**Run on:** vm-proxy-git

Create `instana-application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: instana-agent
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://agents.instana.io/helm
      chart: instana-agent
      targetRevision: '*'
      helm:
        valueFiles:
          - $values/values.yaml
    - repoURL: http://192.168.189.150:3000/root/instana-gitops-lab.git
      targetRevision: master
      ref: values
    - repoURL: http://192.168.189.150:3000/root/instana-gitops-lab.git
      targetRevision: master
      path: hooks
  destination:
    name: vm-k8s
    namespace: instana-agent
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - SkipDryRunOnMissingResource=true
```

What each part does:

- **Source 1:** the official Instana chart (the "recipe"). ArgoCD downloads it from `agents.instana.io` using its direct internet access, and uses your `values.yaml` as input.
- **Source 2** (`ref: values`): your Gogs repo, where `values.yaml` comes from.
- **Source 3** (`path: hooks`): the folder with the hook. Without this source, ArgoCD ignores those files.
- **Destination:** `name: vm-k8s` is the remote cluster you registered in step 8.4. The Application lives on vm-proxy-git but applies to vm-k3-git.
- **Automated sync:** applies changes by itself. `prune` deletes what you remove from the repo, and `selfHeal` reverts manual changes.
- **SkipDryRunOnMissingResource:** avoids an ordering failure when the chart creates the `InstanaAgent` resource before its definition exists.

The `repoURL` of the last two sources must be **identical** to the one you registered in step 10.1. (Multiple sources need ArgoCD 2.6 or newer.)

Apply it:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl apply -f instana-application.yaml
kubectl get application -n argocd
```

This is the moment the agent gets installed. You never log in to vm-k3-git to install it.

---

## Step 11. Verify and test GitOps

**Run on:** vm-proxy-git

Watch the pods in the remote cluster:

```bash
kubectl --kubeconfig /root/vmk8s.yaml get pods -n instana-agent -w
```

First the controller (the Operator) comes up. Then, after a couple of minutes, the agent and the `k8sensor` pods appear. A plain `kubectl get pods` without `--kubeconfig` looks at the wrong cluster and finds nothing.

If the Application shows `OutOfSync` but `Healthy`, or the first sync reports the hook as failed, sync again (`argocd app sync instana-agent`). On the second pass the Operator is ready and the agent resources exist.

### Check three things

1. On vm-proxy-git, `tail -f /var/log/squid/access.log` shows `TCP_TUNNEL/200` from `10.10.10.60` toward `.instana.io` and `icr.io`.
2. In Instana, the cluster `instana-lab` and the vm-k3-git host appear (give it 2 to 5 minutes).
3. From vm-k3-git, `ping -c 2 8.8.8.8` still fails. The isolation is intact.

### End-to-end GitOps test

1. In Gogs, edit `values.yaml` (for example, change `zone.name`) and commit.
2. ArgoCD detects it in about 3 minutes, or force it with `argocd app get instana-agent --refresh`.
3. The `restart-instana-agent` Job appears briefly and the agent pod is recreated.
4. Instana shows the new zone.

If that works, you have a complete GitOps pipeline into an isolated host.

---

## 12. Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `no default routes found` when starting k3s | vm-k3-git has no gateway | `nmcli connection modify ens160 ipv4.gateway 10.10.10.40`, then restart k3s |
| `status=203/EXEC` on k3s after a reboot | SELinux went back to Enforcing | `setenforce 0` and check `/etc/selinux/config` |
| `connection refused` on port 30443 | `argocd-server` is still ClusterIP | Step 5.2 |
| `gRPC connection not ready` on login | Wrong port (3000 is Gogs) | Use `192.168.189.150:30443` and user `admin` |
| `x509` when registering vm-k3-git | Missing `tls-san` | Step 8.2 |
| Timeout when registering vm-k3-git | No connectivity to port 6443 | `nc -zv 10.10.10.60 6443` from vm-proxy-git, and check the nft rule |
| `ImagePullBackOff` on vm-k3-git | Domain blocked in Squid | `grep TCP_DENIED /var/log/squid/access.log`, then add the domain |
| Pods `Running` but nothing in Instana | `proxyHost` points to the wrong IP | It must be `10.10.10.40` (vm-proxy-git) |
| `unable to resolve 'master'` | Gogs' default branch has another name | Adjust `targetRevision` |
| `InstanaAgent is invalid` | Wrong data type in a field | Fix `values.yaml`; if it mentions strings, quote the ports |
| k8sensor `Pending`, or controller restarting | Not enough RAM on vm-k3-git | Give it 4 GB or more |
| `applicationset-controller` in CrashLoopBackOff | CRD not installed by a normal apply | Reinstall with `--server-side` (step 5.1), or scale that deployment to 0 |

**Golden rule:** if something doesn't work, look at `/var/log/squid/access.log`. It tells you whether the request reached the proxy and whether it was allowed.

---

## 13. Shutting down and starting up

Shut down vm-k3-git first, then vm-proxy-git (`shutdown -h now`), or suspend both from the hypervisor.

When powering on, start **vm-proxy-git first** (Squid, Gogs, k3s, and ArgoCD), then vm-k3-git, which takes 3 to 5 minutes to bring its pods up.

Check that everything survived the reboot:

- `getenforce` says `Permissive` on both VMs.
- `systemctl is-enabled k3s squid lab-isolate` says `enabled` (on vm-proxy-git).
- `podman ps` shows Gogs running (on vm-proxy-git).
- `ip route` on vm-k3-git shows the gateway `10.10.10.40`.

---

## 14. Security notes

- The agent key sits in plain text in the repo. That is acceptable in a lab, but in production use a Kubernetes Secret. If you ever pasted a real key in a chat, a document, or a public repo, regenerate it in Instana.
- Firewalld and SELinux are relaxed for the lab only.
- Gogs serves plain HTTP with no TLS. Use it only on the lab network.
- Squid allows only the listed domains. Review the list from time to time.
- If vm-proxy-git goes down, the agent loses its connection to Instana and ArgoCD stops syncing. Production setups use several proxies.
- Change ArgoCD's initial `admin` password from the UI (*User Info > Update Password*).

---

## 15. Glossary

| Term | Meaning |
| --- | --- |
| Forward proxy | An intermediary server that goes out to the internet on behalf of other machines |
| Squid | Open source HTTP/HTTPS proxy, the de facto standard |
| ACL | Access rule: who can use the proxy and where they can go |
| NO_PROXY | Destinations that must bypass the proxy (internal traffic) |
| k3s | Lightweight Kubernetes distribution |
| Gogs | Lightweight self-hosted Git server, a local alternative to GitHub |
| GitOps | Managing infrastructure by committing the desired state to Git and letting a tool apply it |
| ArgoCD | GitOps controller that syncs Git with a cluster |
| Application | ArgoCD object that says which repo to watch and where to apply it |
| Sync | Applying to the cluster what the repo says |
| OutOfSync | The cluster doesn't match the repo |
| Hook (PostSync) | A job ArgoCD runs after every successful sync |
| NodePort | Kubernetes service type that opens a fixed port on the node's IP |
| Operator | Controller that manages the lifecycle of the Instana agent |

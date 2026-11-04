# Fast path: automate the lab with shell scripts

These scripts do everything in the [main README](../README.md) from **step 3 onward** (Squid, k3s, isolation, ArgoCD, Gogs, cluster registration, the repo content, the Application).

Doing the lab by hand once is the best way to understand each piece, so keep the manual guide as your learning path. Use the scripts when you want to rebuild the lab quickly, or to see the whole flow in one place.

## What you must do first (not automated)

1. Create the two VMs in your hypervisor (sizing in the main README).
2. Put them on the right networks and give them static IPs: main README **steps 1.1 to 2.2**. When `ping 10.10.10.40` works from vm-k3-git, you are ready.
3. Make sure `root` can log in over SSH to vm-k3-git (the scripts use SSH to configure it).

## How to run

On **vm-proxy-git**, as root:

```bash
dnf install -y git tmux
git clone <this repository> && cd <repository>/scripts

cp vars.env.example vars.env
vi vars.env                  # fill in your Instana key, endpoint and Gogs password

tmux new -s lab              # so an SSH drop doesn't kill the run
chmod +x *.sh               # only needed if "Permission denied" shows up
./run-all.sh
```

`run-all.sh` asks for the vm-k3-git root password **once** (to copy an SSH key), then configures both machines. It ends by running `40-verify.sh`.

## What each script does

| Script | Runs on | What it does |
| --- | --- | --- |
| `run-all.sh` | vm-proxy-git | Runs everything below in order and handles the SSH key |
| `10-proxy-host.sh` | vm-proxy-git | Packages, Squid, k3s, the isolation rule, ArgoCD (NodePort 30443), Gogs with its admin user |
| `20-k3-host.sh` | vm-k3-git | k3s behind the proxy. Copied and started over SSH by `run-all.sh` |
| `30-deploy.sh` | vm-proxy-git | Registers vm-k3-git in ArgoCD, creates the Gogs repo and pushes `values.yaml` and `hooks/`, creates the Application, waits for the agent |
| `40-verify.sh` | vm-proxy-git | Read-only checks: app status, pods, Squid log, isolation |
| `lib.sh` | n/a | Shared helpers |
| `files/` | n/a | Config files and templates the scripts install (see below) |

You can also run the numbered scripts one at a time. If you do, run `20-k3-host.sh` on vm-k3-git with `K3_IP`, `PROXY_INT_IP` and `K3_IFACE` set as environment variables.

## The `files/` folder

Everything the scripts install lives here as a normal file, so you can read it, edit it, or copy it into the manual steps:

- `squid.conf`: the domain allow-list. **This is the file you will edit most.**
- `values.yaml.tpl`, `instana-application.yaml.tpl`, `nft-labiso.conf.tpl`, `gogs-app.ini.tpl`: templates. `@@NAME@@` placeholders are filled from `vars.env`.
- `hooks/`: the PostSync hook that restarts the agent after each sync.
- `lab-isolate.service`: re-applies the isolation rule after reboots.

## Safe to re-run

Every script checks what already exists (installed k3s, existing Gogs user, registered cluster, existing repo files) and skips it. If a run fails, fix the cause and run it again.

## Notes and caveats

- **Secrets:** `vars.env` holds your agent key and passwords and is in `.gitignore`. Never commit it. Wrap values in single quotes if they contain special characters.
- **Gogs:** the web installer is skipped by pre-seeding `app.ini` with `INSTALL_LOCK = true`, and the admin user is created with Gogs' own CLI inside the container. If that step fails with a newer Gogs image, create the admin by hand (stop the container, remove `/opt/gogs/gogs/conf/app.ini` and use the web installer as in the main README), then re-run `10-proxy-host.sh`.
- **First sync:** the first ArgoCD sync often leaves the app `OutOfSync` because the Operator isn't ready yet. `30-deploy.sh` triggers extra syncs on its own while it waits.
- **Stuck on `ImagePullBackOff`?** A domain is probably blocked. The scripts print the same hint the main README gives: `grep TCP_DENIED /var/log/squid/access.log`, add the domain to `files/squid.conf`, and re-run `10-proxy-host.sh`.
- **Assumptions:** the internal network is a `/24`, and the interface names are the ones in `vars.env`.
- **Lab only:** these scripts disable firewalld, set SELinux to permissive and use plain HTTP. See the security notes in the main README.

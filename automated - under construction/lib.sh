#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts, not run directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # used by the scripts that source this file
FILES_DIR="$SCRIPT_DIR/files"

# Bash 5.2 treats '&' specially in ${var//a/b}; turn that off so values are literal.
shopt -u patsub_replacement 2>/dev/null || true

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run this script as root."; }

# Load vars.env and make sure the required values are filled in.
load_vars() {
  local f="${VARS_FILE:-$SCRIPT_DIR/vars.env}"
  [[ -f $f ]] || die "Missing $f. Copy vars.env.example to vars.env and fill it in."
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a

  local v missing=()
  for v in PROXY_NAT_IP PROXY_INT_IP K3_IP NAT_IFACE INT_IFACE K3_IFACE \
           INSTANA_AGENT_KEY INSTANA_ENDPOINT_HOST \
           GOGS_ADMIN_USER GOGS_ADMIN_PASSWORD GOGS_REPO; do
    [[ -n ${!v:-} ]] || missing+=("$v")
  done
  ((${#missing[@]} == 0)) || die "Fill in these values in vars.env: ${missing[*]}"

  INSTANA_ENDPOINT_PORT=${INSTANA_ENDPOINT_PORT:-443}
  CLUSTER_NAME=${CLUSTER_NAME:-instana-lab}
  ZONE_NAME=${ZONE_NAME:-gogs-instana-lab-zone}
  export INSTANA_ENDPOINT_PORT CLUSTER_NAME ZONE_NAME
}

# wait_for "description" timeout_seconds command [args...]
wait_for() {
  local desc=$1 timeout=$2
  shift 2
  local start=$SECONDS
  info "Waiting for: $desc"
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start > timeout )) && die "Timed out after ${timeout}s waiting for: $desc"
    sleep 5
  done
  info "OK: $desc"
}

# render TEMPLATE VAR1 VAR2 ...  -> prints the template with @@VAR@@ replaced by $VAR
render() {
  local content name
  content=$(<"$1")
  shift
  for name in "$@"; do
    content=${content//@@${name}@@/${!name}}
  done
  printf '%s\n' "$content"
}

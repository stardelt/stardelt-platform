#!/usr/bin/env bash
# Bootstrap a single-node k3s dev cluster on a home host.
#
# Run once, as root:
#   sudo bash dev/home-k3s/install-k3s.sh
#
# It is idempotent: a second run reinstalls the same k3s version with the same
# flags, re-checks the kernel settings and leaves an existing cluster's data
# alone (/var/lib/rancher/k3s is never touched).
#
# What it does NOT do: ingress, cert-manager, DNS or the stardelt install —
# those are unprivileged `kubectl`/`helm` steps (see README.md in this
# directory). Nothing here opens a firewall port to the internet; that is the
# router's job.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.37.1+k3s1}"   # same pin as dev/hetzner-k3s
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.37.1}"
HELM_VERSION="${HELM_VERSION:-v3.18.4}"
GH_VERSION="${GH_VERSION:-2.102.0}"

# The login user that gets the kubeconfig and the cluster-admin rights.
OWNER_USER="${OWNER_USER:-${SUDO_USER:-}}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"

log() { printf '\n\033[1;36m› %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }

[ "${EUID}" -eq 0 ] || { echo "run me with sudo: sudo bash $0" >&2; exit 1; }
[ -n "$OWNER_USER" ] && id "$OWNER_USER" >/dev/null 2>&1 || {
  echo "cannot resolve the login user (set OWNER_USER=<name>)" >&2; exit 1; }

OWNER_HOME="$(getent passwd "$OWNER_USER" | cut -d: -f6)"

# --- 1. host facts ---------------------------------------------------------
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) warn "expected ubuntu/debian, found '${ID:-unknown}' — continuing anyway" ;;
esac

LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
[ -n "$LAN_IP" ] || { echo "cannot determine the LAN IPv4 address" >&2; exit 1; }

log "host: $(hostname -s)  user: $OWNER_USER  LAN: $LAN_IP  tailscale: ${TS_IP:-none}"
log "k3s $K3S_VERSION · kubectl $KUBECTL_VERSION · helm $HELM_VERSION · gh $GH_VERSION"

# --- 2. base packages ------------------------------------------------------
log "base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl jq openssl gnupg apt-transport-https \
  apache2-utils shellcheck >/dev/null
# apache2-utils: `htpasswd` hashes the Trino service-account password
# (scripts/identity-bootstrap.sh refuses to run without it).
# shellcheck: `make lint` uses it when present.

# --- 3. swap off (kubelet's default is fail-swap-on) -----------------------
if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
  log "disabling swap"
  swapoff -a
  if grep -qE '^[^#].*\sswap\s' /etc/fstab; then
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
    sed -ri 's|^([^#].*\sswap\s.*)$|# disabled for k3s: \1|' /etc/fstab
  fi
else
  log "swap already off"
fi

# --- 4. kernel settings ----------------------------------------------------
log "kernel modules and sysctl"
cat >/etc/modules-load.d/k3s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/90-k3s.conf <<'EOF'
# k3s / Kubernetes
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
# JupyterHub spawns one process tree per user; the defaults (128) run out.
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 8192
EOF
sysctl --system >/dev/null

# --- 5. k3s ----------------------------------------------------------------
TLS_SANS=(--tls-san "$NODE_NAME" --tls-san "localhost" --tls-san "127.0.0.1"
          --tls-san "$LAN_IP")
if [ -n "$TS_IP" ]; then TLS_SANS+=(--tls-san "$TS_IP"); fi
# Optional extra names for the API certificate (e.g. the platform's base domain when
# kubectl is pointed at it). Never required for the platform itself.
# Comma separated; unset is the normal case and must not trip `set -u`.
if [ -n "${EXTRA_TLS_SANS:-}" ]; then
  IFS=',' read -ra _extra_sans <<<"$EXTRA_TLS_SANS"
  for san in "${_extra_sans[@]}"; do
    [ -n "$san" ] && TLS_SANS+=(--tls-san "$san")
  done
fi

installer_flags=(
  server
  --node-name "$NODE_NAME"
  # ingress-nginx runs host-network on :80/:443 (dev/playground); traefik would
  # fight it for the same ports and svclb would add a second binder.
  --disable traefik
  --disable servicelb
  "${TLS_SANS[@]}"
)

if systemctl is-active --quiet k3s; then
  log "k3s is running — reinstalling $K3S_VERSION with the same flags"
else
  log "installing k3s $K3S_VERSION"
fi
curl -sfL https://get.k3s.io \
  | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - "${installer_flags[@]}"

# --- 6. client tools -------------------------------------------------------
install_binary() {  # install_binary <url> <checksum-url|""> <dest>
  local url="$1" sumurl="$2" dest="$3" tmp
  tmp="$(mktemp)"
  curl -fsSL --retry 3 -o "$tmp" "$url"
  if [ -n "$sumurl" ]; then
    local want got
    want="$(curl -fsSL --retry 3 "$sumurl" | awk '{print $1; exit}')"
    got="$(sha256sum "$tmp" | awk '{print $1}')"
    [ "$want" = "$got" ] || { rm -f "$tmp"; echo "checksum mismatch for $url" >&2; exit 1; }
  fi
  install -m 0755 "$tmp" "$dest"
  rm -f "$tmp"
}

log "kubectl $KUBECTL_VERSION"
install_binary "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
  /usr/local/bin/kubectl

log "helm $HELM_VERSION"
helm_tmp="$(mktemp -d)"
helm_file="helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSL --retry 3 -o "$helm_tmp/$helm_file" "https://get.helm.sh/$helm_file"
( cd "$helm_tmp" && curl -fsSL -o helm.sha256 "https://get.helm.sh/$helm_file.sha256sum" \
  && sha256sum -c helm.sha256 >/dev/null )
tar -xzf "$helm_tmp/$helm_file" -C "$helm_tmp" linux-amd64/helm
install -m 0755 "$helm_tmp/linux-amd64/helm" /usr/local/bin/helm
rm -rf "$helm_tmp"

log "gh $GH_VERSION"
gh_tmp="$(mktemp -d)"
curl -fsSL --retry 3 -o "$gh_tmp/gh.tgz" \
  "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz"
tar -xzf "$gh_tmp/gh.tgz" -C "$gh_tmp"
install -m 0755 "$gh_tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh
rm -rf "$gh_tmp"

# --- 6b. docker (image builds; `make deps` requires it) --------------------
if [ "${INSTALL_DOCKER:-1}" = "1" ]; then
  if command -v docker >/dev/null 2>&1; then
    log "docker already installed: $(docker --version)"
  else
    log "docker (official repository)"
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$(dpkg --print-architecture)" "$(. /etc/os-release; echo "$VERSION_CODENAME")" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    usermod -aG docker "$OWNER_USER"
    log "added $OWNER_USER to the docker group (takes effect at the next login)"
  fi
fi

# --- 7. kubeconfig for the login user --------------------------------------
log "kubeconfig for $OWNER_USER"
install -d -o "$OWNER_USER" -g "$OWNER_USER" -m 0700 "$OWNER_HOME/.kube"
tmp_kc="$(mktemp)"
cp /etc/rancher/k3s/k3s.yaml "$tmp_kc"
# k3s names the context `default`; rename it to `stardelt-dev` so
# EXPECT_CONTEXT=stardelt-dev (the Makefile guard) matches. Use kubectl rather than
# sed: the context references the cluster and the user by name, and rewriting one
# side only leaves a kubeconfig that cannot resolve its own cluster.
KUBECONFIG="$tmp_kc" /usr/local/bin/kubectl config rename-context default stardelt-dev >/dev/null
install -o "$OWNER_USER" -g "$OWNER_USER" -m 0600 "$tmp_kc" "$OWNER_HOME/.kube/config"
install -o "$OWNER_USER" -g "$OWNER_USER" -m 0600 "$tmp_kc" "$OWNER_HOME/.kube/stardelt-dev.yaml"
rm -f "$tmp_kc"

if ! grep -qs 'KUBECONFIG=' "$OWNER_HOME/.bashrc"; then
  printf '\nexport KUBECONFIG="$HOME/.kube/config"\n' >>"$OWNER_HOME/.bashrc"
  chown "$OWNER_USER:$OWNER_USER" "$OWNER_HOME/.bashrc"
fi

# --- 8. firewall (only if ufw is active) -----------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  log "ufw is active — allowing 80/443 and LAN/tailnet API access"
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow from 192.168.0.0/16 to any port 6443 proto tcp >/dev/null
  ufw allow from 100.64.0.0/10  to any port 6443 proto tcp >/dev/null
  ufw reload >/dev/null
fi

# --- 9. wait for the node --------------------------------------------------
log "waiting for the node to be Ready"
for _ in $(seq 1 60); do
  if runuser -u "$OWNER_USER" -- /usr/local/bin/kubectl get node "$NODE_NAME" \
       -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    break
  fi
  sleep 5
done
runuser -u "$OWNER_USER" -- /usr/local/bin/kubectl get nodes -o wide || true

printf '\n\033[1;32m✓ k3s is up.\033[0m\n'
cat <<EOF
  node:      $NODE_NAME ($LAN_IP${TS_IP:+, $TS_IP})
  kube ctx:  stardelt-dev  (kubectl config current-context)
  k3s:       $(/usr/local/bin/k3s --version | head -1)
  kubectl:   $(/usr/local/bin/kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // "?"')
  helm:      $(/usr/local/bin/helm version --short)
  gh:        $(/usr/local/bin/gh --version | head -1)

Next (no sudo, as $OWNER_USER):
  see dev/home-k3s/README.md §3–§5   # DNS, ingress, cert-manager, platform
  gh auth login                      # once, before opening any PR
EOF

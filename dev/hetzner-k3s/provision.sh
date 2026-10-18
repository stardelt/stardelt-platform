#!/usr/bin/env bash
# Create the stardelt dev cluster on Hetzner Cloud with hetzner-k3s, then point DNS.
#
# Requirements: hetzner-k3s (https://github.com/vitobotta/hetzner-k3s), HCLOUD_TOKEN,
# an SSH keypair, and optionally ~/.config/stardelt/cloudflare.env for DNS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Credentials live outside the repo (mode 600).
CF_ENV="${CF_ENV:-$HOME/.config/stardelt/cloudflare.env}"
# Runtime paths, resolved via CF_ENV / HETZNER_ENV.
# shellcheck source=/dev/null
[ -f "$CF_ENV" ] && { set -a; . "$CF_ENV"; set +a; }
HETZNER_ENV="${HETZNER_ENV:-$HOME/.config/stardelt/hetzner.env}"
# shellcheck source=/dev/null
[ -f "$HETZNER_ENV" ] && { set -a; . "$HETZNER_ENV"; set +a; }

: "${HCLOUD_TOKEN:?set HCLOUD_TOKEN (or put it in $HETZNER_ENV)}"
command -v hetzner-k3s >/dev/null || {
  echo "hetzner-k3s not found: https://github.com/vitobotta/hetzner-k3s" >&2
  exit 1
}

CLUSTER_NAME="${CLUSTER_NAME:-stardelt-dev}"
K3S_VERSION="${K3S_VERSION:-v1.37.1+k3s1}"
NODE_TYPE="${NODE_TYPE:-cx33}"          # 4 vCPU / 8 GB, ~EUR10/mo. cx43 = 16 GB if OOM.
LOCATION="${LOCATION:-nbg1}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519.pub}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/id_ed25519}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/stardelt-dev.yaml}"
INGRESS_HOST="${INGRESS_HOST:-alpha.dev.stardelt.io}"

# SSH (22) and the Kubernetes API (6443) are firewalled to these networks. Plain addresses
# get a /32 (/128); a CIDR is taken as given. Anything that does not look like an address
# aborts here instead of producing a firewall rule that is wrong or silently open.
ALLOW_IPV4="${ALLOW_IPV4:-$(curl -4 -fsS --max-time 10 https://ifconfig.me)}"
[[ "$ALLOW_IPV4" == */* ]] || ALLOW_IPV4="${ALLOW_IPV4}/32"
[[ "$ALLOW_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || {
  echo "ALLOW_IPV4 must be an IPv4 address or CIDR (got '${ALLOW_IPV4}')" >&2
  exit 1
}
ALLOW_IPV6="${ALLOW_IPV6:-$(curl -6 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)}"
if [ -n "$ALLOW_IPV6" ]; then
  [[ "$ALLOW_IPV6" == */* ]] || ALLOW_IPV6="${ALLOW_IPV6}/128"
  if [[ ! "$ALLOW_IPV6" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
    echo "ignoring ALLOW_IPV6 '${ALLOW_IPV6}': not an IPv6 address or CIDR" >&2
    ALLOW_IPV6=""
  fi
fi
ALLOWED="      - ${ALLOW_IPV4}"
if [ -n "$ALLOW_IPV6" ]; then
  ALLOWED="${ALLOWED}
      - ${ALLOW_IPV6}"
fi

CFG="$HERE/cluster.yaml"

# cluster.yaml is the only record destroy.sh has of what to delete. Re-rendering it for a
# different CLUSTER_NAME would orphan the running cluster (and keep billing for it).
if [ -f "$CFG" ]; then
  existing="$(awk -F': *' '/^cluster_name:/ { print $2; exit }' "$CFG")"
  if [ -n "$existing" ] && [ "$existing" != "$CLUSTER_NAME" ]; then
    echo "refusing: $CFG already describes cluster '$existing', but CLUSTER_NAME is '$CLUSTER_NAME'." >&2
    echo "  Overwriting it would orphan '$existing'. Run 'make dev-down' first, or delete" >&2
    echo "  the file if that cluster is already gone." >&2
    exit 1
  fi
fi

umask 077
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
cat > "$CFG" <<EOF
---
hetzner_token: ${HCLOUD_TOKEN}
cluster_name: ${CLUSTER_NAME}
kubeconfig_path: ${KUBECONFIG_PATH}
k3s_version: ${K3S_VERSION}
config_format_version: 1
schedule_workloads_on_masters: true

networking:
  ssh:
    port: 22
    use_agent: false
    public_key_path: "${SSH_PUBLIC_KEY}"
    private_key_path: "${SSH_PRIVATE_KEY}"
  allowed_networks:
    ssh:
${ALLOWED}
    api:
${ALLOWED}
  custom_firewall_rules:
    - description: "http"
      direction: in
      protocol: tcp
      port: "80"
      source_ips: ["0.0.0.0/0", "::/0"]
    - description: "https"
      direction: in
      protocol: tcp
      port: "443"
      source_ips: ["0.0.0.0/0", "::/0"]
  public_network:
    ipv4: true
    ipv6: true
  private_network:
    enabled: true
    subnet: 10.0.0.0/16
  cni:
    enabled: true
    mode: flannel

datastore:
  mode: etcd

masters_pool:
  instance_type: ${NODE_TYPE}
  instance_count: 1
  locations:
    - ${LOCATION}

addons:
  csi_driver:
    enabled: true
  cloud_controller_manager:
    enabled: true
  system_upgrade_controller:
    enabled: true
  cluster_autoscaler:
    enabled: false
  traefik:
    enabled: false
  servicelb:
    enabled: false
  metrics_server:
    enabled: true

create_load_balancer_for_the_kubernetes_api: false
protect_against_deletion: false
EOF
chmod 600 "$CFG"

echo "› creating cluster '${CLUSTER_NAME}' (${NODE_TYPE} @ ${LOCATION}, k3s ${K3S_VERSION})"
hetzner-k3s create --config "$CFG" --quiet

# The kubeconfig carries cluster-admin credentials: keep it private.
if [ -f "$KUBECONFIG_PATH" ]; then chmod 600 "$KUBECONFIG_PATH"; fi
export KUBECONFIG="$KUBECONFIG_PATH"
kubectl get nodes

# Ensure the playground ports are open. hetzner-k3s did not apply
# `custom_firewall_rules` reliably, so make it explicit and idempotent.
if command -v hcloud >/dev/null 2>&1; then
  for port in 80 443; do
    hcloud firewall add-rule "$CLUSTER_NAME" \
      --direction in --protocol tcp --port "$port" \
      --source-ips 0.0.0.0/0 --source-ips ::/0 \
      --description "playground-$port" >/dev/null 2>&1 || true
  done
fi

IP="$(kubectl --kubeconfig "$KUBECONFIG_PATH" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null | sed -E 's#https://##; s#:.*##' || true)"
if [ -z "$IP" ]; then
  IP="$(grep -oE 'https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$KUBECONFIG_PATH" | head -1 | sed 's|https://||' || true)"
fi

if [ -n "$IP" ] && [ -f "$CF_ENV" ] && [ -x "$HERE/../cloudflare-dns.sh" ]; then
  echo "› DNS: ${INGRESS_HOST} and *.${INGRESS_HOST} → ${IP}"
  NAME="$INGRESS_HOST" IP="$IP" bash "$HERE/../cloudflare-dns.sh" upsert \
    || echo "  DNS update failed (continuing)" >&2
fi

echo
echo "✓ cluster ready (${NODE_TYPE} @ ${LOCATION})"
echo "  export KUBECONFIG=\"${KUBECONFIG_PATH}\""
echo "  node IP: ${IP:-unknown}"
echo
echo "Next:  make install-core   # cheap: storage + catalog + query + Nova"
echo "       make install        # full: + Airflow + Superset (needs cx43/16 GB)"

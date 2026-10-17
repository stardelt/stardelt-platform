#!/usr/bin/env bash
# Provision a single-node Hetzner Cloud VM running k3s for stardelt development.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auth: HCLOUD_TOKEN env var OR an active `hcloud context`.
NAME="${NAME:-stardelt-dev}"
TYPE="${TYPE:-cpx41}"
IMAGE="${IMAGE:-ubuntu-24.04}"
LOCATION="${LOCATION:-nbg1}"
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
ALLOW_CIDR="${ALLOW_CIDR:-$(curl -fsS https://ifconfig.me)/32}"

command -v hcloud >/dev/null 2>&1 || {
  echo "hcloud CLI not found. Install: https://github.com/hetznercloud/cli#installation" >&2
  exit 1
}
if [ -z "${HCLOUD_TOKEN:-}" ]; then
  hcloud context active >/dev/null 2>&1 || {
    echo "No active hcloud context and HCLOUD_TOKEN is unset." >&2
    echo "  Run:  hcloud context create stardelt     (prompts for the API token)" >&2
    echo "  or:   export HCLOUD_TOKEN=..." >&2
    exit 1
  }
fi
[ -f "$SSH_PUBKEY" ] || { echo "SSH public key not found: $SSH_PUBKEY" >&2; exit 1; }

if hcloud server describe "$NAME" >/dev/null 2>&1; then
  echo "server '$NAME' already exists — reusing"
else
  echo "› SSH key"
  hcloud ssh-key describe "$NAME" >/dev/null 2>&1 || \
    hcloud ssh-key create --name "$NAME" --public-key-from-file "$SSH_PUBKEY"

  echo "› firewall (SSH + API from ${ALLOW_CIDR}, 80/443 open)"
  if ! hcloud firewall describe "$NAME" >/dev/null 2>&1; then
    hcloud firewall create --name "$NAME"
    hcloud firewall add-rule "$NAME" --direction in --protocol tcp --port 22  --source-ips "$ALLOW_CIDR" --description ssh
    hcloud firewall add-rule "$NAME" --direction in --protocol tcp --port 6443 --source-ips "$ALLOW_CIDR" --description kube-api
    hcloud firewall add-rule "$NAME" --direction in --protocol tcp --port 80   --source-ips 0.0.0.0/0 --description http
    hcloud firewall add-rule "$NAME" --direction in --protocol tcp --port 443  --source-ips 0.0.0.0/0 --description https
  fi

  echo "› server '$NAME' ($TYPE, $LOCATION)"
  hcloud server create \
    --name "$NAME" \
    --type "$TYPE" \
    --image "$IMAGE" \
    --location "$LOCATION" \
    --ssh-key "$NAME" \
    --firewall "$NAME" \
    --user-data-from-file "$HERE/cloud-init.yaml"
fi

IP="$(hcloud server ip "$NAME")"
echo "› waiting for k3s on ${IP} ..."
for i in $(seq 1 60); do
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@${IP}" \
       'test -f /etc/rancher/k3s/k3s.yaml' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@${IP}" 'k3s kubectl get nodes' >/dev/null 2>&1 || {
  echo "k3s did not become ready in time. Check cloud-init: ssh root@${IP} journalctl -u k3s" >&2
  exit 1
}

KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/stardelt-dev.yaml}"
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
ssh -o StrictHostKeyChecking=accept-new "root@${IP}" 'cat /etc/rancher/k3s/k3s.yaml' \
  | sed "s|127.0.0.1|${IP}|g" > "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"

echo
echo "✓ k3s ready at https://${IP}:6443"
echo "  export KUBECONFIG=\"${KUBECONFIG_OUT}\""
echo "  kubectl get nodes"
echo
echo "Next: cd stardelt-platform && make install"

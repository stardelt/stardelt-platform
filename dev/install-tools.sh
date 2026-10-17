#!/usr/bin/env bash
# Install the stardelt development CLIs into ~/.local/bin (no sudo).
# Idempotent: skips anything already on PATH. Installs kubectl, helm, kind, hcloud.
set -euo pipefail

BIN="${BIN:-$HOME/.local/bin}"
mkdir -p "$BIN"
have() { command -v "$1" >/dev/null 2>&1; }

case "$(uname -m)" in
  x86_64|amd64)  GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

KIND_VERSION="${KIND_VERSION:-v0.32.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"
HELM_VERSION="${HELM_VERSION:-v3.18.4}"
HCLOUD_VERSION="${HCLOUD_VERSION:-latest}"

if have kubectl; then echo "kubectl: $(command -v kubectl)"; else
  echo "installing kubectl ${KUBECTL_VERSION} ..."
  curl -fsSLo "$BIN/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${GOARCH}/kubectl"
  chmod +x "$BIN/kubectl"
fi

if have helm; then echo "helm:    $(command -v helm)"; else
  echo "installing helm ${HELM_VERSION} ..."
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSLo "$tmp/helm.tgz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-${GOARCH}.tar.gz"
  tar -xzf "$tmp/helm.tgz" -C "$tmp"
  install -m 0755 "$tmp/linux-${GOARCH}/helm" "$BIN/helm"
fi

if have kind; then echo "kind:    $(command -v kind)"; else
  echo "installing kind ${KIND_VERSION} ..."
  curl -fsSLo "$BIN/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${GOARCH}"
  chmod +x "$BIN/kind"
fi

if have hcloud; then echo "hcloud:  $(command -v hcloud)"; else
  echo "installing hcloud (${HCLOUD_VERSION}) ..."
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  if [ "$HCLOUD_VERSION" = "latest" ]; then
    url="https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-${GOARCH}.tar.gz"
  else
    url="https://github.com/hetznercloud/cli/releases/download/${HCLOUD_VERSION}/hcloud-linux-${GOARCH}.tar.gz"
  fi
  curl -fsSLo "$tmp/hcloud.tgz" "$url"
  tar -xzf "$tmp/hcloud.tgz" -C "$tmp"
  install -m 0755 "$tmp/hcloud" "$BIN/hcloud"
fi

echo
echo "Ensure ${BIN} is on PATH, then:"
echo "  kubectl version --client && helm version --short && kind version && hcloud version"
#!/usr/bin/env bash
# Install the stardelt development CLIs into ~/.local/bin (no sudo).
# Idempotent: skips anything already on PATH. Installs kubectl, helm, hcloud.
#
# Every download is checked against the SHA-256 the upstream project publishes next to
# the artifact, and is only moved into $BIN once it matches. kubectl floats to the
# current stable release by default (KUBECTL_VERSION=vX.Y.Z pins it).
set -euo pipefail

BIN="${BIN:-$HOME/.local/bin}"
mkdir -p "$BIN"
have() { command -v "$1" >/dev/null 2>&1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# download <url> <out-file> <checksum-url>
# The checksum file is either a bare hash or "<hash>  <name>" lines; the line for the
# artifact's basename is used.
download() {
  local url="$1" out="$2" sums_url="$3" name want got
  name="$(basename "$url")"
  want="$(curl -fsSL "$sums_url" | awk -v f="$name" 'NF == 1 || $2 == f || $2 == "*" f { print $1; exit }')"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "no SHA-256 for $name at $sums_url" >&2; exit 1; }
  curl -fsSLo "$out" "$url"
  got="$(sha256sum "$out" | awk '{print $1}')"
  [ "$got" = "$want" ] || { echo "SHA-256 mismatch for $name: expected $want, got $got" >&2; exit 1; }
}

case "$(uname -m)" in
  x86_64|amd64)  GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

KUBECTL_VERSION="${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"
HELM_VERSION="${HELM_VERSION:-v3.18.4}"
HCLOUD_VERSION="${HCLOUD_VERSION:-v1.70.1}"   # "latest" is accepted but is not reproducible

if have kubectl; then echo "kubectl: $(command -v kubectl)"; else
  echo "installing kubectl ${KUBECTL_VERSION} ..."
  url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${GOARCH}/kubectl"
  download "$url" "$tmp/kubectl" "$url.sha256"
  install -m 0755 "$tmp/kubectl" "$BIN/kubectl"
fi

if have helm; then echo "helm:    $(command -v helm)"; else
  echo "installing helm ${HELM_VERSION} ..."
  url="https://get.helm.sh/helm-${HELM_VERSION}-linux-${GOARCH}.tar.gz"
  download "$url" "$tmp/helm.tgz" "$url.sha256sum"
  tar -xzf "$tmp/helm.tgz" -C "$tmp"
  install -m 0755 "$tmp/linux-${GOARCH}/helm" "$BIN/helm"
fi

if have hcloud; then echo "hcloud:  $(command -v hcloud)"; else
  echo "installing hcloud (${HCLOUD_VERSION}) ..."
  if [ "$HCLOUD_VERSION" = "latest" ]; then
    base="https://github.com/hetznercloud/cli/releases/latest/download"
  else
    base="https://github.com/hetznercloud/cli/releases/download/${HCLOUD_VERSION}"
  fi
  download "$base/hcloud-linux-${GOARCH}.tar.gz" "$tmp/hcloud.tgz" "$base/checksums.txt"
  tar -xzf "$tmp/hcloud.tgz" -C "$tmp" hcloud
  install -m 0755 "$tmp/hcloud" "$BIN/hcloud"
fi

echo
echo "Ensure ${BIN} is on PATH, then:"
echo "  kubectl version --client && helm version --short && hcloud version"

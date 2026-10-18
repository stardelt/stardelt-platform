#!/usr/bin/env bash
set -euo pipefail

missing=()
for cmd in docker kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "Missing required tools: ${missing[*]}" >&2
  echo >&2
  echo "Install hints:" >&2
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      kubectl)
        echo "  kubectl: ./dev/install-tools.sh (SHA-256 verified, ~/.local/bin, no sudo)" >&2
        echo "           or https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/" >&2
        ;;
      helm)
        echo "  helm:    ./dev/install-tools.sh (SHA-256 verified, ~/.local/bin, no sudo)" >&2
        echo "           or https://helm.sh/docs/intro/install/" >&2
        ;;
      docker)
        echo "  docker:  https://docs.docker.com/engine/install/" >&2
        ;;
    esac
  done
  exit 1
fi

echo "All required tools present."
helm version --short
kubectl version --client 2>/dev/null | head -1 || kubectl version --client --short 2>/dev/null
docker --version

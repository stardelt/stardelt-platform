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
  echo "Install hints (Ubuntu/Debian/WSL):" >&2
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      kubectl)
        echo "  kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/" >&2
        ;;
      helm)
        echo "  helm:    curl https://baltocdn.com/helm/signing.asc | sudo gpg --dearmor -o /usr/share/keyrings/helm.gpg" >&2
        echo "           echo 'deb [signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main' | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list" >&2
        echo "           sudo apt-get update && sudo apt-get install -y helm" >&2
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

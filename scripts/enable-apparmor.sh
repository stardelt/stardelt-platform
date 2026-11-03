#!/usr/bin/env bash
# Enable a k3s node whose kernel AppArmor denies signals inside containers
# (stardelt-platform#445).
#
#   scripts/enable-apparmor.sh --check       # is the node ready? exits 1 if not
#   sudo scripts/enable-apparmor.sh --apply  # write the k3s containerd template
#   sudo scripts/enable-apparmor.sh --apply --restart
#
# Why: on kernel 7.0.0-42 (and any kernel whose AppArmor signal mediation meets
# containerd's current profile), `cri-containerd.apparmor.d` allows signals between
# the processes of one container only for the exact profile name, not for the
# `//&unconfined` child profile PostgreSQL's workers use. PostgreSQL wakes its
# background workers with SIGURG; the denial leaves every CNPG instance in
# "starting up", so the install hangs on the databases and the cluster looks down.
# The profile is embedded in k3s's containerd template — a customer cannot patch it
# through configuration — so the supported enable is containerd's own setting:
# `disable_apparmor = true` for the CRI runtime. The containers run unconfined on
# that node (the trade-off); the host's AppArmor service stays on.
#
# The k3s-supported way to keep a containerd setting across restarts is the
# template at /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl: k3s
# renders it instead of its built-in config. This script writes that template,
# idempotently, and never restarts k3s unless asked.
set -euo pipefail

TMPL="${K3S_CONTAINERD_TMPL:-/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl}"
GENERATED="${K3S_CONTAINERD_CONFIG:-/var/lib/rancher/k3s/agent/etc/containerd/config.toml}"
# containerd 2.x names the CRI plugin io.containerd.cri.v1.runtime; 1.x used
# io.containerd.grpc.v1.cri. Pick the one the node's generated config carries.
PLUGIN="[plugins.'io.containerd.cri.v1.runtime']"
if [ -f "${K3S_CONTAINERD_CONFIG:-/var/lib/rancher/k3s/agent/etc/containerd/config.toml}" ] \
   && grep -q 'io.containerd.grpc.v1.cri' "${K3S_CONTAINERD_CONFIG:-/var/lib/rancher/k3s/agent/etc/containerd/config.toml}"; then
  PLUGIN='[plugins."io.containerd.grpc.v1.cri"]'
fi
mode=check
restart=0
for arg in "$@"; do
  case "$arg" in
    --check)   mode=check ;;
    --apply)   mode=apply ;;
    --restart) restart=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "enable-apparmor: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "enable-apparmor: $*" >&2; exit 1; }

enabled() {
  # The setting is in the template, or (before a restart) in the generated config.
  { [ -f "$TMPL" ] && grep -q "disable_apparmor *= *true" "$TMPL"; } && return 0
  { [ -f "$GENERATED" ] && grep -q "disable_apparmor *= *true" "$GENERATED"; } && return 0
  return 1
}

denials() {
  command -v journalctl >/dev/null 2>&1 || { echo 0; return; }
  journalctl -k --since "-10 min" 2>/dev/null | grep -c 'apparmor="DENIED" operation="signal"' || true
}

if [ "$mode" = check ]; then
  if enabled; then
    echo "enable-apparmor: the node is ready (disable_apparmor = true is configured)."
    exit 0
  fi
  n="$(denials)"
  if [ "${n:-0}" -gt 0 ]; then
    echo "enable-apparmor: NOT ready — $n AppArmor signal denial(s) in the last ten minutes and" >&2
    echo "                 disable_apparmor is not set. Run: sudo $0 --apply [--restart]" >&2
    exit 1
  fi
  echo "enable-apparmor: no AppArmor signal denials seen, and the setting is absent; nothing to do."
  exit 0
fi

[ "$(id -u)" -eq 0 ] || fail "--apply needs root (sudo $0 --apply)"
mkdir -p "$(dirname "$TMPL")"
if [ -f "$TMPL" ] && grep -q "disable_apparmor *= *true" "$TMPL"; then
  echo "enable-apparmor: already applied in $TMPL"
else
  if [ -f "$TMPL" ]; then
    cp -a "$TMPL" "$TMPL.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    echo "enable-apparmor: backed up $TMPL"
    if grep -qxF "$PLUGIN" "$TMPL"; then
      # The plugin block exists: put the setting right under its header.
      awk -v plugin="$PLUGIN" '
        { print }
        $0 == plugin && !done { print "  disable_apparmor = true"; done = 1 }
      ' "$TMPL" > "$TMPL.new" && mv "$TMPL.new" "$TMPL"
    else
      printf '\n%s\n  disable_apparmor = true\n' "$PLUGIN" >> "$TMPL"
    fi
  else
    {
      printf '{{ template "base" . }}\n\n'
      printf '%s\n  disable_apparmor = true\n' "$PLUGIN"
    } > "$TMPL"
  fi
  echo "enable-apparmor: wrote $TMPL"
fi

if [ "$restart" = 1 ]; then
  echo "enable-apparmor: restarting k3s (the cluster's pods restart)"
  systemctl restart k3s
  echo "enable-apparmor: done; containers are unconfined on this node (AppArmor service stays on)"
else
  echo "enable-apparmor: restart k3s to apply: sudo systemctl restart k3s   (or --restart)"
fi

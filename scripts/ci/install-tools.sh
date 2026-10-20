#!/usr/bin/env bash
# Install pinned CLI tools for CI, each verified against a SHA-256 recorded
# here. Downloading binaries directly (instead of third-party GitHub Actions)
# keeps the pipeline's supply chain small and reviewable: a moved tag
# upstream cannot change what runs here.
#
#   scripts/ci/install-tools.sh helm kind kubeconform promtool trivy gitleaks hadolint
set -euo pipefail
BIN="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HELM_VERSION=v4.1.4
KIND_VERSION=v0.29.0
KIND_SHA=c72eda46430f065fb45c5f70e7c957cc9209402ef309294821978677c8fb3284
KUBECONFORM_VERSION=v0.7.0
KUBECONFORM_SHA=c31518ddd122663b3f3aa874cfe8178cb0988de944f29c74a0b9260920d115d3
PROM_VERSION=3.5.0
PROM_SHA=e811827af26d822afb09a4f28314f61b618b12cff5369835a67f674d8b46f39a
# 0.69.3 is a known-good release (0.69.4 and trivy-action <= 0.34.2 were
# compromised in March 2026, CVE-2026-33634), hence a pinned binary + hash.
TRIVY_VERSION=0.69.3
TRIVY_SHA=1816b632dfe529869c740c0913e36bd1629cb7688bd5634f4a858c1d57c88b75
GITLEAKS_VERSION=8.28.0
GITLEAKS_SHA=a65b5253807a68ac0cafa4414031fd740aeb55f54fb7e55f386acb52e6a840eb
HADOLINT_VERSION=v2.12.0
HADOLINT_SHA=56de6d5e5ec427e17b74fa48d51271c7fc0d61244bf5c90e828aab8362d55010

fetch() { # url sha out
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet - || { echo "checksum mismatch for $1" >&2; exit 1; }
}

for tool in "$@"; do
  case "$tool" in
    helm)
      curl -fsSL --retry 3 -o "$TMP/helm.tgz" "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz"
      sha="$(curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz.sha256sum" | cut -d' ' -f1)"
      echo "$sha  $TMP/helm.tgz" | sha256sum -c --quiet -
      tar -xzf "$TMP/helm.tgz" -C "$TMP" && install "$TMP/linux-amd64/helm" "$BIN/helm" ;;
    kind)
      fetch "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64" "$KIND_SHA" "$TMP/kind"
      install "$TMP/kind" "$BIN/kind" ;;
    kubeconform)
      fetch "https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz" "$KUBECONFORM_SHA" "$TMP/kc.tgz"
      tar -xzf "$TMP/kc.tgz" -C "$TMP" kubeconform && install "$TMP/kubeconform" "$BIN/kubeconform" ;;
    promtool)
      fetch "https://github.com/prometheus/prometheus/releases/download/v$PROM_VERSION/prometheus-$PROM_VERSION.linux-amd64.tar.gz" "$PROM_SHA" "$TMP/prom.tgz"
      tar -xzf "$TMP/prom.tgz" -C "$TMP" && install "$TMP/prometheus-$PROM_VERSION.linux-amd64/promtool" "$BIN/promtool" ;;
    trivy)
      fetch "https://github.com/aquasecurity/trivy/releases/download/v$TRIVY_VERSION/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" "$TRIVY_SHA" "$TMP/trivy.tgz"
      tar -xzf "$TMP/trivy.tgz" -C "$TMP" trivy && install "$TMP/trivy" "$BIN/trivy" ;;
    gitleaks)
      fetch "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" "$GITLEAKS_SHA" "$TMP/gl.tgz"
      tar -xzf "$TMP/gl.tgz" -C "$TMP" gitleaks && install "$TMP/gitleaks" "$BIN/gitleaks" ;;
    hadolint)
      fetch "https://github.com/hadolint/hadolint/releases/download/$HADOLINT_VERSION/hadolint-Linux-x86_64" "$HADOLINT_SHA" "$TMP/hadolint"
      install "$TMP/hadolint" "$BIN/hadolint" ;;
    *) echo "unknown tool: $tool" >&2; exit 1 ;;
  esac
  echo "installed $tool"
done
[[ -n "${GITHUB_PATH:-}" ]] && echo "$BIN" >>"$GITHUB_PATH"
true

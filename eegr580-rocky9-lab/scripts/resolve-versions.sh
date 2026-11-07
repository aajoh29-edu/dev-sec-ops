#!/usr/bin/env bash
# resolve-versions.sh — fill versions.env with current releases, archive hashes
# and image digests. Run on the HOST side (WSL2 shell or the lab container),
# review `git diff versions.env`, then commit. Pinning happens at commit time;
# builds never resolve "latest" on their own.
#
# Requires: curl, jq, docker (buildx imagetools), optional GITHUB_TOKEN.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=versions.env
BLOCKED_TRIVY='^(0\.69\.4|0\.69\.5|0\.69\.6)$'   # CVE-2026-33634 malicious releases

auth=(); [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
gh_latest() { curl -fsSL "${auth[@]}" "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name | sed 's/^v//'; }
sum_from() { # repo version checksums-asset archive-asset
  curl -fsSL "https://github.com/$1/releases/download/v$2/$3" | awk -v f="$4" '$2==f || $2=="*"f {print $1}'
}
digest() { docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r .digest; }
set_kv() { sed -i "s|^$1=.*|$1=$2|" "$OUT"; }

GL=$(gh_latest gitleaks/gitleaks); TV=$(gh_latest aquasecurity/trivy)
GV=$(gh_latest anchore/grype);     SV=$(gh_latest anchore/syft)
[[ "$TV" =~ $BLOCKED_TRIVY ]] && { echo "Refusing blocked Trivy release $TV" >&2; exit 1; }

set_kv GITLEAKS_VERSION "$GL"
set_kv GITLEAKS_SHA256  "$(sum_from gitleaks/gitleaks "$GL" "gitleaks_${GL}_checksums.txt" "gitleaks_${GL}_linux_x64.tar.gz")"
set_kv TRIVY_VERSION    "$TV"
set_kv TRIVY_SHA256     "$(sum_from aquasecurity/trivy "$TV" "trivy_${TV}_checksums.txt" "trivy_${TV}_Linux-64bit.tar.gz")"
set_kv GRYPE_VERSION    "$GV"
set_kv GRYPE_SHA256     "$(sum_from anchore/grype "$GV" "grype_${GV}_checksums.txt" "grype_${GV}_linux_amd64.tar.gz")"
set_kv SYFT_VERSION     "$SV"
set_kv SYFT_SHA256      "$(sum_from anchore/syft "$SV" "syft_${SV}_checksums.txt" "syft_${SV}_linux_amd64.tar.gz")"

set_kv SEMGREP_VERSION "$(curl -fsSL https://pypi.org/pypi/semgrep/json | jq -r .info.version)"
set_kv CHECKOV_VERSION "$(curl -fsSL https://pypi.org/pypi/checkov/json | jq -r .info.version)"

set_kv ROCKY_IMAGE    "docker.io/rockylinux/rockylinux:9@$(digest docker.io/rockylinux/rockylinux:9)"
set_kv APP_BASE_IMAGE "docker.io/library/python:3.12-slim@$(digest docker.io/library/python:3.12-slim)"
set_kv ZAP_IMAGE      "ghcr.io/zaproxy/zaproxy:stable@$(digest ghcr.io/zaproxy/zaproxy:stable)"

grep -nE '=$|sha256:$' "$OUT" && { echo "Unresolved values above" >&2; exit 1; }
echo "versions.env updated — review with: git diff versions.env"

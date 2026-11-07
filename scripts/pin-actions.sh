#!/usr/bin/env bash
# pin-actions.sh — replace @PIN_<NAME> placeholders with full commit SHAs.
# Run once (WSL2 or the lab container) with the GitHub CLI logged in, review the
# diff, and commit. Re-run deliberately to upgrade; never point at a moving tag.
set -euo pipefail
cd "$(dirname "$0")/.."
WF=.github/workflows/secure-supply-chain.yml
declare -A REPO=(
  [CHECKOUT]=actions/checkout
  [UPLOAD_ARTIFACT]=actions/upload-artifact
  [DOWNLOAD_ARTIFACT]=actions/download-artifact
  [CODEQL]=github/codeql-action
  [ATTEST]=actions/attest-build-provenance
)
for k in "${!REPO[@]}"; do
  repo=${REPO[$k]}
  tag=$(gh api "repos/$repo/releases/latest" --jq .tag_name)
  # Resolve annotated tags to the commit they point at.
  sha=$(gh api "repos/$repo/commits/$tag" --jq .sha)
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "could not resolve $repo@$tag" >&2; exit 1; }
  sed -i -E "s|@PIN_${k} # v[0-9]+|@${sha} # ${tag}|g" "$WF"
  echo "$repo $tag -> $sha"
done
grep -n '@PIN_' "$WF" && { echo "unresolved placeholders remain" >&2; exit 1; }
echo "Pinned. Review: git diff $WF"

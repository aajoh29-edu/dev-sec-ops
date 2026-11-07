#!/usr/bin/env bash
# verify.sh <evidence-dir> [public-key.asc] — independent check of an evidence package.
set -euo pipefail
D="${1:?evidence dir}"; KEY="${2:-/srv/git/ci-status/labci-public.asc}"
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --batch --quiet --import "$KEY"
gpg --batch --verify "$D/manifest.json.asc" "$D/manifest.json"
( cd "$D" && jq -r '.files[] | "\(.sha256)  \(.path)"' manifest.json | sha256sum -c --quiet ) \
  && echo "verify: signature valid and all $(jq '.files|length' "$D/manifest.json") file hashes match"

#!/usr/bin/env bash
# dojo-upload.sh <evidence-dir> — import/reimport every report into DefectDojo.
# Trusted contexts only (labci identity, or the protected 'defectdojo' GitHub environment).
# Needs DD_URL, DD_API_KEY (from a secret store), DD_PRODUCT, DD_ENGAGEMENT.
set -euo pipefail
D="${1:?evidence dir}"
: "${DD_URL:?}" "${DD_API_KEY:?}" "${DD_PRODUCT:=eegr580-app}" "${DD_ENGAGEMENT:=ci}"
jq -c '.[]' "$D/dojo-import.json" | while read -r row; do
  f=$(jq -r .file <<<"$row"); st=$(jq -r .scan_type <<<"$row")
  curl -fsS -X POST "$DD_URL/api/v2/reimport-scan/" \
    -H "Authorization: Token $DD_API_KEY" \
    -F "scan_type=$st" -F "file=@$D/$f" -F "product_name=$DD_PRODUCT" \
    -F "engagement_name=$DD_ENGAGEMENT" -F "test_title=$st" \
    -F "auto_create_context=true" -F "close_old_findings=true" -F "minimum_severity=Info" \
    -o /dev/null && echo "dojo: reimported $f as '$st'"
done

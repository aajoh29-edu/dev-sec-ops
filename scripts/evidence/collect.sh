#!/usr/bin/env bash
# collect.sh — forensic evidence package for one pipeline run.
#   evidence/<run>/reports/*         every scanner report + verdicts
#   evidence/<run>/context/*         git provenance, push-log excerpt, tool versions
#   evidence/<run>/dojo-import.json  DefectDojo import plan (file -> scan_type)
#   evidence/<run>/manifest.json     SHA-256 of every file + run metadata
#   evidence/<run>/manifest.json.asc detached OpenPGP signature (labci key) [--sign]
# In GitHub Actions use --no-sign; integrity there comes from artifact attestations.
set -euo pipefail
RUN_ID="run-$(date -u +%Y%m%dT%H%M%SZ)"; OUT=""; SIGN=0
while [[ $# -gt 0 ]]; do case "$1" in
  --run-id) RUN_ID="$2"; shift 2;; --out) OUT="$2"; shift 2;;
  --sign) SIGN=1; shift;; --no-sign) SIGN=0; shift;; *) echo "bad arg $1" >&2; exit 2;; esac; done
REPORT_DIR="${REPORT_DIR:-$PWD/reports}"; OUT="${OUT:-$PWD/evidence/$RUN_ID}"
mkdir -p "$OUT/reports" "$OUT/context"
find "$REPORT_DIR" -maxdepth 2 -type f ! -name 'image.tar' -exec cp -p {} "$OUT/reports/" \;
[[ -f "$REPORT_DIR/image.tar.sha256" ]] && cp "$REPORT_DIR/image.tar.sha256" "$OUT/reports/"

# Provenance context
{ git -c gpg.format=openpgp log -1 --format='commit %H%nauthor %an <%ae>%ncommitter %cn <%ce>%ndate %cI%nsigner %GS%nsig_status %G?%nsig_fpr %GF%nprimary_fpr %GP%n%n%B' HEAD
  echo "---- raw signature verification ----"; git -c gpg.format=openpgp log -1 --show-signature --format=%H HEAD 2>&1; } \
  > "$OUT/context/git-provenance.txt" 2>&1 || true
git -c gpg.format=openpgp log --format='%H %G? %GP %s' -n 50 > "$OUT/context/git-history.txt" 2>/dev/null || true
[[ -r /var/log/lab-audit/push.log ]] && tail -n 200 /var/log/lab-audit/push.log > "$OUT/context/push-log.jsonl" || true
{ for t in gitleaks semgrep checkov trivy grype syft docker git gpg; do
    printf '%s: ' "$t"; ("$t" --version 2>/dev/null || "$t" version 2>/dev/null) | head -n1 || echo n/a; done
  echo "host: $(uname -srm)"; if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "runner: github-actions ${ImageOS:-} ${RUNNER_NAME:-}"; else echo "runner: rocky9-lab container"; fi
} > "$OUT/context/tool-versions.txt" 2>&1

# DefectDojo import plan — scan_type names match DefectDojo's parsers; only files present are listed.
plan=()
add() { [[ -f "$OUT/$1" ]] && plan+=("$(jq -cn --arg file "$1" --arg st "$2" '{file:$file,scan_type:$st}')"); return 0; }
add reports/gitleaks.json     "Gitleaks Scan"
add reports/semgrep.json      "Semgrep JSON Report"
add reports/results_json.json "Checkov Scan"
add reports/trivy.json        "Trivy Scan"
add reports/grype.json        "Anchore Grype"
add reports/zap.xml           "ZAP Scan"
printf '%s\n' "${plan[@]}" | jq -s . > "$OUT/dojo-import.json"

# Manifest: every file, hashed, plus run metadata.
( cd "$OUT"
  find . -type f ! -name manifest.json ! -name manifest.json.asc -printf '%P\n' | sort | while read -r f; do
    jq -cn --arg path "$f" --arg sha256 "$(sha256sum "$f" | cut -d' ' -f1)" --argjson bytes "$(stat -c %s "$f")" \
      '{path:$path,sha256:$sha256,bytes:$bytes}'; done | jq -s \
    --arg run "$RUN_ID" --arg commit "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
    --arg image_tar_sha256 "$(cut -d' ' -f1 "$REPORT_DIR/image.tar.sha256" 2>/dev/null || echo none)" \
    --arg image_id "$(cat "$REPORT_DIR/image.id" 2>/dev/null || echo none)" \
    --arg at "$(date -u +%FT%TZ)" --arg by "$(id -un)@$(hostname)" \
    --slurpfile v <(cat "$REPORT_DIR"/verdict-*.json 2>/dev/null | jq -s . || echo '[]') \
    '{schema:"eegr580-evidence/v1",run_id:$run,commit:$commit,image:{tar_sha256:$image_tar_sha256,id:$image_id},
      collected_at:$at,collected_by:$by,verdicts:($v[0]//[]),files:.}' > manifest.json )

if [[ $SIGN -eq 1 ]]; then
  gpg --batch --yes --armor --detach-sign -o "$OUT/manifest.json.asc" "$OUT/manifest.json"
  gpg --batch --verify "$OUT/manifest.json.asc" "$OUT/manifest.json" 2>&1 | sed 's/^/evidence: /'
fi
echo "evidence: $OUT (files: $(jq '.files|length' "$OUT/manifest.json"))"

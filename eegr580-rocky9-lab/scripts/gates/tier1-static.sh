#!/usr/bin/env bash
# Tier 1 — Static quality and policy gates (pre-build).
#   Semgrep (SAST): command injection, unsafe eval/exec, unsafe YAML load.
#   Checkov (IaC):  Dockerfile posture (non-root USER, pinned tags, HEALTHCHECK)
#                   and GitHub Actions workflow posture.
# Usage: tier1-static.sh [source-dir]   (default: .)
source "$(dirname "$0")/lib.sh"
SRC="${1:-.}"; need_tool semgrep; need_tool checkov

log "Tier 1: Semgrep with repository rules (.semgrep/), registry disabled for reproducibility"
semgrep scan --metrics=off --disable-version-check --config "$SRC/.semgrep" \
  --error --json-output="$REPORT_DIR/semgrep.json" --sarif-output="$REPORT_DIR/semgrep.sarif" \
  --quiet "$SRC" && pass "Semgrep: no blocking findings" \
  || { fail "Semgrep: blocking findings"; \
       jq -r '.results[] | "  \(.check_id) \(.path):\(.start.line)"' "$REPORT_DIR/semgrep.json" >&2 || true; }

log "Tier 1: Checkov (dockerfile, github_actions); lab/ is the root-by-design workstation and is out of release scope"
mkdir -p "$REPORT_DIR/checkov"
if checkov -d "$SRC" --config-file "$SRC/.checkov.yaml" --quiet --compact \
     -o cli -o json -o sarif --output-file-path "$REPORT_DIR/checkov" ; then
  pass "Checkov: all checks passed"
else
  fail "Checkov: failed checks (see reports/checkov/results_json.json)"
fi
finish tier1

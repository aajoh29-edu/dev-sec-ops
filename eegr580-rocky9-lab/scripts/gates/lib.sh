#!/usr/bin/env bash
# Shared helpers for all gate tiers. Sourced, not executed.
set -euo pipefail
REPORT_DIR="${REPORT_DIR:-$PWD/reports}"
mkdir -p "$REPORT_DIR"
export SEMGREP_SEND_METRICS=off
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
pass() { log "PASS  $*"; }
fail() { log "FAIL  $*"; GATE_FAILED=1; }
GATE_FAILED=0
# Record a gate verdict for the evidence manifest.
verdict() { # tier status detail
  jq -n --arg tier "$1" --arg status "$2" --arg detail "$3" \
        --arg at "$(date -u +%FT%TZ)" '{tier:$tier,status:$status,detail:$detail,at:$at}' \
    > "$REPORT_DIR/verdict-$1.json"
}
finish() { # tier
  if [[ "$GATE_FAILED" -ne 0 ]]; then verdict "$1" fail "see reports"; exit 1; fi
  verdict "$1" pass "all checks passed"
}
need_tool() { command -v "$1" >/dev/null || { log "required tool missing: $1"; exit 3; }; }

#!/usr/bin/env bash
# Tier 3 — Isolated runtime DAST (OWASP ZAP baseline, passive only).
#   The app runs on an --internal Docker network (no egress) with a read-only
#   root fs, all capabilities dropped and no-new-privileges. Only this
#   container is a scan target. Active scanning is out of scope by policy.
# Usage: tier3-runtime.sh <image-tag> [port]
source "$(dirname "$0")/lib.sh"
TAG="${1:-eegr580/app:ci}"; PORT="${2:-8000}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "${VERSIONS_FILE:-$HERE/versions.env}"
need_tool docker
NET="dast-$$"; APPC="dast-app-$$"
cleanup() { docker rm -f "$APPC" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker network create --internal "$NET" >/dev/null
docker run -d --name "$APPC" --network "$NET" --network-alias app \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 128 --memory 256m \
  "$TAG" >/dev/null
for _ in $(seq 1 30); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "$APPC" 2>/dev/null)" == healthy ]] && break; sleep 1
done
log "Tier 3: target http://app:$PORT on internal network $NET (health: $(docker inspect -f '{{.State.Health.Status}}' "$APPC"))"

WRK="$(mktemp -d)"; chmod 0777 "$WRK"
[[ -f .zap/rules.tsv ]] && cp .zap/rules.tsv "$WRK/rules.tsv"
RULES=(); [[ -f "$WRK/rules.tsv" ]] && RULES=(-c rules.tsv)
set +e
docker run --rm --network "$NET" -v "$WRK:/zap/wrk:rw" "${ZAP_IMAGE:?}" \
  zap-baseline.py -t "http://app:$PORT" "${RULES[@]}" -I \
  -J zap.json -x zap.xml -r zap.html
rc=$?
set -e
cp "$WRK"/zap.* "$REPORT_DIR/" 2>/dev/null || true; rm -rf "$WRK"
# zap-baseline exit codes: 0 pass, 1 FAIL-level alerts, 2 WARN (suppressed by -I), 3 error
case "$rc" in
  0) pass "ZAP baseline: no FAIL-level alerts" ;;
  1) fail "ZAP baseline: FAIL-level alerts (see reports/zap.html)" ;;
  *) fail "ZAP baseline did not complete (rc=$rc) — a scanner that cannot run fails the gate" ;;
esac
finish tier3

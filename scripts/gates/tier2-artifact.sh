#!/usr/bin/env bash
# Tier 2 — Artifact assurance and vulnerability intelligence.
#   Build once -> docker save -> image.tar -> SHA-256. Every scanner reads the
#   SAME tarball and re-verifies its hash first, so all findings describe one
#   immutable artifact. Trivy (primary) + Grype (independent cross-check),
#   SBOMs in CycloneDX and SPDX.
# Usage: tier2-artifact.sh <app-dir> <image-tag>
#   Policy: fail on CRITICAL or HIGH with an available fix, minus documented,
#   unexpired exceptions (.trivyignore with exp:, .grype.yaml).
source "$(dirname "$0")/lib.sh"
APP="${1:-app}"; TAG="${2:-eegr580/app:ci}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "${VERSIONS_FILE:-$HERE/versions.env}"
need_tool docker; need_tool trivy; need_tool grype; need_tool syft
TAR="$REPORT_DIR/image.tar"

log "Tier 2: build $TAG from $APP (base ${APP_BASE_IMAGE:?})"
docker build --pull --provenance=false --build-arg "BASE_IMAGE=$APP_BASE_IMAGE" \
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
  -t "$TAG" "$APP"
docker save "$TAG" -o "$TAR"
( cd "$REPORT_DIR" && sha256sum image.tar > image.tar.sha256 )
docker image inspect "$TAG" --format '{{.Id}}' > "$REPORT_DIR/image.id"
log "image.tar sha256 $(cut -d' ' -f1 "$REPORT_DIR/image.tar.sha256"), image id $(cat "$REPORT_DIR/image.id")"
verify_tar() { ( cd "$REPORT_DIR" && sha256sum -c --quiet image.tar.sha256 ) || { log "image.tar hash changed — aborting"; exit 1; }; }

verify_tar
IGN=(); [[ -f .trivyignore ]] && IGN=(--ignorefile .trivyignore)
trivy image --input "$TAR" --scanners vuln,secret --format json -o "$REPORT_DIR/trivy.json" "${IGN[@]}" --quiet
trivy image --input "$TAR" --scanners vuln --format sarif -o "$REPORT_DIR/trivy.sarif" "${IGN[@]}" --quiet
trivy image --input "$TAR" --format cyclonedx -o "$REPORT_DIR/sbom.cdx.json" --quiet
if trivy image --input "$TAR" --scanners vuln,secret --severity CRITICAL,HIGH --ignore-unfixed \
     --exit-code 1 "${IGN[@]}" --quiet --format table > "$REPORT_DIR/trivy-gate.txt"; then
  pass "Trivy: no fixable HIGH/CRITICAL"
else fail "Trivy: fixable HIGH/CRITICAL present"; cat "$REPORT_DIR/trivy-gate.txt" >&2; fi

verify_tar
syft "docker-archive:$TAR" -q -o "spdx-json=$REPORT_DIR/sbom.spdx.json" -o "cyclonedx-json=$REPORT_DIR/sbom.syft.cdx.json"
GCFG=(); [[ -f .grype.yaml ]] && GCFG=(-c .grype.yaml)
grype "docker-archive:$TAR" "${GCFG[@]}" -q -o json --file "$REPORT_DIR/grype.json" || true
grype "docker-archive:$TAR" "${GCFG[@]}" -q -o sarif --file "$REPORT_DIR/grype.sarif" || true
# Same policy as Trivy: HIGH+ with a fix available.
gn=$(jq '[.matches[] | select((.vulnerability.severity=="Critical" or .vulnerability.severity=="High")
           and (.vulnerability.fix.state=="fixed"))] | length' "$REPORT_DIR/grype.json")
if [[ "$gn" -eq 0 ]]; then pass "Grype: no fixable HIGH/CRITICAL"; else fail "Grype: $gn fixable HIGH/CRITICAL"; fi

# Cross-check: normalise to (vuln id, package, version) and report overlap.
jq -r '[.Results[]?.Vulnerabilities[]? | "\(.VulnerabilityID)|\(.PkgName)|\(.InstalledVersion)"] | unique[]' \
  "$REPORT_DIR/trivy.json" | sort > "$REPORT_DIR/.t"
jq -r '[.matches[] | "\(.vulnerability.id)|\(.artifact.name)|\(.artifact.version)"] | unique[]' \
  "$REPORT_DIR/grype.json" | sort > "$REPORT_DIR/.g"
jq -n --argjson both "$(comm -12 "$REPORT_DIR/.t" "$REPORT_DIR/.g" | wc -l)" \
      --argjson trivy_only "$(comm -23 "$REPORT_DIR/.t" "$REPORT_DIR/.g" | wc -l)" \
      --argjson grype_only "$(comm -13 "$REPORT_DIR/.t" "$REPORT_DIR/.g" | wc -l)" \
      '{both:$both,trivy_only:$trivy_only,grype_only:$grype_only}' > "$REPORT_DIR/scanner-overlap.json"
rm -f "$REPORT_DIR/.t" "$REPORT_DIR/.g"
log "scanner overlap: $(cat "$REPORT_DIR/scanner-overlap.json")"
finish tier2

#!/usr/bin/env bash
# Tier 0 — Trust & provenance.
#   1. Every commit in the range carries a valid OpenPGP signature.
#   2. The signing key's primary fingerprint is on the allow-list.
#   3. No secrets in the commits (Gitleaks).
# Policy (trusted-signers.asc, allowed-signers.txt, .gitleaks.toml) is read from
# POLICY_REF — the protected base branch — never from the commits being tested,
# so a change cannot add its own author to the allow-list.
#
# Usage: tier0-provenance.sh --policy-ref <ref> -- <git rev-list args...>
#   e.g. tier0-provenance.sh --policy-ref origin/main -- origin/main..HEAD
#        tier0-provenance.sh --policy-ref refs/heads/main -- <new-sha> --not --all
source "$(dirname "$0")/lib.sh"
POLICY_REF=""; SKIP_GITLEAKS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy-ref) POLICY_REF="$2"; shift 2 ;;
    --policy-dir) POLICY_DIR="$2"; shift 2 ;;   # bootstrap only: policy from a path
    --skip-gitleaks) SKIP_GITLEAKS=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
RANGE=("$@"); [[ ${#RANGE[@]} -gt 0 ]] || { log "no commit range"; exit 2; }
need_tool gpg; need_tool git

POL="$(mktemp -d)"; export GNUPGHOME="$POL/gnupg"; mkdir -m 700 "$GNUPGHOME"
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$POL"' EXIT
get_policy() { # path-in-repo dest
  if [[ -n "${POLICY_DIR:-}" ]]; then cp "$POLICY_DIR/$1" "$2"
  else git show "${POLICY_REF:?--policy-ref required}:$1" > "$2"; fi
}
get_policy .github/security/trusted-signers.asc "$POL/trusted.asc"
get_policy .github/security/allowed-signers.txt "$POL/allowed.txt"
get_policy .gitleaks.toml "$POL/gitleaks.toml" 2>/dev/null || : > "$POL/gitleaks.toml"
gpg --batch --quiet --import "$POL/trusted.asc" 2>/dev/null
# Allow-list format: <40-hex primary fingerprint> <email> [# comment]
ALLOWED="$(grep -Eo '^[0-9A-Fa-f]{40}' "$POL/allowed.txt" | tr a-f A-F)"

REPORT="$REPORT_DIR/tier0-signatures.jsonl"; : > "$REPORT"
mapfile -t COMMITS < <(git rev-list "${RANGE[@]}")
log "Tier 0: verifying ${#COMMITS[@]} commit(s) against policy ${POLICY_REF:-$POLICY_DIR}"
for c in "${COMMITS[@]}"; do
  # %G? : G good+valid, U good+unknown validity (expected: temp keyring has no
  # ownertrust — the allow-list is the trust decision), N none, B bad, E cannot
  # check (key not in trusted-signers), X/Y expired sig/key, R revoked.
  IFS='|' read -r st fpr pfpr signer subj < <(git -c gpg.format=openpgp log -1 --format='%G?|%GF|%GP|%GS|%s' "$c")
  key="${pfpr:-$fpr}"; key="${key^^}"; decision=reject; reason=""
  case "$st" in
    G|U) if grep -qx "$key" <<<"$ALLOWED"; then decision=accept; reason="allow-listed signer"
         else reason="valid signature, key $key not on allow-list"; fi ;;
    N)   reason="unsigned commit" ;;
    E)   reason="signature from a key not in trusted-signers.asc" ;;
    B)   reason="BAD signature (content altered after signing)" ;;
    X|Y) reason="expired signature or key" ;;
    R)   reason="signing key revoked" ;;
    *)   reason="unrecognised status $st" ;;
  esac
  jq -cn --arg c "$c" --arg st "$st" --arg key "$key" --arg signer "$signer" \
         --arg subj "$subj" --arg d "$decision" --arg r "$reason" \
     '{commit:$c,gpg_status:$st,primary_fpr:$key,signer:$signer,subject:$subj,decision:$d,reason:$r}' >> "$REPORT"
  if [[ "$decision" == accept ]]; then pass "$c ${subj:0:50} — $reason"; else fail "$c ${subj:0:50} — $reason"; fi
done

if [[ "$SKIP_GITLEAKS" -eq 0 && ${#COMMITS[@]} -gt 0 ]]; then
  need_tool gitleaks
  cfg=(); [[ -s "$POL/gitleaks.toml" ]] && cfg=(--config "$POL/gitleaks.toml")
  log_opts="${RANGE[*]}"
  for fmt in json sarif; do
    gitleaks git "${cfg[@]}" --log-opts="$log_opts" --redact --no-banner \
      --report-format "$fmt" --report-path "$REPORT_DIR/gitleaks.$fmt" --exit-code 0 . >/dev/null 2>&1 || true
  done
  n=$(jq 'length' "$REPORT_DIR/gitleaks.json" 2>/dev/null || echo 0)
  if [[ "$n" -gt 0 ]]; then
    fail "Gitleaks: $n secret finding(s) — treat as exposed; see runbook (revoke, rotate, investigate)"
    jq -r '.[] | "  \(.RuleID) \(.File):\(.StartLine) commit \(.Commit[0:12])"' "$REPORT_DIR/gitleaks.json" >&2
  else pass "Gitleaks: no secrets in range"; fi
fi
finish tier0

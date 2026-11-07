#!/usr/bin/env bash
# demo.sh — live scenario driver, run as the lab user inside the Rocky 9 container after setup-lab.sh.
#   demo.sh all | a | a2 | b | c | d
# A   unsigned commit + synthetic credential  -> pre-commit and pre-receive reject
# A2  valid signature, key not allow-listed   -> pre-receive rejects
# B   signed commit with SAST + Dockerfile + dependency flaws -> CI fails, merge rejected
# C   forensic evidence: signed manifest, audit chain, push log
# D   remediation -> CI passes -> fast-forward merge to main accepted
set -uo pipefail
export GNUPGHOME="$HOME/.gnupg" PATH=/opt/scanners/bin:/opt/lab/scripts/bin:$PATH
WS="$HOME/work/app"; cd "$WS" || { echo "run setup-lab.sh first" >&2; exit 1; }
ROGUE_FPR="$(gpg --with-colons --list-keys rogue@eegr580.lab | awk -F: '/^fpr/{print $10; exit}')"
banner() { printf '\n\033[1;36m################ %s ################\033[0m\n' "$*"; }
step()   { printf '\033[1m-- %s\033[0m\n' "$*"; }
expect_fail() { if "$@"; then echo "UNEXPECTED: command succeeded: $*"; return 1; else echo "EXPECTED: blocked"; fi; }
expect_ok()   { if "$@"; then echo "EXPECTED: accepted"; else echo "UNEXPECTED: command failed: $*"; return 1; fi; }
fresh_branch() { git checkout -q main && git pull -q --ff-only origin main; git branch -D "$1" >/dev/null 2>&1; git checkout -q -b "$1"; }
synthetic_token() { printf 'ghp_%s' "$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"; }

scenario_a() {
  banner "Scenario A: unsigned commit carrying a synthetic credential"
  fresh_branch demo/a
  mkdir -p config
  # Generated at run time so no token-shaped string is ever stored in this script or repo.
  printf 'API_BASE = "https://api.example.invalid"\nGITHUB_TOKEN = "%s"\n' "$(synthetic_token)" > config/settings.py
  git add config/settings.py
  step "A.1 signed commit attempt: pre-commit Gitleaks blocks the credential"
  expect_fail git commit -m "feat: add API settings"
  step "A.2 developer bypasses hooks AND signing (--no-verify, gpgsign=false)"
  git -c commit.gpgsign=false commit -q --no-verify -m "feat: add API settings (bypass)"
  git log -1 --format='   commit %h  signature status: %G?'
  step "A.3 push: server-side pre-receive rejects (unsigned + secret); objects stay in quarantine"
  expect_fail git push origin demo/a
  step "A.4 response: the token is synthetic; for a real one -> revoke, rotate, review provider audit logs"
  git checkout -q main; git branch -D demo/a >/dev/null
}

scenario_a2() {
  banner "Scenario A2: valid signature from a key that is NOT allow-listed"
  fresh_branch demo/a2
  echo "- contributor note $(date -u +%FT%TZ)" >> CONTRIBUTING.md
  git add CONTRIBUTING.md
  step "A2.1 commit signed by the rogue key (signature is cryptographically valid)"
  git commit -q -S"$ROGUE_FPR" -m "docs: contributor note"
  git log -1 --format='   commit %h  status %G?  signer %GS  key %GF'
  step "A2.2 push: pre-receive rejects — fingerprint absent from allowed-signers.txt on main"
  expect_fail git push origin demo/a2
  git checkout -q main; git branch -D demo/a2 >/dev/null
}

write_vulnerable_app() {
  cat > app/app.py <<'PY'
"""Scenario B: deliberately vulnerable revision (lab only)."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import yaml


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path in ("/", "/health"):
            return self._send(200, {"status": "ok"})
        if url.path == "/api/lookup":
            return self._send(200, {"out": os.popen("nslookup " + q.get("host", "")).read()})
        if url.path == "/api/calc":
            return self._send(200, {"result": eval(q.get("expr", "0"))})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        return self._send(200, {"config": yaml.load(body, Loader=yaml.Loader)})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
PY
  echo "PyYAML==5.3.1" > app/requirements.txt
  # Insecure Dockerfile: single stage, runs as root, no HEALTHCHECK.
  cat > app/Dockerfile <<'DF'
ARG BASE_IMAGE=python:3.12-slim
FROM ${BASE_IMAGE}
WORKDIR /app
COPY requirements.txt app.py ./
RUN pip install -r requirements.txt
USER root
EXPOSE 8000
CMD ["python", "app.py"]
DF
}

write_fixed_app() {
  git checkout -q main -- app/app.py app/Dockerfile   # restore the hardened baseline
  python3.12 - <<'PY'
import re, pathlib
p = pathlib.Path("app/app.py"); s = p.read_text()
s = s.replace("import socket\n", "import socket\n\nimport yaml\n", 1)
s = s.replace("    def log_message", '''    def do_POST(self):
        if self.path != "/api/config":
            return self._send(404, {"error": "not found"})
        length = min(int(self.headers.get("Content-Length", 0)), 65536)
        try:
            return self._send(200, {"config": yaml.safe_load(self.rfile.read(length))})
        except yaml.YAMLError:
            return self._send(400, {"error": "bad request"})

    def log_message''', 1)
p.write_text(s)
PY
  echo "PyYAML==6.0.2" > app/requirements.txt
}

scenario_b() {
  banner "Scenario B: trusted signer, vulnerable change (SAST + Dockerfile + dependency)"
  fresh_branch feature/config-api
  write_vulnerable_app
  git add app
  step "B.1 signed commit (pre-commit passes: signed, no secrets — Tier 0 is not a code-quality gate)"
  git commit -q -m "feat: config API and diagnostics"
  step "B.2 push feature branch: accepted (provenance is valid)"
  expect_ok git push -q -f origin feature/config-api
  step "B.3 CI as labci: Semgrep (popen, eval, yaml.load), Checkov (root USER), Trivy/Grype (PyYAML 5.3.1)"
  expect_fail sudo -u labci /opt/lab/scripts/bin/lab-ci feature/config-api
  step "B.4 attempt to merge into main: rejected, CI record for this commit is 'fail'"
  git checkout -q main
  git merge -q --ff-only feature/config-api
  expect_fail git push origin main
  git reset -q --hard origin/main
}

scenario_c() {
  banner "Scenario C: forensic evidence"
  latest="$(ls -1dt /srv/git/ci-status/evidence/* 2>/dev/null | head -n1)"
  [[ -n "$latest" ]] || { echo "no evidence yet (run scenario b)"; return 1; }
  step "C.1 evidence package: $latest"
  jq '{run_id, commit, image, verdicts: [.verdicts[] | {tier, status}], files: (.files|length)}' "$latest/manifest.json"
  step "C.2 verify manifest.json.asc with the labci public key, then every file hash"
  /opt/lab/scripts/evidence/verify.sh "$latest"
  step "C.3 findings by tool (normalised counts)"
  jq -r '"semgrep: \(.results|length)"' "$latest/reports/semgrep.json" 2>/dev/null
  jq -r '"checkov failed: \(.results.failed_checks|length)"' "$latest/reports/results_json.json" 2>/dev/null
  jq -r '"trivy HIGH/CRITICAL: \([.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL")] | length)"' "$latest/reports/trivy.json" 2>/dev/null
  jq -r '"grype High/Critical: \([.matches[] | select(.vulnerability.severity=="High" or .vulnerability.severity=="Critical")] | length)"' "$latest/reports/grype.json" 2>/dev/null
  cat "$latest/reports/scanner-overlap.json" 2>/dev/null
  step "C.4 push audit log: decisions and hash chain"
  jq -r '"\(.ts)  \(.decision|ascii_upcase)  \(.ref)  \(.new[0:12])  \(.reason)"' /var/log/lab-audit/push.log | tail -n 10
  audit-verify
  step "C.5 DefectDojo import plan"
  jq -r '.[] | "  \(.scan_type) <- \(.file)"' "$latest/dojo-import.json"
}

scenario_d() {
  banner "Scenario D: remediation, verification, merge"
  git checkout -q feature/config-api
  write_fixed_app
  git add app
  step "D.1 signed fix: validated lookup, ast calculator, yaml.safe_load, PyYAML 6.0.2, non-root multi-stage image"
  git commit -q -m "fix: remove injection sinks, safe YAML, patched PyYAML, non-root image"
  expect_ok git push -q origin feature/config-api
  step "D.2 CI as labci: all tiers must pass"
  expect_ok sudo -u labci /opt/lab/scripts/bin/lab-ci feature/config-api || return 1
  step "D.3 fast-forward merge to main: pre-receive verifies the signed CI pass record"
  git checkout -q main; git merge -q --ff-only feature/config-api
  expect_ok git push origin main
  latest="$(ls -1dt /srv/git/ci-status/evidence/* | head -n1)"
  /opt/lab/scripts/evidence/verify.sh "$latest"
  audit-verify
}

case "${1:-all}" in
  a) scenario_a ;; a2) scenario_a2 ;; b) scenario_b ;; c) scenario_c ;; d) scenario_d ;;
  all) scenario_a; scenario_a2; scenario_b; scenario_c; scenario_d ;;
  *) echo "usage: demo.sh all|a|a2|b|c|d" >&2; exit 2 ;;
esac

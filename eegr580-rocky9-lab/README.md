# EEGR 580 — Rocky Linux 9 Containerized Secure Supply-Chain Lab

Your Rocky Linux 9 workstation image (systemd, XFCE/XRDP, Apache, PostgreSQL 16) plus a
lab layer (nested Docker, pinned scanners, gate scripts, Git hooks, labci identity) and a
four-tier gate pipeline that runs identically in the lab and on GitHub Actions.

## Quick start (Windows 11 + Docker Desktop, WSL2 backend)

```powershell
# 1. Pin inputs once (from a WSL2 shell with curl, jq, docker, gh), review, commit
bash scripts/resolve-versions.sh      # versions + SHA-256 + image digests -> versions.env
bash scripts/pin-actions.sh           # @PIN_* -> full commit SHAs in the workflow
git diff; git commit -am "pin toolchain and actions"

# 2. Point versions.env at YOUR workstation Dockerfile (pinned to a commit)
#    WORKSTATION_GIT_CONTEXT=https://github.com/<user>/<repo>.git#<40-char-sha>:<dir>
#    (or a local folder path) — LAB_USER=aaron is already set
#    Private repo: $env:GIT_AUTH_TOKEN = '<token with repo read>'

# 3. Launch
.\lab\run.ps1          # builds workstation if missing, adds lab layer, starts, runs lab-doctor
.\lab\run.ps1 -Shell   # shell as aaron
```

Inside the container:

```bash
setup-lab.sh        # lab identities, labci key, protected mock remote, signed bootstrap
demo.sh all         # Scenarios A, A2, B, C, D  (or: demo.sh a | a2 | b | c | d)
```

RDP: `mstsc /v:127.0.0.1:3390` (user `aaron`, password in `lab\secrets\lab_user_password.txt`).
HTTP test page (your Apache): `http://127.0.0.1:8080`. PostgreSQL: `psql -h 127.0.0.1 -U aaron lab`.

## Layout

| Path | Purpose |
| --- | --- |
| `versions.env` | Every pinned input (scanner versions + SHA-256, image digests) |
| `lab/Dockerfile` | Targets: `lab` (your workstation + lab layer, default), `standalone`, `toolchain` |
| `lab/docker-compose.yml`, `lab/run.ps1` | Launch spec; `run.ps1` also builds your workstation from its pinned commit |
| `scripts/provision-lab-layer.sh` | Adds only what your workstation lacks (Docker CE, git/gnupg, users, sudoers, XRDP :3390, Apache :8080) |
| `scripts/bin/lab-doctor` | Post-boot check of every lab piece (PASS/FAIL) |
| `docs/workstation-Dockerfile.recommended` | Suggested fixes for your workstation repo (digest pin, no `trust` auth) |
| `lab/rootfs/` | systemd units, first-boot and PostgreSQL bootstrap, Docker daemon config |
| `scripts/provision-rocky9.sh` | Full provisioning for the `standalone` target only |
| `scripts/install-scanners.sh` | Checksum-verified toolchain install (lab and CI) |
| `scripts/gates/tier0..3-*.sh` | Gate logic shared by lab and CI |
| `scripts/hooks/pre-commit`, `pre-receive` | Client fast-fail; server-side enforcement + audit log |
| `scripts/bin/lab-ci`, `audit-verify` | Local CI as `labci`; audit hash-chain check |
| `scripts/evidence/` | Evidence package, signature verification, DefectDojo reimport |
| `scripts/setup-lab.sh`, `scripts/demo.sh` | One-time setup and scenario driver |
| `.github/workflows/secure-supply-chain.yml` | GitHub-hosted parity pipeline |
| `.semgrep/`, `.checkov.yaml`, `.gitleaks.toml`, `.trivyignore`, `.grype.yaml`, `.zap/` | Policy (CODEOWNERS-protected) |
| `app/` | Hardened demo service (stdlib HTTP, non-root multi-stage image) |

## Reset

`.\lab\run.ps1 -Reset` deletes every lab volume (keys, database, audit log, mock remote).

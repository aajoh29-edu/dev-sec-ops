# EEGR 580 lab environment
export PATH=/opt/scanners/bin:/opt/lab/scripts/bin:$PATH
export TRIVY_CACHE_DIR=/var/cache/scanners/trivy
export GRYPE_DB_CACHE_DIR=/var/cache/scanners/grype
export SEMGREP_SEND_METRICS=off
export GPG_TTY=$(tty 2>/dev/null || true)

# EEGR 580 lab environment (login shells)
export PATH=/opt/scanners/bin:/opt/lab/scripts/bin:/opt/lab/scripts:$PATH
export TRIVY_CACHE_DIR=/var/cache/scanners/trivy
export GRYPE_DB_CACHE_DIR=/var/cache/scanners/grype
export SEMGREP_SEND_METRICS=off
GPG_TTY=$(tty 2>/dev/null || true); export GPG_TTY
alias ll='ls -l --color=auto' 2>/dev/null

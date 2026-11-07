#!/usr/bin/env bash
# Runs on EVERY boot. /etc/shadow lives in the container (not a volume), so a recreated
# container starts with the lab user locked; re-apply the password from the Docker secret.
set -euo pipefail
S=/etc/lab/secrets/lab_user_password
U="$(cat /etc/lab/lab-user)"
[[ -s "$S" ]] || { echo "missing secret $S (run.ps1 creates it)" >&2; exit 1; }
printf '%s:%s\n' "$U" "$(tr -d '\r\n' < "$S")" | chpasswd
passwd -u "$U" >/dev/null
echo "password applied for $U"

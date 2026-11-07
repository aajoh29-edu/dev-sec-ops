#!/usr/bin/env bash
# Runs once per fresh rocky9-pgdata volume. Reads credentials from Docker secrets
# (bind-mounted read-only under /etc/lab/secrets); never from ENV or image layers.
set -euo pipefail
S=/etc/lab/secrets
U="$(cat /etc/lab/lab-user)"; H="$(getent passwd "$U" | cut -d: -f6)"
for f in lab_user_password pg_user_password; do
  [[ -s "$S/$f" ]] || { echo "missing secret $S/$f (run.ps1 creates it)" >&2; exit 1; }
done

# Lab user: password only for sudo and XRDP login.
printf '%s:%s\n' "$U" "$(tr -d '\r\n' < "$S/lab_user_password")" | chpasswd
passwd -u "$U" >/dev/null
chown "$U:$U" "$H" && chmod 0700 "$H"
install -d -m 0700 -o "$U" -g "$U" "$H/.gnupg"
chown -R "$U:$U" "$H/.gnupg"
[[ -f "$H/.Xclients" ]] || install -m 0755 -o "$U" -g "$U" /etc/skel/.Xclients "$H/.Xclients"

# PostgreSQL 16: SCRAM-SHA-256 for every network login, peer for local superuser.
# Initialise only if the volume is empty; ENFORCE the auth policy every first boot,
# including when a workstation base image shipped its own cluster or pg_hba.conf.
PGDATA=/var/lib/pgsql/data
if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
  PGSETUP_INITDB_OPTIONS="--auth-local=peer --auth-host=scram-sha-256 --data-checksums" \
    postgresql-setup --initdb
fi
[[ "$(cat "$PGDATA/PG_VERSION")" == 16 ]] || { echo "pgdata is PostgreSQL $(cat "$PGDATA/PG_VERSION"), expected 16" >&2; exit 1; }
if ! grep -q '^# --- eegr580 managed ---' "$PGDATA/postgresql.conf"; then
  cat >> "$PGDATA/postgresql.conf" <<'CONF'
# --- eegr580 managed ---
listen_addresses = '*'
password_encryption = 'scram-sha-256'
log_connections = on
log_disconnections = on
CONF
fi
# Replaces any trust/md5 rules a base image may have shipped.
cat > "$PGDATA/pg_hba.conf" <<'HBA'
# --- eegr580 managed: SCRAM-SHA-256 only for password logins ---
local   all  postgres                 peer
local   all  all                      scram-sha-256
host    all  all   127.0.0.1/32       scram-sha-256
host    all  all   172.16.0.0/12      scram-sha-256
host    all  all   192.168.0.0/16     scram-sha-256
HBA
chown postgres:postgres "$PGDATA/postgresql.conf" "$PGDATA/pg_hba.conf"
chmod 0600 "$PGDATA/pg_hba.conf"

# Audit log: append-only where the filesystem allows it (ext4 volume in the Docker VM).
install -d -m 0750 -o root -g lab-git /var/log/lab-audit
touch /var/log/lab-audit/push.log
chown root:lab-git /var/log/lab-audit/push.log && chmod 0660 /var/log/lab-audit/push.log
chattr +a /var/log/lab-audit/push.log 2>/dev/null || echo "chattr +a unsupported; relying on hash chain"

# CI status store: writable only by the pipeline identity.
install -d -m 0755 -o labci -g labci /srv/git/ci-status
install -d -m 0700 -o labci -g labci /var/lib/labci/.gnupg

install -d -m 0755 /var/cache/scanners/trivy /var/cache/scanners/grype
chgrp -R docker /var/cache/scanners && chmod -R g+rwXs /var/cache/scanners

touch /var/lib/pgsql/.lab-firstboot-done

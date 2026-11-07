#!/usr/bin/env bash
# Creates the lab user's PostgreSQL role and database "lab". The password is read by
# psql's \set from the secret file, so it never appears in argv or the environment.
set -euo pipefail
U="$(cat /etc/lab/lab-user)"
psql -q -v ON_ERROR_STOP=1 -v u="$U" -d postgres <<'SQL'
\set pw `tr -d '\r\n' < /etc/lab/secrets/pg_user_password`
SET password_encryption = 'scram-sha-256';
SELECT format('CREATE ROLE %I LOGIN', :'u') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'u') \gexec
SELECT format('ALTER ROLE %I WITH PASSWORD %L', :'u', :'pw') \gexec
SELECT format('CREATE DATABASE lab OWNER %I', :'u') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'lab') \gexec
SQL
touch /var/lib/pgsql/.lab-pg-bootstrapped

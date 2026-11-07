#!/usr/bin/env bash
# provision-lab-layer.sh — add the DevSecOps lab prerequisites ON TOP OF an existing
# Rocky Linux 9 workstation image (your own Dockerfile). Idempotent: anything your
# workstation already has is left alone; only missing pieces are added.
# Runs at image build time (lab/Dockerfile, target "lab"). No secrets, no keys.
set -euo pipefail
say()  { printf '[lab-layer] %s\n' "$*"; }
die()  { printf '[lab-layer] ERROR: %s\n' "$*" >&2; exit 1; }
have() { rpm -q "$1" >/dev/null 2>&1; }
LAB_USER="${LAB_USER:-dev}"
[[ "$LAB_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid LAB_USER '$LAB_USER'"
 
# 0. Preconditions: Rocky 9 with systemd as init.
. /etc/os-release
[[ "${ID:-}" == rocky && "${VERSION_ID%%.*}" == 9 ]] || die "base is ${PRETTY_NAME:-unknown}; expected Rocky Linux 9"
have systemd || dnf -y install --setopt=install_weak_deps=False systemd systemd-sysv
say "base: $PRETTY_NAME"
 
# 1. Repository streams (no-ops when already enabled).
dnf -y install --setopt=install_weak_deps=False dnf-plugins-core
dnf config-manager --set-enabled crb
have epel-release || dnf -y install epel-release
if have postgresql-server; then
  pgmaj="$(rpm -q --qf '%{VERSION}' postgresql-server | cut -d. -f1)"
  [[ "$pgmaj" == 16 ]] || die "workstation has PostgreSQL $pgmaj; the lab requires 16 (change your Dockerfile or remove it)"
else
  dnf -y module reset postgresql && dnf -y module enable postgresql:16
fi
if ! have docker-ce; then
  have podman-docker && die "podman-docker is installed and conflicts with docker-ce; remove it from your Dockerfile"
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
fi
 
# 2. Packages the lab needs. dnf skips anything already installed.
dnf -y install --setopt=install_weak_deps=False \
  sudo passwd shadow-utils util-linux procps-ng which iproute hostname tar gzip unzip \
  rsync jq findutils diffutils file e2fsprogs ca-certificates \
  git gnupg2 pinentry openssh-clients python3.12 python3.12-pip \
  postgresql-server postgresql-contrib \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
  xrdp xorgxrdp dbus-x11
if ! have xfce4-session; then
  say "XFCE not found in workstation; installing"
  dnf -y groupinstall --setopt=group_package_types=mandatory "Xfce"
fi
 
# 3. XRDP listens on 3390 inside the container to match the 127.0.0.1:3390 binding.
sed -i -E 's/^port=[0-9]+/port=3390/' /etc/xrdp/xrdp.ini
[[ -f /etc/skel/.Xclients ]] || { echo "xfce4-session" > /etc/skel/.Xclients; chmod 0755 /etc/skel/.Xclients; }
 
# 3b. Apache (if the workstation ships it) is the HTTP test server: port 8080, quiet banner.
if have httpd; then
  sed -i -E 's/^Listen[[:space:]]+80$/Listen 8080/' /etc/httpd/conf/httpd.conf
  cat > /etc/httpd/conf.d/zz-eegr580-hardening.conf <<'HTTPD'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "DENY"
Header always set Content-Security-Policy "default-src 'self'; frame-ancestors 'none'"
HTTPD
  # mod_ssl's localhost.crt/.key are generated at FIRST BOOT by httpd-init.service, so they
  # don't exist at build time. Validate the config against a throwaway pair and delete it
  # in this same step: no private key ever lands in an image layer.
  crt=/etc/pki/tls/certs/localhost.crt; key=/etc/pki/tls/private/localhost.key; tmp=0
  if [[ -f /etc/httpd/conf.d/ssl.conf && ! -s "$crt" ]]; then
    have openssl || dnf -y install --setopt=install_weak_deps=False openssl
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=build-check \
      -keyout "$key" -out "$crt" >/dev/null 2>&1 && tmp=1
  fi
  rc=0; httpd -t || rc=$?
  [[ $tmp -eq 1 ]] && rm -f "$crt" "$key"
  [[ $rc -eq 0 ]] || die "httpd config test failed"
  say "Apache will serve the HTTP test page on 8080"
fi
 
# 4. Users and groups (create or extend; never replace yours).
getent group lab-git >/dev/null || groupadd lab-git
getent group docker  >/dev/null || groupadd docker
if id "$LAB_USER" >/dev/null 2>&1; then usermod -aG wheel,docker,lab-git "$LAB_USER"; say "extended existing user $LAB_USER"
else useradd -m -s /bin/bash -G wheel,docker,lab-git "$LAB_USER"; say "created user $LAB_USER"; fi
install -d -m 0755 /etc/lab && echo "$LAB_USER" > /etc/lab/lab-user
if id labci >/dev/null 2>&1; then usermod -aG docker labci
else useradd -r -m -d /var/lib/labci -s /sbin/nologin -G docker labci; say "created pipeline user labci"; fi
 
# A password baked into an image layer is a credential leak (threat T4). Lock it;
# lab-firstboot.service sets the lab user's password from the Docker secret at first start.
for u in "$LAB_USER" root; do
  hash="$(getent shadow "$u" | cut -d: -f2)"
  if [[ -n "$hash" && "$hash" != '!'* && "$hash" != '*'* ]]; then
    say "WARNING: user $u has a password baked into the workstation image; locking it here."
    say "         Remove the password step from your workstation Dockerfile as well."
    passwd -l "$u" >/dev/null
  fi
done
 
echo '%wheel ALL=(ALL) ALL'                                  > /etc/sudoers.d/10-wheel
echo "$LAB_USER ALL=(labci) NOPASSWD: /opt/lab/scripts/bin/lab-ci" > /etc/sudoers.d/20-lab-ci
chmod 0440 /etc/sudoers.d/10-wheel /etc/sudoers.d/20-lab-ci
visudo -cq || die "sudoers validation failed"
 
# 5. Lab directories (named volumes mount over several of these at run time).
install -d -m 2775 -g lab-git /srv/git
install -d -m 0750 /var/log/lab-audit
install -d -m 0755 /var/cache/scanners /srv/www
[[ -f /srv/www/index.html ]] || echo '<!doctype html><title>lab</title><p>EEGR 580 lab HTTP test server' > /srv/www/index.html
 
# 6. Units that cannot work in a container (harmless if your image already masked them).
systemctl mask systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
  dev-hugepages.mount sys-fs-fuse-connections.mount systemd-remount-fs.service \
  getty.target console-getty.service systemd-firstboot.service >/dev/null 2>&1 || true
 
dnf clean all && rm -rf /var/cache/dnf
say "lab prerequisites present"
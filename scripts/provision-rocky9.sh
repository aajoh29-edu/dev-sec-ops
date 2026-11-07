#!/usr/bin/env bash
# provision-rocky9.sh — build-time provisioning of the Rocky Linux 9 workstation image.
# Replaces the VM-era script: same packages and services, but no per-user secrets,
# no keys, and no machine-specific state. Runtime state is created by
# lab-firstboot.service on the named volumes.
set -euo pipefail

# 1. Repository streams: CRB, EPEL, PostgreSQL 16 module, Docker CE.
dnf -y install --setopt=install_weak_deps=False dnf-plugins-core
dnf config-manager --set-enabled crb
dnf -y install epel-release
dnf -y module reset postgresql
dnf -y module enable postgresql:16
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

# 2. Base OS, systemd, and git signing toolchain.
dnf -y install --setopt=install_weak_deps=False \
  systemd systemd-sysv procps-ng sudo passwd shadow-utils util-linux which iproute \
  hostname less vim-minimal tar gzip unzip rsync jq findutils diffutils file \
  git gnupg2 pinentry openssh-clients ca-certificates \
  python3.12 python3.12-pip e2fsprogs

# 3. Services: PostgreSQL 16, Docker engine (nested, storage on its own volume).
dnf -y install --setopt=install_weak_deps=False \
  postgresql-server postgresql-contrib \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 4. Desktop: XFCE + XRDP (EPEL). XRDP listens on 3390 inside the container too.
dnf -y groupinstall --setopt=group_package_types=mandatory "Xfce"
dnf -y install xrdp xorgxrdp dbus-x11 xfce4-terminal
sed -i 's/^port=3389/port=3390/' /etc/xrdp/xrdp.ini
echo "xfce4-session" > /etc/skel/.Xclients && chmod 0755 /etc/skel/.Xclients

# 5. Users and groups. Passwords are NOT set here (firstboot reads Docker secrets).
LAB_USER="${LAB_USER:-dev}"
groupadd -f lab-git
useradd -m -s /bin/bash -G wheel,docker,lab-git "$LAB_USER"
install -d -m 0755 /etc/lab && echo "$LAB_USER" > /etc/lab/lab-user
useradd -r -m -d /var/lib/labci -s /sbin/nologin -G docker labci   # pipeline identity
passwd -l "$LAB_USER" >/dev/null
# wheel keeps password-gated sudo; the lab user may run the CI driver as labci without a password.
echo '%wheel ALL=(ALL) ALL'                                   > /etc/sudoers.d/10-wheel
echo "$LAB_USER ALL=(labci) NOPASSWD: /opt/lab/scripts/bin/lab-ci" > /etc/sudoers.d/20-lab-ci
chmod 0440 /etc/sudoers.d/*

# 6. Lab directories (volumes mount over /srv/git and /var/log/lab-audit at run time).
install -d -m 2775 -g lab-git /srv/git
install -d -m 0750 /var/log/lab-audit
install -d -m 0755 /srv/www && echo '<!doctype html><title>lab</title><p>EEGR 580 lab HTTP test server' > /srv/www/index.html
install -d -m 0755 /var/cache/scanners

# 7. Trim units that cannot work in a container.
systemctl mask systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
  dev-hugepages.mount sys-fs-fuse-connections.mount systemd-remount-fs.service \
  getty.target console-getty.service systemd-firstboot.service || true
systemctl set-default multi-user.target

dnf clean all && rm -rf /var/cache/dnf /var/log/dnf*

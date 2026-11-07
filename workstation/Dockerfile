# Rocky Linux 9 workstation for EEGR 580
# Build (pinned): docker build --build-arg ROCKY_IMAGE=<ROCKY_IMAGE from versions.env> -t eegr580/rocky9-workstation:local .
# Build (quick):  docker build -t eegr580/rocky9-workstation:local .

# Base image. run.ps1 overrides this with the digest-pinned value from versions.env.
ARG ROCKY_IMAGE=rockylinux/rockylinux:9
FROM ${ROCKY_IMAGE}

# Init, admin tools and repositories
RUN dnf -y update && dnf -y install systemd procps-ng iproute passwd sudo dnf-plugins-core which \
 && dnf config-manager --set-enabled crb && dnf -y install epel-release && dnf clean all

# XFCE desktop, fonts, XRDP and Firefox
RUN dnf -y groupinstall "Xfce" && dnf -y install xorg-x11-xinit dbus-x11 xfce4-terminal \
      dejavu-sans-fonts dejavu-sans-mono-fonts dejavu-serif-fonts glibc-langpack-en \
      xrdp xorgxrdp tigervnc-server-minimal firefox && dnf clean all

# Apache and PostgreSQL 16
RUN dnf -y install httpd mod_ssl && dnf -y module reset postgresql \
 && dnf -y module enable postgresql:16 && dnf -y install postgresql-server postgresql-contrib && dnf clean all

# Desktop user and XFCE session for XRDP (no password in the image; set at first boot)
RUN echo "xfce4-session" > /etc/skel/.Xclients && chmod 755 /etc/skel/.Xclients \
 && useradd -m -s /bin/bash -G wheel aaron && useradd -m -s /bin/bash -G wheel dev

# Web test page and database cluster (peer for local, SCRAM-SHA-256 for network; no "trust")
COPY index.html /var/www/html/index.html
RUN su - postgres -c "initdb -D /var/lib/pgsql/data --auth-local=peer --auth-host=scram-sha-256"

# Start services at boot
RUN systemctl enable xrdp xrdp-sesman httpd postgresql

# No physical console in a container
RUN systemctl mask getty.target console-getty.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

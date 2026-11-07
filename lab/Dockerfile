# syntax=docker/dockerfile:1.7
# EEGR 580 — DevSecOps lab image
#
# Targets
#   toolchain  : pinned scanners only (built from the public Rocky 9 image).
#   lab        : DEFAULT. Your own Rocky 9 workstation image + the lab layer
#                (provision-lab-layer.sh adds only what is missing), toolchain,
#                systemd units, /opt/lab scripts and Git hooks.
#   standalone : fallback when you have no workstation image; provisions everything
#                from the public Rocky 9 image (provision-rocky9.sh).
#
# Build args (from versions.env via run.ps1)
#   ROCKY_IMAGE        public Rocky 9 by digest (toolchain + standalone)
#   WORKSTATION_IMAGE  your workstation image (local tag or registry@digest)
# No secret, key, password or token is ever passed as ARG/ENV or COPY'd here.

ARG ROCKY_IMAGE
ARG WORKSTATION_IMAGE
ARG LAB_USER=dev

FROM ${ROCKY_IMAGE} AS toolchain
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN dnf -y install --setopt=install_weak_deps=False \
        python3.12 python3.12-pip tar gzip git-core jq findutils \
 && dnf clean all && rm -rf /var/cache/dnf
COPY versions.env /opt/lab/versions.env
COPY scripts/install-scanners.sh /opt/lab/install-scanners.sh
RUN PYTHON=/usr/bin/python3.12 /opt/lab/install-scanners.sh --prefix /opt/scanners

# -----------------------------------------------------------------------------
# lab: layer onto YOUR workstation
FROM ${WORKSTATION_IMAGE} AS lab
ARG LAB_USER
USER root
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV container=docker \
    LANG=C.UTF-8 \
    PATH=/opt/scanners/bin:/opt/lab/scripts/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
COPY scripts/provision-lab-layer.sh /opt/lab/provision-lab-layer.sh
RUN LAB_USER="${LAB_USER}" /opt/lab/provision-lab-layer.sh
COPY --from=toolchain /opt/scanners /opt/scanners
COPY versions.env /opt/lab/versions.env
COPY lab/rootfs/ /
COPY scripts/ /opt/lab/scripts/
RUN chmod -R a+rX,go-w /opt/lab \
 && find /opt/lab/scripts -name '*.sh' -exec chmod 0755 {} + \
 && chmod 0755 /opt/lab/scripts/bin/* /opt/lab/scripts/hooks/* /usr/local/libexec/lab/*.sh \
 && systemctl enable lab-credentials.service lab-firstboot.service lab-pg-bootstrap.service \
        postgresql.service docker.service xrdp.service \
 && if rpm -q httpd >/dev/null; then systemctl enable httpd.service; else systemctl enable lab-http.service; fi
LABEL org.opencontainers.image.title="eegr580-rocky9-lab" \
      org.opencontainers.image.description="Rocky 9 workstation + EEGR 580 DevSecOps lab layer"
STOPSIGNAL SIGRTMIN+3
EXPOSE 3390 8080 5432
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s \
  CMD systemctl is-system-running --quiet || systemctl is-system-running | grep -q degraded
CMD ["/sbin/init"]

# -----------------------------------------------------------------------------
# standalone: everything from the public Rocky 9 image
FROM ${ROCKY_IMAGE} AS standalone
ARG LAB_USER
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV container=docker \
    LANG=C.UTF-8 \
    PATH=/opt/scanners/bin:/opt/lab/scripts/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
COPY scripts/provision-rocky9.sh /opt/lab/provision-rocky9.sh
RUN LAB_USER="${LAB_USER}" /opt/lab/provision-rocky9.sh
COPY --from=toolchain /opt/scanners /opt/scanners
COPY versions.env /opt/lab/versions.env
COPY lab/rootfs/ /
COPY scripts/ /opt/lab/scripts/
RUN chmod -R a+rX,go-w /opt/lab \
 && find /opt/lab/scripts -name '*.sh' -exec chmod 0755 {} + \
 && chmod 0755 /opt/lab/scripts/bin/* /opt/lab/scripts/hooks/* /usr/local/libexec/lab/*.sh \
 && systemctl enable lab-credentials.service lab-firstboot.service lab-pg-bootstrap.service \
        postgresql.service docker.service xrdp.service lab-http.service
STOPSIGNAL SIGRTMIN+3
EXPOSE 3390 8080 5432
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s \
  CMD systemctl is-system-running --quiet || systemctl is-system-running | grep -q degraded
CMD ["/sbin/init"]

# Multi-stage, non-root, minimal runtime. BASE_IMAGE is overridden with the
# digest-pinned value from versions.env by tier2-artifact.sh.
ARG BASE_IMAGE=python:3.12-slim
FROM ${BASE_IMAGE} AS build
WORKDIR /src
COPY requirements.txt .
RUN python -m venv /venv \
 && /venv/bin/pip install --no-cache-dir --disable-pip-version-check -r requirements.txt

FROM ${BASE_IMAGE}
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /venv /venv
COPY app.py /app/app.py
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD ["/venv/bin/python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]
ENTRYPOINT ["/venv/bin/python", "/app/app.py"]

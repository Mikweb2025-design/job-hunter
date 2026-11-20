FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DATA_DIR=/app/data \
    CONFIG_PATH=/app/config.yaml \
    TZ=Europe/Berlin

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

# Optional: opencode CLI for KI cover letters (llm.provider: opencode). Off by default so the
# image stays small; build with `--build-arg INSTALL_OPENCODE=1` (or INSTALL_OPENCODE=1 in .env
# for docker compose). Node comes from the Debian packages; the npm package ships a native binary.
ARG INSTALL_OPENCODE=0
ARG OPENCODE_VERSION=1.18.34
RUN if [ "$INSTALL_OPENCODE" = "1" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends nodejs npm ca-certificates \
      && npm install -g --omit=dev "opencode-ai@${OPENCODE_VERSION}" \
      && npm cache clean --force \
      && rm -rf /var/lib/apt/lists/* \
      && opencode --version; \
    fi

COPY jobhunter/ ./jobhunter/
COPY config.yaml ./config.yaml
COPY data/cv_profile.example.md ./seed/cv_profile.md

RUN useradd --create-home --uid 1000 jobhunter \
    && mkdir -p /app/data && chown -R jobhunter:jobhunter /app
USER jobhunter

EXPOSE 8000
HEALTHCHECK --interval=60s --timeout=5s --start-period=20s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=4).status == 200 else 1)"

# Seed the CV profile into the (empty) data volume on first start, then serve + daily scheduler.
CMD ["sh", "-c", "[ -f /app/data/cv_profile.md ] || cp /app/seed/cv_profile.md /app/data/; exec python -m jobhunter serve --host 0.0.0.0 --port 8000"]

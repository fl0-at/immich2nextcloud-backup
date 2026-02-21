# ──────────────────────────────────────────────────────────────
# immich2nextcloud-backup – Dockerfile
# ──────────────────────────────────────────────────────────────

FROM alpine:3.21

# ── Build arguments for pinning tool versions ────────────────
ARG IMMICH_GO_VERSION=0.31.0
ARG RCLONE_VERSION=1.69.1

# ── Install base dependencies ────────────────────────────────
RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      coreutils \
  findutils \
  unzip \
  tar

# ── Install rclone ───────────────────────────────────────────
RUN set -eux; \
    curl -fsSL "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.zip" \
      -o /tmp/rclone.zip; \
    unzip /tmp/rclone.zip -d /tmp; \
    cp "/tmp/rclone-v${RCLONE_VERSION}-linux-amd64/rclone" /usr/local/bin/rclone; \
    chmod +x /usr/local/bin/rclone; \
    rm -rf /tmp/rclone*; \
    unset RCLONE_VERSION || true; rclone version

# ── Install immich-go ────────────────────────────────────────
RUN set -eux; \
    curl -fsSL "https://github.com/simulot/immich-go/releases/download/v${IMMICH_GO_VERSION}/immich-go_Linux_x86_64.tar.gz" \
      -o /tmp/immich-go.tar.gz; \
    tar -xzf /tmp/immich-go.tar.gz -C /tmp; \
    cp /tmp/immich-go /usr/local/bin/immich-go; \
    chmod +x /usr/local/bin/immich-go; \
    rm -rf /tmp/immich-go*; \
    immich-go version || true

# ── Copy entrypoint script ──────────────────────────────────
COPY backup.sh /app/backup.sh
RUN chmod +x /app/backup.sh

WORKDIR /app
VOLUME ["/data"]

ENTRYPOINT ["/app/backup.sh"]

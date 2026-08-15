FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="Transmission with Cloudflare WARP"
LABEL org.opencontainers.image.description="Fail-closed Transmission container supervised with Cloudflare WARP"

RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        coreutils \
        curl \
        dbus \
        gnupg \
        iproute2 \
        nftables \
        python3 \
        tini \
        transmission-daemon \
        util-linux \
    && curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        -o /tmp/cloudflare-warp.gpg \
    && gpg --batch --yes --dearmor \
        --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
        /tmp/cloudflare-warp.gpg \
    && printf '%s\n' \
        'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ noble main' \
        > /etc/apt/sources.list.d/cloudflare-client.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cloudflare-warp \
    && install -d /usr/local/share/transmission-warp \
    && transmission-daemon --dump-settings \
        2> /usr/local/share/transmission-warp/default-settings.json \
    && python3 -m json.tool \
        /usr/local/share/transmission-warp/default-settings.json \
        > /dev/null \
    && rm -f /usr/sbin/policy-rc.d /tmp/cloudflare-warp.gpg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY \
    arr-finished-cleanup.py \
    entrypoint.sh \
    healthcheck.sh \
    update-settings.py \
    /usr/local/bin/

RUN chmod 0755 \
        /usr/local/bin/arr-finished-cleanup.py \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/healthcheck.sh \
        /usr/local/bin/update-settings.py \
    && install -d -m 0700 /root/.local/share/warp \
    && printf 'yes' > /root/.local/share/warp/accepted-tos.txt

ENV PUID=1000 \
    PGID=1000 \
    LOCAL_NETWORK=192.168.1.0/24 \
    GLOBAL_APPLY_PERMISSIONS=false \
    TRANSMISSION_HOME=/config/transmission-home \
    TRANSMISSION_DOWNLOAD_DIR=/data/completed \
    TRANSMISSION_INCOMPLETE_DIR=/data/incomplete \
    TRANSMISSION_WATCH_DIR=/data/watch \
    TRANSMISSION_UMASK=2 \
    TRANSMISSION_LOG_LEVEL=info \
    WARP_CHECK_INTERVAL=5 \
    WARP_CONNECT_TIMEOUT=60 \
    WARP_RECOVERY_INTERVAL=5 \
    WARP_STARTUP_DELAY=2 \
    ARR_CLEANUP_ENABLED=false \
    ARR_CLEANUP_DRY_RUN=false \
    ARR_CLEANUP_INTERVAL_SECONDS=120 \
    ARR_CLEANUP_MAX_SEEDING_DAYS=14 \
    ARR_SONARR_CONFIG_DIR=/arr/sonarr \
    ARR_RADARR_CONFIG_DIR=/arr/radarr \
    ARR_CLEANUP_TRANSMISSION_RPC_URL=http://127.0.0.1:9091/transmission/rpc

VOLUME ["/config", "/data", "/var/lib/cloudflare-warp"]
EXPOSE 9091

HEALTHCHECK --interval=15s --timeout=8s --start-period=90s --retries=2 \
    CMD ["/usr/local/bin/healthcheck.sh"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]

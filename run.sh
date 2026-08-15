#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi

IMAGE_NAME="${IMAGE_NAME:-local/transmission-warp:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-transmission}"
HOST_PORT="${HOST_PORT:-9092}"
LOCAL_NETWORK="${LOCAL_NETWORK:-192.168.1.0/24}"
PUID="${PUID:-$(id -u)}"
PGID="${PGID:-$(id -g)}"

DOWNLOADS_DIR="${DOWNLOADS_DIR:-/media/HDD2}"
MEDIA_DIR="${MEDIA_DIR:-/media}"
TRANSMISSION_CONFIG_DIR="${TRANSMISSION_CONFIG_DIR:-$HOME/.config/transmission}"
SONARR_CONFIG_DIR="${SONARR_CONFIG_DIR:-$HOME/.config/Sonarr}"
RADARR_CONFIG_DIR="${RADARR_CONFIG_DIR:-$HOME/.config/Radarr}"
WARP_DATA_DIR="${WARP_DATA_DIR:-$SCRIPT_DIR/data}"

ARR_CLEANUP_ENABLED="${ARR_CLEANUP_ENABLED:-true}"
ARR_CLEANUP_INTERVAL_SECONDS="${ARR_CLEANUP_INTERVAL_SECONDS:-120}"
ARR_CLEANUP_MAX_SEEDING_DAYS="${ARR_CLEANUP_MAX_SEEDING_DAYS:-14}"

if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
else
    DOCKER=(sudo docker)
fi

require_directory() {
    local name=$1
    local path=$2
    [[ -d "$path" ]] || {
        printf '%s does not exist or is not a directory: %s\n' "$name" "$path" >&2
        exit 1
    }
}

case "$ARR_CLEANUP_ENABLED" in
    true|false) ;;
    *)
        printf 'ARR_CLEANUP_ENABLED must be true or false\n' >&2
        exit 1
        ;;
esac

require_directory DOWNLOADS_DIR "$DOWNLOADS_DIR"
install -d "$TRANSMISSION_CONFIG_DIR"
install -d -m 0700 "$WARP_DATA_DIR"

if [[ "$ARR_CLEANUP_ENABLED" == "true" ]]; then
    require_directory MEDIA_DIR "$MEDIA_DIR"
    require_directory SONARR_CONFIG_DIR "$SONARR_CONFIG_DIR"
    require_directory RADARR_CONFIG_DIR "$RADARR_CONFIG_DIR"
fi

if "${DOCKER[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    printf 'Container %q already exists. Stop and remove it before switching:\n' \
        "$CONTAINER_NAME" >&2
    printf '  docker stop %q && docker rm %q\n' \
        "$CONTAINER_NAME" "$CONTAINER_NAME" >&2
    exit 1
fi

"${DOCKER[@]}" build --pull --tag "$IMAGE_NAME" "$SCRIPT_DIR"

docker_args=(
    --detach
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    --stop-timeout 30
    --log-driver json-file
    --log-opt max-size=10m
    --log-opt max-file=3
    --cap-add NET_ADMIN
    --cap-add MKNOD
    --cap-add AUDIT_WRITE
    --device-cgroup-rule 'c 10:200 rwm'
    --sysctl net.ipv6.conf.all.disable_ipv6=0
    --sysctl net.ipv4.conf.all.src_valid_mark=1
    --publish "$HOST_PORT:9091"
    --volume "$DOWNLOADS_DIR:/data"
    --volume "$TRANSMISSION_CONFIG_DIR:/config"
    --volume "$WARP_DATA_DIR:/var/lib/cloudflare-warp"
    --env "LOCAL_NETWORK=$LOCAL_NETWORK"
    --env GLOBAL_APPLY_PERMISSIONS=false
    --env "PUID=$PUID"
    --env "PGID=$PGID"
    --env TRANSMISSION_CACHE_SIZE_MB=500
    --env TRANSMISSION_DHT_ENABLED=true
    --env TRANSMISSION_ENCRYPTION=0
    --env TRANSMISSION_PEER_PORT=57848
    --env TRANSMISSION_PEX_ENABLED=true
    --env TRANSMISSION_UMASK=2
    --env "ARR_CLEANUP_ENABLED=$ARR_CLEANUP_ENABLED"
    --env "ARR_CLEANUP_INTERVAL_SECONDS=$ARR_CLEANUP_INTERVAL_SECONDS"
    --env "ARR_CLEANUP_MAX_SEEDING_DAYS=$ARR_CLEANUP_MAX_SEEDING_DAYS"
)

if [[ "$ARR_CLEANUP_ENABLED" == "true" ]]; then
    docker_args+=(
        --volume "$MEDIA_DIR:/media:ro"
        --volume "$SONARR_CONFIG_DIR:/arr/sonarr:ro"
        --volume "$RADARR_CONFIG_DIR:/arr/radarr:ro"
    )
fi

exec "${DOCKER[@]}" run "${docker_args[@]}" "$IMAGE_NAME"


#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR=/run/transmission-warp
readonly DEFAULT_SETTINGS=/usr/local/share/transmission-warp/default-settings.json
readonly WARP_STATE_DIR=/var/lib/cloudflare-warp

WARP_PID=""
TRANSMISSION_PID=""
ARR_CLEANUP_PID=""
DBUS_PID=""
STOPPING=0

log() {
    printf '%s [supervisor] %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

validate_positive_integer() {
    local name=$1
    local value=$2
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer"
}

validate_managed_path() {
    local name=$1
    local value=$2
    local root=$3
    local resolved

    [[ "$value" = /* ]] || fail "$name must be an absolute path"
    resolved="$(realpath -m -- "$value")"
    [[ "$resolved" == "$root" || "$resolved" == "$root/"* ]] \
        || fail "$name must be inside $root"
}

initialize_environment() {
    : "${PUID:=1000}"
    : "${PGID:=1000}"
    : "${LOCAL_NETWORK:=192.168.1.0/24}"
    : "${GLOBAL_APPLY_PERMISSIONS:=false}"
    : "${TRANSMISSION_HOME:=/config/transmission-home}"
    : "${TRANSMISSION_DOWNLOAD_DIR:=/data/completed}"
    : "${TRANSMISSION_INCOMPLETE_DIR:=/data/incomplete}"
    : "${TRANSMISSION_WATCH_DIR:=/data/watch}"
    : "${TRANSMISSION_LOG_LEVEL:=info}"
    : "${WARP_CHECK_INTERVAL:=5}"
    : "${WARP_CONNECT_TIMEOUT:=60}"
    : "${WARP_RECOVERY_INTERVAL:=5}"
    : "${WARP_STARTUP_DELAY:=2}"
    : "${ARR_CLEANUP_ENABLED:=false}"
    : "${ARR_CLEANUP_DRY_RUN:=false}"
    : "${ARR_CLEANUP_INTERVAL_SECONDS:=120}"
    : "${ARR_CLEANUP_MAX_SEEDING_DAYS:=14}"
    : "${ARR_SONARR_CONFIG_DIR:=/arr/sonarr}"
    : "${ARR_RADARR_CONFIG_DIR:=/arr/radarr}"
    : "${ARR_CLEANUP_TRANSMISSION_RPC_URL:=http://127.0.0.1:9091/transmission/rpc}"

    export PUID PGID
    export TRANSMISSION_HOME
    export TRANSMISSION_DOWNLOAD_DIR
    export TRANSMISSION_INCOMPLETE_DIR
    export TRANSMISSION_WATCH_DIR
    export ARR_CLEANUP_MAX_SEEDING_DAYS
    export ARR_SONARR_CONFIG_DIR
    export ARR_RADARR_CONFIG_DIR
    export ARR_CLEANUP_TRANSMISSION_RPC_URL

    validate_positive_integer PUID "$PUID"
    validate_positive_integer PGID "$PGID"
    validate_positive_integer WARP_CHECK_INTERVAL "$WARP_CHECK_INTERVAL"
    validate_positive_integer WARP_CONNECT_TIMEOUT "$WARP_CONNECT_TIMEOUT"
    validate_positive_integer WARP_RECOVERY_INTERVAL "$WARP_RECOVERY_INTERVAL"
    validate_positive_integer WARP_STARTUP_DELAY "$WARP_STARTUP_DELAY"
    validate_positive_integer ARR_CLEANUP_INTERVAL_SECONDS "$ARR_CLEANUP_INTERVAL_SECONDS"
    validate_positive_integer ARR_CLEANUP_MAX_SEEDING_DAYS "$ARR_CLEANUP_MAX_SEEDING_DAYS"

    case "$GLOBAL_APPLY_PERMISSIONS" in
        true|false) ;;
        *) fail "GLOBAL_APPLY_PERMISSIONS must be true or false" ;;
    esac

    case "$ARR_CLEANUP_ENABLED" in
        true|false) ;;
        *) fail "ARR_CLEANUP_ENABLED must be true or false" ;;
    esac

    case "$ARR_CLEANUP_DRY_RUN" in
        true|false) ;;
        *) fail "ARR_CLEANUP_DRY_RUN must be true or false" ;;
    esac

    case "$TRANSMISSION_LOG_LEVEL" in
        critical|error|warn|info|debug|trace) ;;
        *) fail "TRANSMISSION_LOG_LEVEL has an unsupported value" ;;
    esac

    validate_managed_path TRANSMISSION_HOME "$TRANSMISSION_HOME" /config
    validate_managed_path TRANSMISSION_DOWNLOAD_DIR "$TRANSMISSION_DOWNLOAD_DIR" /data
    validate_managed_path TRANSMISSION_INCOMPLETE_DIR "$TRANSMISSION_INCOMPLETE_DIR" /data
    validate_managed_path TRANSMISSION_WATCH_DIR "$TRANSMISSION_WATCH_DIR" /data

    if [[ "$ARR_CLEANUP_ENABLED" == "true" ]]; then
        [[ -r "$ARR_SONARR_CONFIG_DIR/sonarr.db" ]] \
            || fail "ARR cleanup cannot read $ARR_SONARR_CONFIG_DIR/sonarr.db"
        [[ -r "$ARR_RADARR_CONFIG_DIR/radarr.db" ]] \
            || fail "ARR cleanup cannot read $ARR_RADARR_CONFIG_DIR/radarr.db"
    fi
}

ensure_tun_device() {
    if [[ ! -c /dev/net/tun ]]; then
        install -d /dev/net
        mknod /dev/net/tun c 10 200
        chmod 0600 /dev/net/tun
    fi
}

prepare_transmission_storage() {
    local directory

    install -d /config "$TRANSMISSION_HOME"
    chown -R "$PUID:$PGID" /config

    for directory in \
        "$TRANSMISSION_DOWNLOAD_DIR" \
        "$TRANSMISSION_INCOMPLETE_DIR" \
        "$TRANSMISSION_WATCH_DIR"; do
        if [[ ! -d "$directory" ]]; then
            install -d -o "$PUID" -g "$PGID" "$directory"
        elif [[ "$GLOBAL_APPLY_PERMISSIONS" == "true" ]]; then
            chown -R "$PUID:$PGID" "$directory"
        fi
    done
}

network_family() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.ip_network(sys.argv[1], strict=False).version)
except ValueError as error:
    raise SystemExit(f"invalid network {sys.argv[1]!r}: {error}")
PY
}

add_allowed_network() {
    local network=$1
    local family

    [[ -n "$network" ]] || return 0
    family="$(network_family "$network")" || fail "LOCAL_NETWORK contains an invalid CIDR"
    if [[ "$family" == "4" ]]; then
        nft add rule inet transmission_killswitch output \
            meta skuid "$PUID" ip daddr "$network" accept
    else
        nft add rule inet transmission_killswitch output \
            meta skuid "$PUID" ip6 daddr "$network" accept
    fi
}

install_transmission_killswitch() {
    local network
    local -a networks=()

    nft delete table inet transmission_killswitch 2>/dev/null || true
    nft add table inet transmission_killswitch
    nft 'add chain inet transmission_killswitch output { type filter hook output priority -10; policy accept; }'
    nft add rule inet transmission_killswitch output \
        meta skuid "$PUID" oifname "lo" accept
    nft add rule inet transmission_killswitch output \
        meta skuid "$PUID" oifname "CloudflareWARP" accept

    IFS=',' read -r -a networks <<< "$LOCAL_NETWORK"
    for network in "${networks[@]}"; do
        network="${network//[[:space:]]/}"
        add_allowed_network "$network"
    done

    while read -r network; do
        add_allowed_network "$network"
    done < <(ip -o -4 route show dev eth0 scope link | awk '{print $1}')

    while read -r network; do
        add_allowed_network "$network"
    done < <(ip -o -6 route show dev eth0 scope link | awk '{print $1}')

    nft add rule inet transmission_killswitch output \
        meta skuid "$PUID" counter reject
    log "Transmission kill switch installed for UID $PUID"
}

start_dbus() {
    if [[ -n "$DBUS_PID" ]] && kill -0 "$DBUS_PID" 2>/dev/null; then
        return 0
    fi

    install -d /run/dbus
    rm -f /run/dbus/pid
    dbus-daemon --system --nofork --nopidfile &
    DBUS_PID=$!
    sleep 1
    kill -0 "$DBUS_PID" 2>/dev/null || fail "D-Bus failed to start"
}

warp_cli() {
    timeout 10 warp-cli --accept-tos "$@"
}

warp_is_healthy() {
    local trace

    [[ -n "$WARP_PID" ]] && kill -0 "$WARP_PID" 2>/dev/null || return 1
    trace="$(
        curl -fsS \
            --connect-timeout 3 \
            --max-time 5 \
            --interface CloudflareWARP \
            https://cloudflare.com/cdn-cgi/trace
    )" || return 1
    grep -qE '^warp=(on|plus)$' <<< "$trace"
}

terminate_process() {
    local name=$1
    local pid=$2
    local attempt

    [[ -n "$pid" ]] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        return 0
    fi

    kill -TERM "$pid"
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 0.2
    done

    log "$name did not stop gracefully; sending SIGKILL"
    kill -KILL "$pid"
    wait "$pid" 2>/dev/null || true
}

start_warp_daemon() {
    log "Starting Cloudflare WARP service"
    warp-svc --accept-tos &
    WARP_PID=$!
    printf '%s\n' "$WARP_PID" > "$STATE_DIR/warp.pid" || return 1
    sleep "$WARP_STARTUP_DELAY" || return 1
    kill -0 "$WARP_PID" 2>/dev/null
}

stop_warp_daemon() {
    if [[ -n "$WARP_PID" ]] && kill -0 "$WARP_PID" 2>/dev/null; then
        if ! warp_cli disconnect; then
            log "WARP disconnect command failed; terminating the service"
        fi
    fi
    terminate_process "WARP" "$WARP_PID"
    WARP_PID=""
    rm -f "$STATE_DIR/warp.pid"
}

configure_warp() {
    if [[ ! -s "$WARP_STATE_DIR/reg.json" ]]; then
        log "Registering a free Cloudflare WARP client"
        warp_cli registration new || return 1
    fi

    warp_cli mode warp || return 1
    warp_cli connect || return 1
}

wait_for_warp() {
    local elapsed=0

    while ((elapsed < WARP_CONNECT_TIMEOUT)); do
        ((STOPPING == 0)) || return 1
        if warp_is_healthy; then
            log "Cloudflare WARP connectivity verified"
            return 0
        fi
        if [[ -z "$WARP_PID" ]] || ! kill -0 "$WARP_PID" 2>/dev/null; then
            return 1
        fi
        sleep 2
        ((elapsed += 2))
    done
    return 1
}

recover_warp() {
    while ((STOPPING == 0)); do
        start_dbus || return 1
        if start_warp_daemon && configure_warp && wait_for_warp; then
            return 0
        fi

        log "WARP recovery attempt failed; retrying in ${WARP_RECOVERY_INTERVAL}s"
        stop_warp_daemon
        sleep "$WARP_RECOVERY_INTERVAL" || true
    done
    return 1
}

update_transmission_settings() {
    local tunnel_ipv4
    local tunnel_ipv6

    tunnel_ipv4="$(
        ip -o -4 address show dev CloudflareWARP scope global \
            | awk 'NR == 1 { split($4, address, "/"); print address[1] }'
    )" || return 1
    [[ -n "$tunnel_ipv4" ]] || fail "WARP has no IPv4 tunnel address"
    export TRANSMISSION_BIND_ADDRESS_IPV4="$tunnel_ipv4"

    tunnel_ipv6="$(
        ip -o -6 address show dev CloudflareWARP scope global \
            | awk 'NR == 1 { split($4, address, "/"); print address[1] }'
    )" || return 1
    if [[ -n "$tunnel_ipv6" ]]; then
        export TRANSMISSION_BIND_ADDRESS_IPV6="$tunnel_ipv6"
    fi

    python3 /usr/local/bin/update-settings.py \
        "$DEFAULT_SETTINGS" \
        "$TRANSMISSION_HOME/settings.json" || return 1
    chown "$PUID:$PGID" "$TRANSMISSION_HOME/settings.json" || return 1
    chmod 0600 "$TRANSMISSION_HOME/settings.json" || return 1
}

start_transmission() {
    update_transmission_settings || return 1
    log "Starting Transmission through WARP"
    setpriv \
        --reuid="$PUID" \
        --regid="$PGID" \
        --clear-groups \
        env HOME="$TRANSMISSION_HOME" \
        transmission-daemon \
            --foreground \
            --config-dir "$TRANSMISSION_HOME" \
            --log-level "$TRANSMISSION_LOG_LEVEL" &
    TRANSMISSION_PID=$!
    printf '%s\n' "$TRANSMISSION_PID" > "$STATE_DIR/transmission.pid"
    sleep 1

    if ! kill -0 "$TRANSMISSION_PID" 2>/dev/null; then
        wait "$TRANSMISSION_PID" 2>/dev/null || true
        TRANSMISSION_PID=""
        rm -f "$STATE_DIR/transmission.pid"
        return 1
    fi
}

stop_transmission() {
    if [[ -n "$TRANSMISSION_PID" ]] && kill -0 "$TRANSMISSION_PID" 2>/dev/null; then
        log "Stopping Transmission"
    fi
    terminate_process "Transmission" "$TRANSMISSION_PID"
    TRANSMISSION_PID=""
    rm -f "$STATE_DIR/transmission.pid"
}

start_arr_cleanup() {
    local runtime_dir="/run/user/$PUID"

    [[ "$ARR_CLEANUP_ENABLED" == "true" ]] || return 0
    if [[ -n "$ARR_CLEANUP_PID" ]] \
        && kill -0 "$ARR_CLEANUP_PID" 2>/dev/null; then
        return 0
    fi

    install -d -m 0700 -o "$PUID" -g "$PGID" "$runtime_dir" || return 1
    log "Starting guarded Sonarr/Radarr cleanup loop"
    (
        local -a cleanup_args=()
        if [[ "$ARR_CLEANUP_DRY_RUN" == "true" ]]; then
            cleanup_args+=(--dry-run)
        fi

        while true; do
            if ! setpriv \
                --reuid="$PUID" \
                --regid="$PGID" \
                --clear-groups \
                env \
                    HOME=/tmp \
                    XDG_RUNTIME_DIR="$runtime_dir" \
                    ARR_CLEANUP_MAX_SEEDING_DAYS="$ARR_CLEANUP_MAX_SEEDING_DAYS" \
                    ARR_SONARR_CONFIG_DIR="$ARR_SONARR_CONFIG_DIR" \
                    ARR_RADARR_CONFIG_DIR="$ARR_RADARR_CONFIG_DIR" \
                    ARR_CLEANUP_TRANSMISSION_RPC_URL="$ARR_CLEANUP_TRANSMISSION_RPC_URL" \
                python3 /usr/local/bin/arr-finished-cleanup.py \
                    "${cleanup_args[@]}"; then
                log "Sonarr/Radarr cleanup pass failed; it will retry"
            fi
            sleep "$ARR_CLEANUP_INTERVAL_SECONDS"
        done
    ) &
    ARR_CLEANUP_PID=$!
    printf '%s\n' "$ARR_CLEANUP_PID" > "$STATE_DIR/arr-cleanup.pid" || return 1
}

stop_arr_cleanup() {
    terminate_process "Sonarr/Radarr cleanup" "$ARR_CLEANUP_PID"
    ARR_CLEANUP_PID=""
    rm -f "$STATE_DIR/arr-cleanup.pid"
}

monitor_services() {
    while ((STOPPING == 0)); do
        sleep "$WARP_CHECK_INTERVAL" || true
        ((STOPPING == 0)) || return 0

        if ! warp_is_healthy; then
            log "WARP connectivity failed; taking Transmission offline"
            return 1
        fi

        if [[ -z "$TRANSMISSION_PID" ]] \
            || ! kill -0 "$TRANSMISSION_PID" 2>/dev/null; then
            wait "$TRANSMISSION_PID" 2>/dev/null || true
            TRANSMISSION_PID=""
            rm -f "$STATE_DIR/transmission.pid"
            log "Transmission exited unexpectedly; restarting it"
            if ! start_transmission; then
                log "Transmission restart failed; another attempt will follow"
            fi
        fi

        if [[ "$ARR_CLEANUP_ENABLED" == "true" ]] \
            && { [[ -z "$ARR_CLEANUP_PID" ]] \
                || ! kill -0 "$ARR_CLEANUP_PID" 2>/dev/null; }; then
            wait "$ARR_CLEANUP_PID" 2>/dev/null || true
            ARR_CLEANUP_PID=""
            rm -f "$STATE_DIR/arr-cleanup.pid"
            log "Sonarr/Radarr cleanup loop exited unexpectedly; restarting it"
            start_arr_cleanup
        fi
    done
}

request_shutdown() {
    STOPPING=1
}

cleanup() {
    set +e
    STOPPING=1
    stop_arr_cleanup
    stop_transmission
    stop_warp_daemon
    terminate_process "D-Bus" "$DBUS_PID"
    nft delete table inet transmission_killswitch 2>/dev/null
}

main() {
    initialize_environment
    trap request_shutdown TERM INT
    trap cleanup EXIT

    install -d "$STATE_DIR" "$WARP_STATE_DIR"
    ensure_tun_device
    prepare_transmission_storage
    install_transmission_killswitch

    while ((STOPPING == 0)); do
        recover_warp || break

        if ! start_transmission; then
            log "Transmission failed to start; retrying after WARP recovery"
            stop_warp_daemon
            sleep "$WARP_RECOVERY_INTERVAL" || true
            continue
        fi

        start_arr_cleanup
        monitor_services || true
        stop_transmission
        stop_warp_daemon
        if ((STOPPING == 0)); then
            sleep "$WARP_RECOVERY_INTERVAL" || true
        fi
    done
}

main "$@"

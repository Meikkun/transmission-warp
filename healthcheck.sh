#!/usr/bin/env bash
set -Eeuo pipefail

state_dir=/run/transmission-warp

for process in warp transmission; do
    pid_file="${state_dir}/${process}.pid"
    [[ -s "$pid_file" ]] || exit 1
    read -r pid < "$pid_file"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || exit 1
    kill -0 "$pid" 2>/dev/null || exit 1
done

trace="$(
    curl -fsS \
        --connect-timeout 3 \
        --max-time 5 \
        --interface CloudflareWARP \
        https://cloudflare.com/cdn-cgi/trace
)" || exit 1

grep -qE '^warp=(on|plus)$' <<< "$trace"


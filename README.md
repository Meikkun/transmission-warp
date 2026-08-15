# Transmission over Cloudflare WARP

A self-contained Docker image that runs Transmission only through the official
Cloudflare WARP Linux client. It fails closed: if WARP or internet connectivity
fails, Transmission traffic is blocked immediately, Transmission is stopped,
and both services are recovered in the correct order.

## Why this exists

Most Transmission VPN images expect a paid OpenVPN or WireGuard provider. This
project uses the free consumer version of Cloudflare WARP instead while keeping
the operational safeguards expected from a VPN-routed torrent container:

- Transmission starts only after `warp=on` is verified.
- An nftables kill switch prevents Transmission from falling back to the normal
  Docker interface.
- A supervisor stops Transmission when WARP fails.
- WARP is restarted and reconnected automatically.
- Transmission resumes only after the tunnel is verified again.
- Docker restarts the whole container if its supervisor exits.
- Optional Sonarr/Radarr cleanup handles a Transmission 4 seed-ratio mismatch.

> [!IMPORTANT]
> Cloudflare WARP is not an anonymity service and does not provide inbound port
> forwarding. Review Cloudflare's terms and privacy model before using it.

## Requirements

- Linux host with Docker
- A kernel that supports TUN devices and nftables
- Permission to run Docker directly or through `sudo`
- A local directory for Transmission state and downloads
- Sonarr/Radarr config directories only if guarded cleanup is enabled

## Quick start

```bash
git clone https://github.com/Meikkun/transmission-warp.git
cd transmission-warp
cp .env.example .env
```

Edit `.env`, especially:

```dotenv
DOWNLOADS_DIR=/path/to/download-storage
TRANSMISSION_CONFIG_DIR=/home/your-user/.config/transmission
LOCAL_NETWORK=192.168.1.0/24
```

Then start the container:

```bash
./run.sh
```

The default Web UI address is:

```text
http://localhost:9092
```

The launcher deliberately refuses to replace an existing container named
`transmission`. Replace an older instance explicitly:

```bash
docker stop transmission
docker rm transmission
./run.sh
```

All persistent Transmission and WARP state remains in bind-mounted host
directories.

## Main configuration

| Variable | Default | Purpose |
|---|---:|---|
| `DOWNLOADS_DIR` | `/media/HDD2` | Host directory mounted read-write at `/data` |
| `TRANSMISSION_CONFIG_DIR` | `~/.config/transmission` | Persistent Transmission state |
| `WARP_DATA_DIR` | `./data` | Private WARP registration and state |
| `LOCAL_NETWORK` | `192.168.1.0/24` | LAN allowed to reach the Web UI |
| `HOST_PORT` | `9092` | Host port mapped to Transmission port `9091` |
| `PUID` / `PGID` | Current user | UID/GID used by Transmission |
| `CONTAINER_NAME` | `transmission` | Docker container name |
| `IMAGE_NAME` | `local/transmission-warp:latest` | Locally built image tag |

See [Operations](docs/OPERATIONS.md) for all cleanup variables and common
administrative commands.

## Guarded Sonarr/Radarr cleanup

Transmission 4 can stop at a displayed ratio of `2.0` while Sonarr/Radarr
calculate a slightly lower ratio from raw byte counters. Arr then never marks
the imported torrent as removable.

When `ARR_CLEANUP_ENABLED=true`, the built-in cleanup loop removes a torrent
only when all applicable safeguards pass:

1. The torrent is complete and has no Transmission error.
2. Transmission marks it stopped and finished, **or** it has accumulated the
   configured number of seeding days.
3. The torrent matches the configured Transmission client in Sonarr or Radarr.
4. The latest Arr download-history event says the download was imported.
5. Every imported library file recorded by Arr still exists.
6. Completed-download removal remains enabled for that Arr client.

The Arr databases and `/media` are mounted read-only. Transmission still has
read-write access to downloads through `/data`; cleanup deletion is requested
through Transmission's own RPC interface.

Preview cleanup decisions without deleting anything:

```bash
docker exec transmission \
  /usr/local/bin/arr-finished-cleanup.py --dry-run
```

## Verify operation

Check overall health:

```bash
docker inspect --format '{{.State.Health.Status}}' transmission
```

Verify WARP directly:

```bash
docker exec transmission curl -fsS --interface CloudflareWARP \
  https://cloudflare.com/cdn-cgi/trace | grep '^warp='
```

Expected output:

```text
warp=on
```

Check the WARP-routed public IPv4 address:

```bash
docker exec transmission curl -4fsS --interface CloudflareWARP \
  https://api.ipify.org && echo
```

Follow supervisor and cleanup logs:

```bash
docker logs -f transmission
```

## Documentation

- [Implementation guide](docs/IMPLEMENTATION.md) — architecture, control flow,
  design decisions, safeguards, and limitations
- [Operations guide](docs/OPERATIONS.md) — configuration, verification,
  upgrades, recovery tests, and troubleshooting


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
| `MEDIA_DIR` | `/media` | Host media library mounted read-only at `/media` |
| `SONARR_CONFIG_DIR` | `~/.config/Sonarr` | Host Sonarr config directory containing `sonarr.db` |
| `RADARR_CONFIG_DIR` | `~/.config/Radarr` | Host Radarr config directory containing `radarr.db` |
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

### How Arr monitoring works

The cleaner does not call the Sonarr or Radarr APIs and does not watch their
directories for changes. Every `ARR_CLEANUP_INTERVAL_SECONDS` seconds, it reads
both applications' SQLite databases and compares their records with the live
torrent list returned by Transmission RPC.

When cleanup is enabled, `run.sh` creates these bind mounts:

| Host path | Container path | Access | Used for |
|---|---|---|---|
| `SONARR_CONFIG_DIR` | `/arr/sonarr` | Read-only | Reads `sonarr.db` |
| `RADARR_CONFIG_DIR` | `/arr/radarr` | Read-only | Reads `radarr.db` |
| `MEDIA_DIR` | `/media` | Read-only | Confirms imported library files still exist |
| `DOWNLOADS_DIR` | `/data` | Read-write | Transmission's download data |

A bind mount exposes an existing host directory inside the container; it does
not copy the directory. The `:ro` mount option makes the view read-only, and the
cleaner also opens each SQLite database with SQLite's read-only mode. It can
therefore inspect Arr configuration and history, but cannot change Arr settings,
database records, or media-library files.

For each otherwise eligible torrent, the cleaner:

1. Reads enabled Transmission download clients from both Arr databases.
2. Keeps only clients pointing to this host's Transmission service with
   completed-download removal enabled.
3. Matches the torrent to the client's category/label or download directory.
4. Looks up the torrent hash and requires its latest matching
   `DownloadHistory` event to be an import.
5. Reads every `importedPath` recorded for that hash and confirms each file is
   visible through the read-only media mount.
6. Proceeds only when exactly one of Sonarr or Radarr supplies all that
   evidence.
7. Repeats the checks immediately before asking Transmission RPC to remove the
   torrent with its download data.

The cleaner never directly deletes a path. Transmission performs the deletion
through its own RPC interface; its downloaded payload is on the separately
mounted read-write `/data` tree, while the imported media library remains
read-only.

`SONARR_CONFIG_DIR` and `RADARR_CONFIG_DIR` must be host paths, even when Arr
runs in another container; use the host directories mounted as `/config` in
those containers. Arr's recorded `importedPath` values must be below `/media`
inside this container. For example, if Arr records
`/media/tv/Example/episode.mkv`, then
`$MEDIA_DIR/tv/Example/episode.mkv` must be the corresponding host file.

Both Arr database directories are currently required when cleanup is enabled.
Set `ARR_CLEANUP_ENABLED=false` when the guarded cleanup is not needed.

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

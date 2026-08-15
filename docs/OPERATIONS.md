# Operations Guide

## Configure the launcher

`run.sh` reads an optional `.env` file in the project directory. Start from the
example:

```bash
cp .env.example .env
```

### Host and container variables

| Variable | Default | Notes |
|---|---:|---|
| `DOWNLOADS_DIR` | `/media/HDD2` | Mounted read-write as `/data` |
| `TRANSMISSION_CONFIG_DIR` | `~/.config/transmission` | Persistent torrent state |
| `WARP_DATA_DIR` | `./data` | Private WARP registration; never commit it |
| `MEDIA_DIR` | `/media` | Read-only library view for cleanup |
| `SONARR_CONFIG_DIR` | `~/.config/Sonarr` | Read-only Sonarr database mount |
| `RADARR_CONFIG_DIR` | `~/.config/Radarr` | Read-only Radarr database mount |
| `LOCAL_NETWORK` | `192.168.1.0/24` | LAN allowed outside WARP |
| `HOST_PORT` | `9092` | Transmission Web UI host port |
| `PUID` | Current UID | Transmission process identity |
| `PGID` | Current GID | Transmission group identity |
| `CONTAINER_NAME` | `transmission` | Docker name |
| `IMAGE_NAME` | `local/transmission-warp:latest` | Local image tag |

### Cleanup variables

| Variable | Default | Notes |
|---|---:|---|
| `ARR_CLEANUP_ENABLED` | `true` in `run.sh` | Set `false` if Arr is not used |
| `ARR_CLEANUP_INTERVAL_SECONDS` | `120` | Time between guarded passes |
| `ARR_CLEANUP_MAX_SEEDING_DAYS` | `14` | Actual accumulated seeding time |

When cleanup is disabled, the launcher does not require or mount Arr and media
directories.

## Start

```bash
./run.sh
```

The script builds the local image before starting it.

## Stop and start again

```bash
docker stop transmission
docker start transmission
```

The supervisor reconnects WARP and verifies the tunnel before starting
Transmission.

## Replace or rebuild

The launcher refuses to replace an existing container. To deploy a rebuilt
image:

```bash
docker stop transmission
docker rm transmission
./run.sh
```

Bind-mounted settings, torrents, downloads, and WARP registration remain on the
host.

## Check health

```bash
docker inspect --format '{{.State.Health.Status}}' transmission
```

Expected result:

```text
healthy
```

## Verify WARP

```bash
docker exec transmission curl -fsS --interface CloudflareWARP \
  https://cloudflare.com/cdn-cgi/trace | grep '^warp='
```

Expected:

```text
warp=on
```

`warp=plus` is also accepted by the implementation.

## Check the public IP

```bash
docker exec transmission curl -4fsS --interface CloudflareWARP \
  https://api.ipify.org && echo
```

Compare this with a request made directly on the host if you need to confirm
that the addresses differ.

## Read logs

```bash
docker logs --tail 200 transmission
docker logs -f transmission
```

Supervisor messages contain `[supervisor]`. Cleanup messages contain
`[arr-finished-cleanup]`.

Docker JSON logs are rotated at 10 MB with three retained files by `run.sh`.

## Preview Arr cleanup

```bash
docker exec transmission \
  /usr/local/bin/arr-finished-cleanup.py --dry-run
```

The dry run performs all database, history, library-file, and torrent-state
checks without requesting deletion.

## Controlled recovery test

The following command deliberately disconnects the test or production tunnel:

```bash
docker exec transmission warp-cli --accept-tos disconnect
```

Watch recovery:

```bash
docker logs -f transmission
```

Expected sequence:

1. WARP connectivity fails.
2. Transmission is taken offline.
3. WARP restarts and reconnects.
4. The trace check succeeds.
5. Transmission restarts.

Do not run this during time-sensitive downloads unless a brief interruption is
acceptable.

## Common problems

### Container name already exists

The launcher will print:

```text
Container transmission already exists.
```

Inspect it before replacement:

```bash
docker ps -a --filter name=transmission
```

Then stop and remove only that container if appropriate.

### TUN permission error

Confirm the host supports the TUN device:

```bash
ls -l /dev/net/tun
```

The launcher adds `MKNOD`, `NET_ADMIN`, and the device cgroup rule required to
create or access it.

### WARP never becomes healthy

Read logs:

```bash
docker logs --tail 300 transmission
```

Check ordinary host connectivity and confirm Cloudflare WARP is usable from
your network. Persistent registration is in `WARP_DATA_DIR`.

### Web UI is unreachable

Check:

- `HOST_PORT` is not already used;
- `LOCAL_NETWORK` includes the client LAN;
- Transmission health is `healthy`; and
- the host firewall permits the selected port.

### Cleanup pass fails

Check that:

- cleanup is enabled;
- Sonarr and Radarr database paths exist;
- the config mounts are read-only but readable by `PUID`;
- imported paths are visible below `MEDIA_DIR`; and
- both Arr Transmission clients still point to the published local service.

Cleanup failure does not stop WARP or Transmission. It retries on the next
interval.

### Cleanup does not select a torrent

A torrent is intentionally skipped if any guard is missing. Use dry-run mode
and check:

- completed state;
- `isFinished`, or accumulated seeding days;
- Arr category or directory match;
- latest imported download-history event; and
- existence of every recorded imported library file.

## Back up state

Stop the container before a consistent manual backup:

```bash
docker stop transmission
```

Back up:

- `TRANSMISSION_CONFIG_DIR`;
- `WARP_DATA_DIR`; and
- download data according to your normal storage policy.

The WARP state directory contains private registration material. Store backups
accordingly and never commit that directory.


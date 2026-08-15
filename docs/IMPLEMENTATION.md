# Implementation Guide

## 1. Executive Summary

This project packages three responsibilities into one Docker container:

1. The official Cloudflare WARP Linux client creates an encrypted network
   tunnel.
2. Transmission downloads and seeds torrents through that tunnel.
3. A Bash supervisor controls startup, shutdown, health checks, recovery, and
   optional Sonarr/Radarr cleanup.

The main problem being solved is accidental network fallback. A normal process
may return to the ordinary Docker network when a tunnel fails. That would expose
Transmission traffic through the host's regular public IP address. This image
uses both process supervision and an nftables firewall rule so that Transmission
cannot use that fallback path.

The implementation also contains an optional cleanup workaround for a known
behavioral mismatch between Transmission 4 and Arr applications. "Arr" is the
common name for media automation applications such as Sonarr and Radarr.

## 2. High-Level Overview

### Plain-English mental model

Think of the container as a room with two doors:

- `eth0` is the normal Docker network door.
- `CloudflareWARP` is the protected tunnel door.

The WARP service is allowed to use the normal door because it must contact
Cloudflare to establish and repair the tunnel. Transmission is a different
Linux user, and the firewall only allows that user to use:

- the WARP door,
- the local loopback interface, and
- explicitly allowed local networks.

If WARP disappears, Transmission cannot walk through `eth0`. Its traffic is
rejected by the kernel before the supervisor even finishes detecting the
failure.

### Main components

```text
                         Docker restart policy
                                  |
                                  v
                         Bash supervisor (PID 1)
                         /        |          \
                        /         |           \
                 warp-svc   Transmission   Arr cleanup loop
                    |            |               |
                    v            v               v
             CloudflareWARP   /data        read-only Arr DBs
                    |                            |
                    +-------- Internet          +-> Transmission RPC
```

`tini` is the actual first process in the container. It forwards Unix signals
and reaps exited child processes. It starts `entrypoint.sh`, which performs the
supervision work.

## 3. Features and Functionality

### Verified tunnel-gated startup

Transmission is not started merely because `warp-svc` is running. The
supervisor performs an HTTPS request through the `CloudflareWARP` interface and
requires Cloudflare's trace endpoint to return `warp=on` or `warp=plus`.

This matters because a running daemon does not guarantee a working tunnel.

### Owner-scoped network kill switch

`entrypoint.sh` creates an nftables output chain named
`transmission_killswitch`. Rules use `meta skuid` to match only the configured
Transmission UID.

The UID may send traffic through:

- `lo`, the local loopback interface;
- `CloudflareWARP`;
- `LOCAL_NETWORK`; and
- the directly connected Docker subnet.

All other output for that UID is rejected. Root-owned WARP processes remain
able to repair the tunnel through `eth0`.

### Automatic WARP recovery

The supervisor checks WARP on a configurable interval. After the first failed
check it:

1. stops Transmission;
2. disconnects and terminates the WARP daemon;
3. starts WARP again;
4. registers the client if persistent registration does not yet exist;
5. selects full WARP mode and connects;
6. verifies `warp=on`; and
7. restarts Transmission.

If internet connectivity is unavailable, recovery retries continue without
starting Transmission.

### Automatic Transmission recovery

The supervisor also checks whether the Transmission process exits while WARP
is healthy. If it does, the settings are regenerated safely and Transmission
is started again.

### Persistent state

Three important paths are outside the image:

| Container path | Data |
|---|---|
| `/config` | Transmission settings, resume data, torrent metadata, and state |
| `/data` | Downloaded and incomplete files |
| `/var/lib/cloudflare-warp` | WARP registration and client state |

Rebuilding or replacing the container does not remove these bind-mounted files.

### Health reporting

Docker runs `healthcheck.sh` every 15 seconds. It verifies:

- the recorded WARP PID exists;
- the recorded Transmission PID exists; and
- a request bound to `CloudflareWARP` returns `warp=on` or `warp=plus`.

Docker health status is useful for observation. The internal supervisor is
responsible for recovery because Docker restart policies do not restart a
container merely because it is marked unhealthy.

### Guarded Sonarr/Radarr cleanup

The optional `arr-finished-cleanup.py` process works around seed-ratio counter
differences. It never removes a torrent based only on its name or age.

Before requesting removal, it requires:

- a completed torrent with no Transmission error;
- either a stopped and `isFinished` state, or enough accumulated
  `secondsSeeding`;
- a matching enabled Transmission client in the Arr database;
- `RemoveCompletedDownloads` enabled for that client;
- the latest matching `DownloadHistory` event to be `DownloadImported`;
- a matching category, label, or configured download directory; and
- all imported library paths recorded in Arr history to still be files.

The cleanup then asks Transmission to run `torrent-remove` with
`delete-local-data=true`. It does not directly delete filesystem paths.

## 4. Architecture and Structure

### `Dockerfile`

Builds from Ubuntu 24.04 and installs:

- Cloudflare's official `cloudflare-warp` package;
- Transmission daemon;
- nftables and IP routing tools;
- D-Bus, which WARP requires;
- Python 3 for settings and cleanup helpers; and
- `tini` for process lifecycle handling.

It generates and validates a default Transmission settings document during the
image build. Runtime scripts are copied to `/usr/local/bin`.

### `entrypoint.sh`

This is the main state machine.

Important function groups include:

- validation: `initialize_environment`, `validate_positive_integer`, and
  `validate_managed_path`;
- storage and firewall setup: `prepare_transmission_storage` and
  `install_transmission_killswitch`;
- WARP lifecycle: `start_warp_daemon`, `configure_warp`, `wait_for_warp`, and
  `recover_warp`;
- Transmission lifecycle: `update_transmission_settings`,
  `start_transmission`, and `stop_transmission`;
- cleanup lifecycle: `start_arr_cleanup` and `stop_arr_cleanup`; and
- shutdown: `request_shutdown` and `cleanup`.

PID files under `/run/transmission-warp` let the health check identify the
specific child processes managed by this supervisor.

### `healthcheck.sh`

Provides Docker's health result. It does not attempt recovery and does not
change configuration.

### `update-settings.py`

Combines:

1. defaults generated by the installed Transmission version;
2. an existing persistent `settings.json`; and
3. matching `TRANSMISSION_*` environment variables.

Values are converted to the type already used by the setting. Booleans accept
only `true` or `false`; invalid numbers or JSON values stop startup. The final
file is replaced atomically so an interruption cannot leave half-written JSON.

### `arr-finished-cleanup.py`

Reads Sonarr and Radarr SQLite databases in read-only mode. It uses their
`DownloadClients`, `DownloadHistory`, and `History` tables to prove that a
torrent belongs to an enabled Transmission client and was imported.

It communicates with Transmission through its JSON RPC endpoint on loopback.
It includes a non-blocking file lock so overlapping cleanup passes cannot run.

### `run.sh`

Provides a repeatable local build and `docker run` command. It:

- reads optional values from `.env`;
- validates required host directories;
- protects the WARP state directory with restrictive permissions;
- refuses to replace an existing named container implicitly;
- builds the image;
- adds only the capabilities required by WARP and nftables;
- creates persistent mounts; and
- adds Arr and media mounts only when cleanup is enabled.

### `.gitignore` and `.dockerignore`

The `data/` directory is excluded because it contains the private WARP
registration. `.env` is also excluded because users may put machine-specific
paths or future sensitive values there.

## 5. Data Flow / Control Flow

### Container startup

1. `tini` starts `entrypoint.sh`.
2. Environment values and managed paths are validated.
3. `/dev/net/tun` is created if Docker did not provide it.
4. Persistent directories are prepared with the configured UID and GID.
5. The owner-scoped nftables kill switch is installed.
6. D-Bus and `warp-svc` are started.
7. WARP registration is created only when `reg.json` is absent.
8. Full WARP mode is selected and connected.
9. The trace endpoint is requested through `CloudflareWARP`.
10. Transmission settings are merged and bound to the current WARP addresses.
11. Transmission starts as the unprivileged configured UID.
12. If enabled, the Arr cleanup loop starts and each cleanup pass also runs as
    the configured UID.
13. The supervisor begins its monitoring loop.

### Tunnel failure

1. The WARP probe fails or `warp-svc` exits.
2. The nftables rule already prevents Transmission from using `eth0`.
3. The supervisor stops Transmission gracefully.
4. WARP is disconnected and terminated.
5. Recovery waits and retries until the tunnel is verifiably usable.
6. Transmission restarts with the current tunnel addresses.

### Settings update

1. The built-in defaults are loaded.
2. Existing settings override those defaults.
3. known `TRANSMISSION_*` values override matching settings.
4. Dynamic WARP bind addresses override the peer bind addresses.
5. A temporary JSON file is written.
6. The temporary file atomically replaces `settings.json`.
7. Ownership and mode `0600` are applied.

### Arr cleanup pass

1. The script acquires a lock.
2. Both Arr databases are opened read-only.
3. Enabled local Transmission clients with removal enabled are loaded.
4. Transmission returns its current torrent list.
5. Ineligible, incomplete, errored, or insufficiently seeded torrents are
   ignored.
6. The torrent hash is matched against Arr download history.
7. The latest event and imported library files are validated.
8. The torrent state and Arr guard are rechecked to reduce race conditions.
9. Transmission receives the removal request.

## 6. Design Decisions

### One network namespace

WARP and Transmission run in one container rather than separate containers.
This avoids stale shared-network namespaces during sidecar restarts and lets one
supervisor control the exact startup order.

Tradeoff: the image has more than one long-running process, so it needs explicit
supervision rather than the usual one-process container model.

### Internal recovery instead of health-only recovery

Docker marks unhealthy containers but does not restart them automatically.
Recovery therefore lives in `entrypoint.sh`; Docker's restart policy is a
second layer for supervisor-level failure.

### UID-based firewall rules

Blocking only Transmission allows WARP to use the ordinary network for tunnel
repair. A blanket output block would also prevent recovery.

Tradeoff: other processes running with the same UID receive the same network
restrictions. The image deliberately runs only Transmission and cleanup work
under that UID.

### Runtime configuration instead of build-time configuration

The image includes cleanup support but `ARR_CLEANUP_ENABLED` controls it at
container startup. The same image can therefore be reused on hosts with or
without Arr applications.

### Read-only Arr and library views

The cleanup process needs evidence that import completed, but it does not need
to edit Arr configuration or library files. Read-only mounts reduce the effect
of a cleanup bug.

### Fail-closed cleanup

Missing databases, invalid JSON, missing history, missing imported files,
ambiguous Arr matches, or RPC errors prevent deletion. This may leave stale
downloads, but it is safer than deleting an unverified download.

## 7. Dependencies and External Connections

| Dependency | Role |
|---|---|
| Docker | Builds and isolates the application |
| Ubuntu 24.04 | Base operating system |
| Cloudflare WARP package repository | Supplies the official Linux client |
| `warp-svc` / `warp-cli` | Creates and manages the tunnel |
| Transmission 4 | Torrent client and JSON RPC server |
| nftables | Kernel firewall kill switch |
| D-Bus | Local IPC service required by WARP |
| Python 3 standard library | JSON settings, SQLite checks, and HTTP RPC |
| Sonarr/Radarr SQLite databases | Import and download-client evidence |
| Cloudflare trace endpoint | Confirms traffic is actually using WARP |

The runtime makes HTTPS requests to Cloudflare's trace endpoint. Optional
operator commands may query `api.ipify.org`, but the application itself does
not depend on that service.

## 8. Error Handling and Edge Cases

- Invalid UID, GID, intervals, booleans, log levels, or managed paths stop
  startup with an explicit error.
- A malformed existing Transmission settings file is not silently replaced.
- The WARP client is not re-registered merely because connection fails.
- WARP connection attempts have timeouts and retry delays.
- Transmission receives a graceful termination signal before forced shutdown.
- The kill switch remains active while Transmission is stopping.
- Cleanup errors are logged and retried on the next interval.
- Cleanup state is re-read immediately before deletion.
- An ambiguous match between Sonarr and Radarr is skipped.
- The launcher refuses to remove or overwrite an existing container.

One deliberate behavior is that an unavailable Arr database causes cleanup to
fail while Transmission and WARP continue operating. Cleanup is optional and
must not take the torrent client offline.

## 9. How to Use or Operate It

1. Copy `.env.example` to `.env`.
2. Set host directories and `LOCAL_NETWORK`.
3. Run `./run.sh`.
4. Wait for Docker health to become `healthy`.
5. Confirm `warp=on`.
6. Use Transmission through the published Web UI port.

Typical checks:

```bash
docker inspect --format '{{.State.Health.Status}}' transmission
docker logs -f transmission
docker exec transmission curl -fsS --interface CloudflareWARP \
  https://cloudflare.com/cdn-cgi/trace | grep '^warp='
```

See `docs/OPERATIONS.md` for replacement, upgrades, cleanup settings, controlled
failure testing, and troubleshooting.

## 10. Beginner Glossary

**Arr**
: A family of media automation applications. Sonarr manages television
  downloads; Radarr manages movie downloads.

**Bind mount**
: A host directory exposed at a specific path inside a container.

**D-Bus**
: A local message system used by Linux applications to communicate.

**Fail closed**
: When something fails, access is blocked instead of silently becoming less
  secure.

**Health check**
: A periodic command that reports whether a container is functioning.

**Kill switch**
: A firewall rule that prevents traffic from bypassing a failed tunnel.

**Network namespace**
: An isolated set of network interfaces, routes, and firewall rules.

**nftables**
: The modern Linux firewall system used to accept or reject packets.

**PID**
: Process identifier, a number assigned to a running Linux process.

**RPC**
: Remote procedure call. Transmission exposes an HTTP JSON API that allows
  trusted programs to query and control torrents.

**Seeding**
: Uploading pieces of an already completed torrent to other peers.

**TUN device**
: A virtual network interface used by VPN and tunnel software.

**UID/GID**
: Numeric Linux user and group identities used for permissions and firewall
  ownership checks.

## 11. Limitations and Future Improvements

- Cloudflare WARP provides no inbound torrent port forwarding.
- WARP is not designed or represented here as an anonymity service.
- The image has been designed for Linux Docker hosts; other container runtimes
  and non-Linux hosts are not covered.
- Cleanup depends on current Sonarr/Radarr SQLite table and event semantics.
  Future Arr schema changes may require updates.
- The cleanup existence guard assumes Arr's recorded `importedPath` is visible
  below the configured read-only `MEDIA_DIR` mount.
- The launcher builds directly on the target host and currently has no
  continuous-integration workflow or published multi-architecture image.
- WARP and Transmission package versions are selected by the configured APT
  repositories at build time rather than pinned to exact package versions.
- There is no project license yet, so normal copyright defaults apply.

Potential future work includes automated integration tests, package-version
pinning, narrower per-library read-only mounts, and release image publishing.

## 12. Open Questions / Assumptions

- The default download and media paths are examples and must be adapted to each
  host.
- The configured Sonarr/Radarr Transmission clients are expected to refer to
  this local container's published port.
- The operator is responsible for ensuring their use of WARP and BitTorrent
  complies with applicable terms and laws.
- No decision has been made about an open-source license.
- Only consumer WARP behavior is documented; Cloudflare Zero Trust enrollment
  has not been implemented or tested.


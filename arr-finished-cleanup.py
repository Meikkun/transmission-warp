#!/usr/bin/env python3

import argparse
import fcntl
import json
import os
import sqlite3
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any


DEFAULT_TRANSMISSION_RPC_URL = "http://127.0.0.1:9092/transmission/rpc"
TRANSMISSION_STOPPED = 0
TRANSMISSION_SEED_WAIT = 5
TRANSMISSION_SEEDING = 6
DOWNLOAD_IMPORTED = 2
HISTORY_IMPORTED = 3


def log(message: str) -> None:
    timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"{timestamp} [arr-finished-cleanup] {message}", flush=True)


@dataclass(frozen=True)
class DownloadClient:
    client_id: int
    category: str
    directory: str


class ArrInstance:
    def __init__(
        self,
        name: str,
        config_dir: Path,
        category_field: str,
        directory_field: str,
    ) -> None:
        self.name = name
        self.config_dir = config_dir
        self.category_field = category_field
        self.directory_field = directory_field
        self.database_path = config_dir / f"{name.lower()}.db"
        self.clients = self._load_clients()

    def _load_clients(self) -> list[DownloadClient]:
        clients: list[DownloadClient] = []
        connection = sqlite3.connect(
            f"file:{self.database_path}?mode=ro",
            uri=True,
        )
        try:
            definitions = connection.execute(
                """
                SELECT Id, Settings
                FROM DownloadClients
                WHERE Implementation = 'Transmission'
                  AND Enable = 1
                  AND RemoveCompletedDownloads = 1
                """
            ).fetchall()

            for client_id, raw_settings in definitions:
                settings = json.loads(raw_settings)
                host = str(settings.get("host") or "").lower()
                port = int(settings.get("port") or 0)
                use_ssl = bool(settings.get("useSsl"))
                url_base = (
                    "/" + str(settings.get("urlBase") or "").strip("/") + "/"
                )
                if (
                    host not in {"localhost", "127.0.0.1"}
                    or port != 9092
                    or use_ssl
                    or url_base != "/transmission/"
                ):
                    log(
                        f"{self.name}: skipping Transmission client "
                        f"{client_id} because it does not target the local container"
                    )
                    continue

                clients.append(
                    DownloadClient(
                        client_id=int(client_id),
                        category=str(settings.get(self.category_field) or ""),
                        directory=str(settings.get(self.directory_field) or ""),
                    )
                )
        finally:
            connection.close()

        return clients

    def matching_import(self, torrent: dict[str, Any]) -> bool:
        if not self.clients:
            return False

        connection = sqlite3.connect(
            f"file:{self.database_path}?mode=ro",
            uri=True,
        )
        try:
            for client in self.clients:
                if not self._matches_client_scope(client, torrent):
                    continue

                row = connection.execute(
                    """
                    SELECT EventType
                    FROM DownloadHistory
                    WHERE lower(DownloadId) = lower(?)
                      AND DownloadClientId = ?
                    ORDER BY Date DESC, Id DESC
                    LIMIT 1
                    """,
                    (torrent["hashString"], client.client_id),
                ).fetchone()
                if row is None or row[0] != DOWNLOAD_IMPORTED:
                    continue

                if self._imported_library_files_exist(
                    connection,
                    torrent["hashString"],
                ):
                    return True
        finally:
            connection.close()

        return False

    @staticmethod
    def _matches_client_scope(
        client: DownloadClient,
        torrent: dict[str, Any],
    ) -> bool:
        labels = {str(label).lower() for label in torrent.get("labels") or []}
        category = client.category.lower()
        download_dir = PurePosixPath(torrent["downloadDir"])

        if category and labels:
            return category in labels
        if client.directory:
            configured_dir = PurePosixPath(client.directory)
            return (
                download_dir == configured_dir
                or configured_dir in download_dir.parents
            )
        if category:
            return category in {part.lower() for part in download_dir.parts}

        return True

    @staticmethod
    def _imported_library_files_exist(
        connection: sqlite3.Connection,
        download_id: str,
    ) -> bool:
        rows = connection.execute(
            """
            SELECT Data
            FROM History
            WHERE lower(DownloadId) = lower(?)
              AND EventType = ?
            """,
            (download_id, HISTORY_IMPORTED),
        ).fetchall()
        if not rows:
            return False

        imported_paths: list[Path] = []
        for (raw_data,) in rows:
            try:
                data = json.loads(raw_data)
            except (TypeError, json.JSONDecodeError):
                return False
            imported_path = data.get("importedPath")
            if not imported_path:
                return False
            imported_paths.append(Path(imported_path))

        return all(path.is_file() for path in imported_paths)


class TransmissionRpc:
    def __init__(self, url: str) -> None:
        self.url = url
        self.session_id = ""

    def call(
        self,
        method: str,
        arguments: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        payload = json.dumps(
            {"method": method, "arguments": arguments or {}},
        ).encode()

        for _ in range(2):
            request = urllib.request.Request(
                self.url,
                data=payload,
                headers={
                    "Content-Type": "application/json",
                    "X-Transmission-Session-Id": self.session_id,
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    result = json.load(response)
            except urllib.error.HTTPError as error:
                if error.code != 409:
                    raise
                self.session_id = error.headers["X-Transmission-Session-Id"]
                continue

            if result.get("result") != "success":
                raise RuntimeError(
                    f"Transmission RPC {method} failed: {result.get('result')}"
                )
            return result["arguments"]

        raise RuntimeError("Transmission did not establish an RPC session")

    def torrents(
        self,
        torrent_ids: list[str] | None = None,
    ) -> list[dict[str, Any]]:
        fields = [
            "id",
            "hashString",
            "status",
            "isFinished",
            "percentDone",
            "leftUntilDone",
            "secondsSeeding",
            "error",
            "errorString",
            "labels",
            "downloadDir",
        ]
        arguments: dict[str, Any] = {"fields": fields}
        if torrent_ids is not None:
            arguments["ids"] = torrent_ids
        return self.call("torrent-get", arguments)["torrents"]

    def remove(self, torrent_hash: str) -> None:
        self.call(
            "torrent-remove",
            {
                "ids": [torrent_hash],
                "delete-local-data": True,
            },
        )


def removal_reason(
    torrent: dict[str, Any],
    max_seeding_seconds: float,
    max_seeding_days: float,
) -> str | None:
    complete_without_error = (
        torrent.get("percentDone") == 1
        and torrent.get("leftUntilDone") == 0
        and torrent.get("error") == 0
    )
    if not complete_without_error:
        return None

    if (
        torrent.get("status") == TRANSMISSION_STOPPED
        and torrent.get("isFinished") is True
    ):
        return "Transmission marked it finished"

    if (
        torrent.get("status")
        in {TRANSMISSION_STOPPED, TRANSMISSION_SEED_WAIT, TRANSMISSION_SEEDING}
        and torrent.get("secondsSeeding", 0) >= max_seeding_seconds
    ):
        return f"it has seeded for at least {max_seeding_days:g} days"

    return None


def acquire_lock() -> Any:
    runtime_dir = Path(
        os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"),
    )
    runtime_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_file = (runtime_dir / "arr-finished-cleanup.lock").open("w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another cleanup run is active; skipping")
        raise SystemExit(0)
    return lock_file


def parse_args() -> argparse.Namespace:
    def positive_days(value: str) -> float:
        days = float(value)
        if days <= 0:
            raise argparse.ArgumentTypeError("must be greater than zero")
        return days

    parser = argparse.ArgumentParser(
        description=(
            "Remove imported Arr torrents that Transmission marks finished "
            "or that have seeded for at least 14 days."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report eligible torrents without removing them",
    )
    parser.add_argument(
        "--max-seeding-days",
        type=positive_days,
        default=os.environ.get("ARR_CLEANUP_MAX_SEEDING_DAYS", "14"),
        help="remove imported completed torrents after this much seeding time",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    lock_file = acquire_lock()
    max_seeding_seconds = args.max_seeding_days * 24 * 60 * 60

    try:
        instances = [
            ArrInstance(
                "Sonarr",
                Path(
                    os.environ.get(
                        "ARR_SONARR_CONFIG_DIR",
                        str(Path.home() / ".config/Sonarr"),
                    )
                ),
                "tvCategory",
                "tvDirectory",
            ),
            ArrInstance(
                "Radarr",
                Path(
                    os.environ.get(
                        "ARR_RADARR_CONFIG_DIR",
                        str(Path.home() / ".config/Radarr"),
                    )
                ),
                "movieCategory",
                "movieDirectory",
            ),
        ]

        rpc = TransmissionRpc(
            os.environ.get(
                "ARR_CLEANUP_TRANSMISSION_RPC_URL",
                DEFAULT_TRANSMISSION_RPC_URL,
            )
        )
        candidates: list[tuple[dict[str, Any], ArrInstance, str]] = []
        for torrent in rpc.torrents():
            reason = removal_reason(
                torrent,
                max_seeding_seconds,
                args.max_seeding_days,
            )
            if reason is None:
                continue

            matches = [
                instance
                for instance in instances
                if instance.matching_import(torrent)
            ]
            if len(matches) != 1:
                if len(matches) > 1:
                    log(
                        f"torrent {torrent['id']} ({torrent['hashString'][-8:]}) "
                        "matches multiple Arr instances; skipping"
                    )
                continue
            candidates.append((torrent, matches[0], reason))

        if not candidates:
            log("no imported torrents satisfy the finished or 14-day policy")
            return 0

        for torrent, instance, reason in candidates:
            identifier = f"{torrent['id']} ({torrent['hashString'][-8:]})"
            if args.dry_run:
                log(
                    f"dry run: {instance.name} torrent {identifier} is eligible: "
                    f"{reason}"
                )
                continue

            current = rpc.torrents([torrent["hashString"]])
            if len(current) != 1:
                log(f"torrent {identifier} disappeared before removal; skipping")
                continue
            current_reason = removal_reason(
                current[0],
                max_seeding_seconds,
                args.max_seeding_days,
            )
            if current_reason is None:
                log(f"torrent {identifier} changed state before removal; skipping")
                continue
            if not instance.matching_import(current[0]):
                log(f"{instance.name} import guard changed for torrent {identifier}; skipping")
                continue

            rpc.remove(torrent["hashString"])
            log(
                f"removed imported {instance.name} torrent {identifier}: "
                f"{current_reason}"
            )

        return 0
    finally:
        lock_file.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        log(f"ERROR: {type(error).__name__}: {error}")
        sys.exit(1)

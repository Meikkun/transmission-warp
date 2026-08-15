#!/usr/bin/env python3

import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any


def fail(message: str) -> None:
    raise SystemExit(f"update-settings: {message}")


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read valid JSON from {path}: {error}")

    if not isinstance(value, dict):
        fail(f"{path} must contain a JSON object")
    return value


def env_name(setting: str) -> str:
    return f"TRANSMISSION_{setting.upper().replace('-', '_')}"


def coerce(raw: str, template: Any, variable: str) -> Any:
    if isinstance(template, bool):
        normalized = raw.lower()
        if normalized not in {"true", "false"}:
            fail(f"{variable} must be true or false")
        return normalized == "true"
    if isinstance(template, int):
        try:
            return int(raw)
        except ValueError:
            fail(f"{variable} must be an integer")
    if isinstance(template, float):
        try:
            return float(raw)
        except ValueError:
            fail(f"{variable} must be a number")
    if isinstance(template, (list, dict)):
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            fail(f"{variable} must be valid JSON")
        if not isinstance(value, type(template)):
            fail(f"{variable} has the wrong JSON type")
        return value
    return raw


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: update-settings.py DEFAULTS OUTPUT")

    defaults_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    settings = load_json(defaults_path)

    if output_path.exists():
        settings.update(load_json(output_path))

    for setting, current_value in list(settings.items()):
        variable = env_name(setting)
        if variable not in os.environ:
            continue

        raw_value = os.environ[variable]
        settings[setting] = coerce(raw_value, current_value, variable)
        shown_value = "[REDACTED]" if "password" in setting else raw_value
        print(f"Overriding {setting} from {variable}={shown_value}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=output_path.parent,
            prefix=".settings.",
            delete=False,
        ) as stream:
            temporary_name = stream.name
            json.dump(settings, stream, indent=4)
            stream.write("\n")
        os.replace(temporary_name, output_path)
    except OSError as error:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
        fail(f"cannot write {output_path}: {error}")


if __name__ == "__main__":
    main()


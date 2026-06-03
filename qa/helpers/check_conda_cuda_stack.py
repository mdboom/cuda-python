#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

"""Check conda-forge CUDA component availability for a CUDA minor release.

The package pages at anaconda.org are human-friendly, but the JSON API is much
easier to poll. This script checks the CUDA component packages concurrently and
reports the latest package version plus whether a target CUDA minor appears to
be available.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import Any
from zoneinfo import ZoneInfo

CHANNEL = "conda-forge"
API_URL = "https://api.anaconda.org/package/{channel}/{package}"
FILES_URL = "https://anaconda.org/{channel}/{package}/files"
PACIFIC = ZoneInfo("America/Los_Angeles")

PACKAGES = [
    "cuda-version",
    "cuda-cudart-dev",
    "cuda-cudart-static",
    "cuda-cudart",
    "cuda-nvrtc",
    "cuda-nvrtc-dev",
    "cuda-nvvm-impl",
    "cuda-profiler-api",
    "libnvfatbin",
    "libnvjitlink",
    "libcufile",
    "libcufile-dev",
    "cuda-crt-dev_linux-64",
    "cuda-crt-dev_linux-aarch64",
    "cuda-crt-dev_win-64",
]


@dataclass(frozen=True)
class PackageStatus:
    package: str
    latest_version: str
    has_target: bool
    target_versions: tuple[str, ...]
    newest_target_upload: str
    url: str
    error: str = ""


def next_minor(target: str) -> str:
    parts = target.split(".")
    if len(parts) != 2:
        raise ValueError(f"target must be major.minor, got {target!r}")
    major, minor = (int(part) for part in parts)
    return f"{major}.{minor + 1}"


def file_matches_target(file_info: dict[str, Any], target: str, upper: str) -> bool:
    version = str(file_info.get("version", ""))
    attrs = file_info.get("attrs") or {}
    constraints = attrs.get("constrains") or []
    depends = attrs.get("depends") or []
    specs = [str(item) for item in [*constraints, *depends]]

    if version == target or version.startswith(f"{target}."):
        return True

    # Packages like libcufile do not use CUDA Toolkit-style versions. Detect
    # whether their metadata pins them to the requested CUDA minor instead.
    target_lower = f"cuda-version >={target},<{upper}.0a0"
    target_major_lower = f"cuda-version >={target.split('.')[0]},<{upper}.0a0"
    return any(target_lower in spec or target_major_lower in spec for spec in specs)


def format_pacific_time(timestamp: str) -> str:
    if not timestamp:
        return ""

    try:
        parsed = dt.datetime.fromisoformat(timestamp)
    except ValueError:
        return timestamp

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.UTC)

    local = parsed.astimezone(PACIFIC)
    return local.strftime("%Y-%m-%d %I:%M:%S %p %Z")


def fetch_package(package: str, target: str, timeout: float) -> PackageStatus:
    url = API_URL.format(channel=CHANNEL, package=package)
    request = urllib.request.Request(url, headers={"User-Agent": "cuda-stack-check/1.0"})  # noqa: S310
    files_url = FILES_URL.format(channel=CHANNEL, package=package)
    upper = next_minor(target)

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            data = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        return PackageStatus(
            package=package,
            latest_version="?",
            has_target=False,
            target_versions=(),
            newest_target_upload="",
            url=files_url,
            error=str(exc),
        )

    matching_files = [file_info for file_info in data.get("files", []) if file_matches_target(file_info, target, upper)]
    target_versions = sorted({str(file_info.get("version", "")) for file_info in matching_files})
    upload_times = sorted(str(file_info.get("upload_time", "")) for file_info in matching_files)
    newest_upload_time = upload_times[-1] if upload_times else ""

    return PackageStatus(
        package=package,
        latest_version=str(data.get("latest_version", "?")),
        has_target=bool(matching_files),
        target_versions=tuple(version for version in target_versions if version),
        newest_target_upload=format_pacific_time(newest_upload_time),
        url=files_url,
    )


def print_table(statuses: list[PackageStatus]) -> None:
    headers = ["package", "latest", "target?", "target versions", "newest target upload"]
    rows = [
        [
            status.package,
            status.latest_version,
            "yes" if status.has_target else "no",
            ", ".join(status.target_versions) if status.target_versions else "-",
            status.newest_target_upload or "-",
        ]
        for status in statuses
    ]

    widths = [max(len(headers[index]), *(len(row[index]) for row in rows)) for index in range(len(headers))]
    print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(value.ljust(widths[index]) for index, value in enumerate(row)))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", default="13.3", help="CUDA major.minor to check, e.g. 13.3")
    parser.add_argument("--jobs", type=int, default=8, help="number of concurrent requests")
    parser.add_argument("--timeout", type=float, default=20.0, help="per-request timeout in seconds")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args(argv)

    try:
        next_minor(args.target)
    except ValueError as exc:
        parser.error(str(exc))

    statuses_by_package: dict[str, PackageStatus] = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        future_to_package = {
            executor.submit(fetch_package, package, args.target, args.timeout): package for package in PACKAGES
        }
        for future in as_completed(future_to_package):
            status = future.result()
            statuses_by_package[status.package] = status

    statuses = [statuses_by_package[package] for package in PACKAGES]

    if args.json:
        print(json.dumps([status.__dict__ for status in statuses], indent=2))
    else:
        print_table(statuses)
        missing = [status.package for status in statuses if not status.has_target]
        if missing:
            print()
            print(f"Missing {args.target} availability for: {', '.join(missing)}")
            return 1
        print()
        print(f"All tracked packages have {args.target} availability.")

    return 0 if all(status.has_target for status in statuses) else 1


if __name__ == "__main__":
    sys.exit(main())

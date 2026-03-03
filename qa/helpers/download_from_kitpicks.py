#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

"""
Download CUDA kitpick local installers for the current platform (or a chosen one),
and list available kitpicks for a given CTK version.

USAGE EXAMPLES
--------------
1) List all kitpicks for a version
   download_from_kitpicks.py 13.1

2) Download the latest kitpick for 13.1 (auto-arch unless overridden)
   download_from_kitpicks.py 13.1 --latest
   download_from_kitpicks.py 13.1 --latest --arch=linux-sbsa
   download_from_kitpicks.py 13.1 --latest --all

3) Full URL (auto-arch detection; downloads only the matching file)
   download_from_kitpicks.py https://kitmaker-web.nvidia.com/kitpicks/cuda-r13-2/13.2.0/044/local_installers/

4) Full URL, override architecture
   download_from_kitpicks.py https://.../local_installers/ --arch=linux

5) Full URL, download all three files
   download_from_kitpicks.py https://.../local_installers/ --all

6) Shorthand (VERSION KITPICK), auto-arch detection
   download_from_kitpicks.py 13.1 028

7) Shorthand with explicit arch
   download_from_kitpicks.py 13.1 028 --arch=linux-sbsa

8) Shorthand, download all
   download_from_kitpicks.py 13.1 028 --all
"""

import argparse
import datetime as _dt
import email.utils
import os
import platform
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import urljoin

BASE_URL = "https://kitmaker-web.nvidia.com/kitpicks"

ARCH_ALIASES = {
    # Windows
    "windows": "win-64",
    "win-64": "win-64",
    # Linux x86_64
    "linux": "linux-64",
    "linux-64": "linux-64",
    # Linux aarch64
    "linux-sbsa": "linux-aarch64",
    "linux-aarch64": "linux-aarch64",
}


def urlopen_with_timeout(url, timeout=20):
    return urllib.request.urlopen(url, timeout=timeout)  # noqa: S310


def debug(msg: str) -> None:
    print(msg, flush=True)


def extract_kitpick_from_url(url: str) -> str | None:
    """
    Extract the 3-digit kitpick number from a full URL (e.g., '028').
    """
    m = re.search(r"/(\d{3})/local_installers/?$", url.rstrip("/"))
    if m:
        return m.group(1)
    # fallback: last 3 consecutive digits in the URL
    m2 = re.findall(r"(\d{3})(?!\d)", url)
    return m2[-1] if m2 else None


def normalize_version_tag(version_str: str) -> tuple[str, str]:
    """
    Given '13.1' or '13.1.0', return (r_tag, semver) where:
      r_tag  = 'cuda-r13-1'
      semver = '13.1.0'
    """
    m = re.fullmatch(r"\s*(\d+)\.(\d+)(?:\.(\d+))?\s*", version_str)
    if not m:
        raise ValueError(f"Invalid VERSION '{version_str}'. Expected like '13.1' or '13.1.0'.")
    maj, min_, patch = m.group(1), m.group(2), m.group(3) or "0"
    r_tag = f"cuda-r{maj}-{min_}"
    semver = f"{maj}.{min_}.{patch}"
    return r_tag, semver


def build_version_index_url(version_str: str) -> str:
    r_tag, semver = normalize_version_tag(version_str)
    return f"{BASE_URL}/{r_tag}/{semver}/"


def build_full_url(version_str: str, kitpick: str) -> str:
    r_tag, semver = normalize_version_tag(version_str)
    kitpick3 = kitpick.strip()
    if not re.fullmatch(r"\d{3}", kitpick3):
        raise ValueError(f"Invalid KITPICK '{kitpick}'. Expected a 3-digit value like '028'.")
    url = f"{BASE_URL}/{r_tag}/{semver}/{kitpick3}/local_installers/"
    return url


class FileLinkExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "a":
            href = dict(attrs).get("href")
            if href and href.endswith((".run", ".exe")):
                self.links.append(href)


def get_file_links(url: str) -> list[tuple[str, str]]:
    """
    Scrape the local_installers directory to find .run and .exe files.
    Returns list of (filename, absolute_url).
    """
    with urlopen_with_timeout(url) as response:
        html = response.read().decode("utf-8")

    parser = FileLinkExtractor()
    parser.feed(html)
    return [(href, urljoin(url, href)) for href in parser.links]


@dataclass(frozen=True)
class KitpickRow:
    kitpick: str  # '031'
    last_modified: str  # '2025-11-07 19:02:57'


class KitpickIndexParser(HTMLParser):
    """
    Parser for the version index page listing numeric kitpick subdirectories with
    an adjacent 'Last Modified' column.

    Site format:
      <tr class="file">
        <td></td>
        <td>
          <a href="./042/">
            <span class="name">042/</span>
          </a>
        </td>
        <td>&mdash;</td>
        <td class="timestamp hideable">
          <time datetime="2026-02-24T03:21:17Z">02/24/2026 03:21:17 AM +00:00</time>
        </td>
      </tr>
    """

    def __init__(self) -> None:
        super().__init__()
        self._in_file_row = False
        self._current_kitpick: str | None = None
        self._current_date: str | None = None
        self.rows: list[KitpickRow] = []

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)

        # Detect file rows: <tr class="file">
        if tag.lower() == "tr" and attrs_dict.get("class") == "file":
            self._in_file_row = True
            self._current_kitpick = None
            self._current_date = None

        # Extract kitpick number from href: <a href="./042/">
        if tag.lower() == "a" and self._in_file_row:
            href = attrs_dict.get("href", "")
            if href:
                m = re.search(r"(\d{3})/", href)
                if m:
                    self._current_kitpick = m.group(1)

        # Extract date from <time datetime="2026-02-24T03:21:17Z">
        if tag.lower() == "time" and self._in_file_row:
            datetime_attr = attrs_dict.get("datetime", "")
            if datetime_attr:
                # Convert ISO format (2026-02-24T03:21:17Z) to YYYY-MM-DD HH:MM:SS
                dt_str = datetime_attr.replace("T", " ").replace("Z", "")
                self._current_date = dt_str

    def handle_endtag(self, tag):
        if tag.lower() == "tr" and self._in_file_row:
            if self._current_kitpick and self._current_date:
                self.rows.append(KitpickRow(self._current_kitpick, self._current_date))
            self._in_file_row = False


def fetch_version_kitpicks(version_str: str) -> list[KitpickRow]:
    """
    Fetch and parse the version index page to obtain [(kitpick, last_modified), ...]
    """
    url = build_version_index_url(version_str)
    with urlopen_with_timeout(url) as response:
        html = response.read().decode("utf-8")

    parser = KitpickIndexParser()
    parser.feed(html)

    # Deduplicate + sort numerically by kitpick
    unique = {r.kitpick: r for r in parser.rows}
    return [unique[k] for k in sorted(unique.keys(), key=lambda s: int(s))]


def generate_new_filename(original_filename: str, kitpick: str) -> str:
    """
    Add _kitpickXYZ before extension.
    """
    name, ext = os.path.splitext(original_filename)
    return f"{name}_kitpick{kitpick}{ext}"


def _http_date_to_timestamp(http_date: str) -> float | None:
    """Convert an HTTP-date string to a POSIX timestamp."""
    try:
        dt = email.utils.parsedate_to_datetime(http_date)
        if dt is None:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=_dt.timezone.utc)
        return dt.timestamp()
    except Exception:
        return None


def download_file(file_url: str, original_filename: str, new_filename: str) -> bool:
    """
    Download file using pure Python, roughly emulating:
        wget --timestamping --output-document=new_filename file_url

    - Preserves server Last-Modified timestamp when available
    - Skips download if local file is already up to date (like --timestamping)
    """
    debug(f"Downloading: {original_filename} -> {new_filename}")

    # 1) Optional HEAD request to emulate --timestamping
    remote_ts: float | None = None
    try:
        head_req = urllib.request.Request(file_url, method="HEAD")  # noqa: S310
        with urllib.request.urlopen(head_req, timeout=30) as head_resp:  # noqa: S310
            lm = head_resp.headers.get("Last-Modified")
            if lm:
                remote_ts = _http_date_to_timestamp(lm)
    except Exception:
        # HEAD might fail on some servers; just fall back to always GET.
        remote_ts = None

    # If we have both a local file and a remote timestamp, check if up to date.
    if remote_ts is not None and os.path.exists(new_filename):
        local_ts = os.path.getmtime(new_filename)
        # Allow 1s slack for rounding
        if local_ts >= remote_ts - 1:
            print(f"✓ {new_filename} (up to date)")
            return True

    # 2) Actually download the file (GET)
    try:
        get_req = urllib.request.Request(file_url, method="GET")  # noqa: S310
        with urllib.request.urlopen(get_req, timeout=60) as resp, open(new_filename, "wb") as f:  # noqa: S310
            # If HEAD failed / had no Last-Modified, try again from GET headers.
            if remote_ts is None:
                lm = resp.headers.get("Last-Modified")
                if lm:
                    remote_ts = _http_date_to_timestamp(lm)

            # Stream to disk in chunks to avoid big-memory downloads.
            while True:
                chunk = resp.read(64 * 1024)
                if not chunk:
                    break
                f.write(chunk)

        # 3) Preserve timestamp if we got one
        if remote_ts is not None:
            os.utime(new_filename, (remote_ts, remote_ts))

        # 4) chmod like your original code (non-Windows only)
        if os.name != "nt":
            os.chmod(new_filename, 0o555)  # noqa: S103

        print(f"✓ {new_filename}")
        return True

    except urllib.error.HTTPError as e:
        print(f"✗ Failed: {original_filename}\nHTTP {e.code}: {e.reason}")
        return False
    except urllib.error.URLError as e:
        print(f"✗ Failed: {original_filename}\nNetwork error: {e}")
        return False
    except OSError as e:
        print(f"✗ Failed: {original_filename}\nFilesystem error: {e}")
        return False


# ---------------------------------------------------------------------------
# Architecture handling
# ---------------------------------------------------------------------------


def auto_detect_arch() -> str:
    sysname = platform.system().lower()
    machine = platform.machine().lower()

    if sysname == "windows":
        return "win-64"

    if sysname == "linux":
        if machine in ("x86_64", "amd64"):
            return "linux-64"
        if machine in ("aarch64", "arm64"):
            return "linux-aarch64"

    raise RuntimeError(f"Unsupported platform for auto-detection: {sysname} / {machine}")


def normalize_arch(name: str) -> str:
    key = name.strip().lower().replace("_", "-")
    canonical = ARCH_ALIASES.get(key)
    if canonical is None:
        raise ValueError(f"Unknown --arch '{name}'. Supported aliases: {', '.join(ARCH_ALIASES.keys())}")
    return canonical


def select_links_for_arch(file_links: list[tuple[str, str]], arch: str) -> list[tuple[str, str]]:
    """
    Pick only the links that match the requested arch, based on filename.
    We rely on naming conventions:
      - Windows: contains 'windows' and ends with .exe
      - linux-64: contains 'linux' but NOT 'sbsa', ends with .run
      - linux-aarch64: contains 'linux_sbsa' or 'sbsa', ends with .run
    """
    out: list[tuple[str, str]] = []

    for fname, href in file_links:
        lower = fname.lower()

        if arch == "win-64":
            if lower.endswith(".exe") and "windows" in lower:
                out.append((fname, href))

        elif arch == "linux-64":
            if lower.endswith(".run") and "linux" in lower and "sbsa" not in lower:
                out.append((fname, href))

        elif arch == "linux-aarch64":  # noqa: SIM102
            if lower.endswith(".run") and ("linux_sbsa" in lower or "sbsa" in lower):
                out.append((fname, href))

    return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Download CUDA kitpick local installers, or list kitpicks for a CTK version."
    )

    # Positional args:
    #   - EITHER: <FULL_URL>
    #   - OR:     <VERSION> [KITPICK]
    p.add_argument("arg1", help="Either FULL_URL or VERSION (e.g., 13.1)")
    p.add_argument("arg2", nargs="?", help="KITPICK (e.g., 028) if using VERSION form")

    p.add_argument(
        "--latest",
        action="store_true",
        help="When given a VERSION (no KITPICK), resolve latest kitpick and proceed to download.",
    )

    # Download selection
    grp = p.add_mutually_exclusive_group()
    grp.add_argument(
        "--arch", help="Target architecture (aliases: windows, win-64, linux, linux-64, linux-sbsa, linux-aarch64)"
    )
    grp.add_argument("--all", action="store_true", help="Download all three installers")
    return p


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = build_parser()
    if not argv:
        p.print_help(sys.stderr)
        sys.exit(0)
    return p.parse_args(argv)


def is_url(s: str) -> bool:
    return s.startswith(("http://", "https://"))


def handle_listing(version_str: str) -> int:
    rows = fetch_version_kitpicks(version_str)
    if not rows:
        print(f"No kitpicks found for {version_str}.")
        return 1

    for r in rows:
        print(f"{r.kitpick} — {r.last_modified}")
    return 0


def resolve_latest_kitpick(version_str: str) -> str:
    rows = fetch_version_kitpicks(version_str)
    if not rows:
        raise RuntimeError(f"No kitpicks available for version {version_str}")
    # rows are sorted numerically
    return rows[-1].kitpick


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    # MODE 1: VERSION-ONLY (listing or latest)
    if not is_url(args.arg1) and not args.arg2:
        version = args.arg1

        if args.latest:
            latest = resolve_latest_kitpick(version)
            print(f"Latest kitpick for {version}: {latest}")
            # fall-through to download code-path as VERSION + KITPICK
            full_url = build_full_url(version, latest)
            kitpick_suffix = latest
        else:
            return handle_listing(version)

    # MODE 2: VERSION + KITPICK  -> build URL
    elif not is_url(args.arg1) and args.arg2:
        full_url = build_full_url(args.arg1, args.arg2)
        kitpick_suffix = args.arg2
        debug(f"Constructed URL: {full_url}")

    # MODE 3: FULL URL
    else:
        if not is_url(args.arg1):
            print(
                "ERROR: With one positional argument, it must be a FULL URL.\n"
                "       Or use: VERSION [KITPICK] (e.g., '13.1 028')\n"
                "       Or: VERSION --latest"
            )
            return 2
        full_url = args.arg1 if args.arg1.endswith("/") else args.arg1 + "/"
        kitpick_suffix = extract_kitpick_from_url(full_url) or "000"
        debug(f"Using provided URL: {full_url}")

    # Resolve architecture target(s)
    targets: list[str]
    if args.all:
        targets = ["win-64", "linux-64", "linux-aarch64"]
        debug("Mode: download all architectures")
    else:
        if args.arch:
            arch = normalize_arch(args.arch)
            debug(f"Mode: explicit arch = {arch}")
        else:
            arch = auto_detect_arch()
            debug(f"Mode: auto-detected arch = {arch}")
        targets = [arch]

    # Fetch directory listing for local_installers
    debug("Fetching directory listing...")
    try:
        file_links = get_file_links(full_url)
    except Exception as e:
        print(f"Error fetching directory listing: {e}")
        return 1

    if not file_links:
        print("No .run or .exe files found in the directory listing.")
        return 1

    # Select links by arch
    selected: list[tuple[str, str]] = []
    for arch in targets:
        chosen = select_links_for_arch(file_links, arch)
        if not chosen:
            debug(f"Warning: no matching files found for arch '{arch}'.")
        selected.extend(chosen)

    if not selected:
        print("No matching files to download after applying architecture filters.")
        return 1

    # Show plan
    print("\nFull URL:", full_url)
    print(f"Kitpick: {kitpick_suffix}")
    print(f"Selected {len(selected)} file(s):")
    for fname, _ in selected:
        print(f"  - {fname} -> {generate_new_filename(fname, kitpick_suffix)}")

    # Download
    print("\nStarting downloads...")
    ok = 0
    for fname, href in selected:
        new_name = generate_new_filename(fname, kitpick_suffix)
        if download_file(href, fname, new_name):
            ok += 1

    print(f"\nDone: {ok}/{len(selected)} files downloaded successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

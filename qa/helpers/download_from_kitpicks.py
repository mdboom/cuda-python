#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

"""
Download CUDA kitpick local installers for the current platform (or a chosen one).

USAGE EXAMPLES
--------------
1) Full URL (auto-arch detection; downloads only the matching file)
   download_from_kitpicks.py https://cuda-repo.nvidia.com/release-candidates/kitpicks/cuda-r13-1/13.1.0/028/local_installers/

2) Full URL, override architecture
   download_from_kitpicks.py https://.../local_installers/ --arch=linux

3) Full URL, download all three files
   download_from_kitpicks.py https://.../local_installers/ --all

4) Shorthand (VERSION KITPICK), auto-arch detection
   download_from_kitpicks.py 13.1 028

5) Shorthand with explicit arch
   download_from_kitpicks.py 13.1 028 --arch=linux-sbsa

6) Shorthand, download all
   download_from_kitpicks.py 13.1 028 --all
"""

import argparse
import os
import platform
import re
import subprocess
import sys
import urllib.request
from html.parser import HTMLParser
from urllib.parse import urljoin

BASE_URL = "https://cuda-repo.nvidia.com/release-candidates/kitpicks"

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


def build_full_url(version_str: str, kitpick: str) -> str:
    r_tag, semver = normalize_version_tag(version_str)
    kitpick3 = kitpick.strip()
    if not re.fullmatch(r"\d{3}", kitpick3):
        raise ValueError(f"Invalid KITPICK '{kitpick}'. Expected a 3-digit value like '028'.")
    url = f"{BASE_URL}/{r_tag}/{semver}/{kitpick3}/local_installers/"
    return url


class LinkExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "a":
            href = dict(attrs).get("href")
            if href and (href.endswith(".run") or href.endswith(".exe")):
                self.links.append(href)


def get_file_links(url: str) -> list[tuple[str, str]]:
    """
    Scrape the directory listing page to find .run and .exe files.
    Returns list of (filename, absolute_url).
    """
    with urllib.request.urlopen(url) as response:  # noqa: S310
        html = response.read().decode("utf-8")

    parser = LinkExtractor()
    parser.feed(html)
    return [(href, urljoin(url, href)) for href in parser.links]


def generate_new_filename(original_filename: str, kitpick: str) -> str:
    """
    Add _kitpickXYZ before extension.
    """
    name, ext = os.path.splitext(original_filename)
    return f"{name}_kitpick{kitpick}{ext}"


def download_file(file_url: str, original_filename: str, new_filename: str) -> bool:
    """
    Download file using wget with timestamp preservation.
    """
    try:
        cmd = ["wget", "--timestamping", "--output-document", new_filename, file_url]
        debug(f"Downloading: {original_filename} -> {new_filename}")
        result = subprocess.run(cmd, capture_output=True, text=True)  # noqa: S603
        if result.returncode == 0:
            print(f"✓ {new_filename}")
            os.chmod(new_filename, 0o555)  # noqa: S103
            return True
        print(f"✗ Failed: {original_filename}\n{result.stderr}")
        return False
    except FileNotFoundError:
        print("Error: wget not found. Please install wget first.")
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
            # include 'linux' but exclude sbsa variants
            if lower.endswith(".run") and "linux" in lower and "sbsa" not in lower:
                out.append((fname, href))

        elif arch == "linux-aarch64":  # noqa: SIM102
            # include sbsa variants
            if lower.endswith(".run") and ("linux_sbsa" in lower or "sbsa" in lower):
                out.append((fname, href))

    return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Download CUDA kitpick local installers for the current platform or a chosen one."
    )

    # Two invocation modes:
    #   1) download_from_kitpicks.py <FULL_URL>
    #   2) download_from_kitpicks.py <VERSION> <KITPICK>
    p.add_argument("arg1", help="Either FULL_URL or VERSION (e.g., 13.1)")
    p.add_argument("arg2", nargs="?", help="KITPICK (e.g., 028) if using VERSION form")

    grp = p.add_mutually_exclusive_group()
    grp.add_argument("--arch", help="Target architecture (see ARCH ALIASES in script header)")
    grp.add_argument("--all", action="store_true", help="Download all three installers")

    return p.parse_args(argv)


def is_url(s: str) -> bool:
    return s.startswith("http://") or s.startswith("https://")


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    # Determine full URL & kitpick suffix
    if args.arg2:  # VERSION + KITPICK
        full_url = build_full_url(args.arg1, args.arg2)
        kitpick_suffix = args.arg2
        debug(f"Constructed URL: {full_url}")
    else:  # FULL URL
        if not is_url(args.arg1):
            print(
                "ERROR: With one positional argument, it must be a FULL URL.\n"
                "       Or use two args: VERSION KITPICK (e.g., '13.1 028')."
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

    # Fetch directory listing
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

#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

r"""
Copy the latest or a specific prerelease Display.Driver directory for a
given version from the shared \\builds path into the current user's
Downloads folder.

Usage (from PowerShell or CMD on Windows):

    # Latest 591.*-sandbag
    python Get-Windows-Prerelease-Driver.py 591

    # Exact 591.34-sandbag
    python Get-Windows-Prerelease-Driver.py 591.34

    # List all available 591.* versions
    python Get-Windows-Prerelease-Driver.py 591.*

This will:
  * For "591":
      - Search under:
            SANDBAGS_ROOT (module-level variable below)
        for directories matching:
            591.<minor>-sandbag
        and select the directory with the highest integer <minor>.

  * For "591.34":
      - Use the exact directory:
            591.34-sandbag
        under SANDBAGS_ROOT.

  * In both cases:
      - Probe a small set of known GeForce/UDA layouts, preferring the
        no-GFE/public variants when available. This currently includes:
            UDA\GeforceWeb_1\Public\International\Display.Driver
            UDA\UAS_UDA_GQS_NoGFE\Display.Driver
            UDA\GeforceWeb\Public\International\Display.Driver
            UDA\GeforceWeb\Private\International\Display.Driver
            UDA\UAS_UDA_GQS_GFE\Display.Driver
      - Copy the first matching Display.Driver tree into the current user's
        Downloads folder as:

            <version>-<layout>-Display.Driver

On success, the script prints an example pnputil command you can run
next to install the driver.
"""

import argparse
import os
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

# Use SANDBAGS_ROOT environment variable if set and non-empty, otherwise use default path
SANDBAGS_ROOT = Path(
    os.environ.get("SANDBAGS_ROOT") or r"\\builds\Prerelease\AttestedDriverSigning\Attested_logod\wddm2-x64-dch"
)

SANDBAGS_ROOT_TIP = "Tip: You can set SANDBAGS_ROOT via an environment variable to use a different path."


@dataclass(frozen=True)
class DriverLayout:
    """Known sandbag layout for a driver package and its install INF."""

    relative_display_driver: Path
    install_inf_name: str


# Known relative paths from the sandbag directory to the GeForce Display.Driver
# tree. Prefer the no-GFE/public variants first to preserve the helper's
# previous behavior, then fall back to GFE/private variants when needed.
DISPLAY_DRIVER_LAYOUTS: tuple[DriverLayout, ...] = (
    DriverLayout(
        Path("UDA") / "GeforceWeb_1" / "Public" / "International" / "Display.Driver",
        "nv_dispi.inf",
    ),
    DriverLayout(
        Path("UDA") / "UAS_UDA_GQS_NoGFE" / "Display.Driver",
        "nv_dispi.inf",
    ),
    DriverLayout(
        Path("UDA") / "GeforceWeb" / "Public" / "International" / "Display.Driver",
        "nv_dispi.inf",
    ),
    DriverLayout(
        Path("UDA") / "GeforceWeb" / "Private" / "International" / "Display.Driver",
        "nv_dispig.inf",
    ),
    DriverLayout(
        Path("UDA") / "UAS_UDA_GQS_GFE" / "Display.Driver",
        "nv_dispig.inf",
    ),
)


class ScriptError(Exception):
    """Custom exception for predictable script failures."""


def validate_sandbags_root() -> None:
    """
    Validate that SANDBAGS_ROOT exists and is a directory.

    Raises ScriptError with appropriate messages depending on whether
    SANDBAGS_ROOT was set via environment variable or using the default.
    """
    env_set = bool(os.environ.get("SANDBAGS_ROOT"))

    if not SANDBAGS_ROOT.exists():
        issue = "does not exist or is not accessible"
        if env_set:
            raise ScriptError(
                f"SANDBAGS_ROOT environment variable is set but the path {issue}: {SANDBAGS_ROOT}\n"
                "Please check that the SANDBAGS_ROOT environment variable points to a valid path."
            )
        else:
            raise ScriptError(f"SANDBAGS_ROOT {issue}: {SANDBAGS_ROOT}\n{SANDBAGS_ROOT_TIP}")

    if not SANDBAGS_ROOT.is_dir():
        if env_set:
            raise ScriptError(
                f"SANDBAGS_ROOT environment variable is set but the path is not a directory: {SANDBAGS_ROOT}\n"
                "Please check that the SANDBAGS_ROOT environment variable points to a valid directory."
            )
        else:
            raise ScriptError(f"SANDBAGS_ROOT is not a directory: {SANDBAGS_ROOT}\n{SANDBAGS_ROOT_TIP}")


def find_sandbag_dir(version_arg: str) -> Path:
    """
    Resolve the sandbag directory from the version argument.

    If version_arg contains a dot (e.g. "591.34"), it is treated as an
    exact version and the script looks for:

        <version_arg>-sandbag

    under SANDBAGS_ROOT.

    If version_arg has no dot (e.g. "591"), it is treated as a major
    version and the script searches for directories named:

        "<major>.<minor>-sandbag"

    and returns the one with the highest integer <minor>.

    Raises ScriptError if nothing appropriate is found or if the root path
    is inaccessible.
    """
    validate_sandbags_root()

    # Exact version mode: e.g. "591.34"
    if "." in version_arg:
        version_str = version_arg
        sandbag_dir = SANDBAGS_ROOT / f"{version_str}-sandbag"
        if not sandbag_dir.exists() or not sandbag_dir.is_dir():
            raise ScriptError(
                "Exact sandbag directory not found.\n"
                f"Expected directory:\n  {sandbag_dir}\n"
                "Make sure the version is correct (e.g. 591.34)."
            )
        return sandbag_dir

    # Latest for a major version: e.g. "591"
    try:
        major = int(version_arg)
    except ValueError as exc:
        raise ScriptError(
            f"Version must be either an integer major (e.g. 591) or "
            f"a major.minor string (e.g. 591.34). Got: {version_arg!r}"
        ) from exc

    pattern = re.compile(rf"^{re.escape(str(major))}\.(\d+)-sandbag$")
    best_dir: Path | None = None
    best_minor: int | None = None

    try:
        entries = list(SANDBAGS_ROOT.iterdir())
    except OSError as exc:
        raise ScriptError(f"Failed to list directories under {SANDBAGS_ROOT}: {exc}\n{SANDBAGS_ROOT_TIP}") from exc

    for entry in entries:
        if not entry.is_dir():
            continue
        m = pattern.match(entry.name)
        if not m:
            continue
        try:
            minor = int(m.group(1))
        except ValueError:
            # Skip directories with unexpected minor formats.
            continue
        if best_minor is None or minor > best_minor:
            best_minor = minor
            best_dir = entry

    if best_dir is None or best_minor is None:
        raise ScriptError(
            f"No sandbag directories found under {SANDBAGS_ROOT} for major version {major}.\n"
            f"Expected names like '{major}.34-sandbag'.\n{SANDBAGS_ROOT_TIP}"
        )

    return best_dir


def list_sandbag_dirs(major: int) -> list[Path]:
    """
    List all sandbag directories matching the given major version.

    Returns a list of Path objects for directories named "<major>.<minor>-sandbag",
    sorted by minor version number.
    """
    validate_sandbags_root()

    pattern = re.compile(rf"^{re.escape(str(major))}\.(\d+)-sandbag$")
    matching_dirs: list[tuple[int, Path]] = []

    try:
        entries = list(SANDBAGS_ROOT.iterdir())
    except OSError as exc:
        raise ScriptError(f"Failed to list directories under {SANDBAGS_ROOT}: {exc}\n{SANDBAGS_ROOT_TIP}") from exc

    for entry in entries:
        if not entry.is_dir():
            continue
        m = pattern.match(entry.name)
        if not m:
            continue
        try:
            minor = int(m.group(1))
            matching_dirs.append((minor, entry))
        except ValueError:
            # Skip directories with unexpected minor formats.
            continue

    # Sort by minor version and return just the paths
    matching_dirs.sort(key=lambda x: x[0])
    return [path for _, path in matching_dirs]


def get_downloads_dir() -> Path:
    """
    Return the current user's Downloads directory (under USERPROFILE).

    Raises ScriptError if USERPROFILE is not set or the Downloads directory
    cannot be determined.
    """
    userprofile = os.environ.get("USERPROFILE")
    if not userprofile:
        raise ScriptError("USERPROFILE environment variable is not set. This script is intended to run on Windows.")
    downloads = Path(userprofile) / "Downloads"
    if not downloads.exists():
        # It's safer not to auto-create it; report clearly instead.
        raise ScriptError(f"Downloads directory does not exist: {downloads}\nPlease create it and rerun the script.")
    if not downloads.is_dir():
        raise ScriptError(f"Downloads path exists but is not a directory: {downloads}")
    return downloads


def format_layout_label(layout: DriverLayout) -> str:
    """
    Build a readable destination label from the selected layout.

    Examples:
      - UDA/UAS_UDA_GQS_NoGFE/Display.Driver -> UAS_UDA_GQS_NoGFE
      - UDA/GeforceWeb_1/Public/International/Display.Driver ->
        GeforceWeb_1-Public-International
    """
    parts = layout.relative_display_driver.parts
    if len(parts) < 3:
        raise ScriptError(f"Unexpected layout path format: {layout.relative_display_driver}")
    return "-".join(parts[1:-1])


def find_display_driver_source(sandbag_dir: Path) -> tuple[DriverLayout, Path]:
    """
    Resolve the first known Display.Driver layout present in the sandbag.

    Returns the selected layout metadata and the full source path.
    """
    attempted_paths: list[Path] = []

    for layout in DISPLAY_DRIVER_LAYOUTS:
        src_display_driver = sandbag_dir / layout.relative_display_driver
        attempted_paths.append(src_display_driver)
        if not src_display_driver.exists():
            continue
        if not src_display_driver.is_dir():
            raise ScriptError(f"Expected Display.Driver to be a directory, but it is not.\nPath: {src_display_driver}")
        return layout, src_display_driver

    version_part = sandbag_dir.name.split("-", 1)[0]
    major_version = version_part.split(".", 1)[0] if version_part else ""
    hint = ""
    if major_version:
        script_name = Path(sys.argv[0]).name if sys.argv else "Get-Windows-Prerelease-Driver.py"
        hint = f"\n\nTip: To see all available versions, try:\n  python {script_name} {major_version}.*"

    attempted_paths_text = "\n".join(f"  {path}" for path in attempted_paths)
    raise ScriptError(f"Display.Driver directory not found.\nTried paths:\n{attempted_paths_text}{hint}")


def find_install_inf(src_display_driver: Path, layout: DriverLayout) -> Path:
    """
    Locate the install INF for the selected layout.

    The layout supplies the expected filename. If that exact filename is
    missing but there is exactly one `nv_disp*.inf`, use it as a fallback.
    """
    install_inf = src_display_driver / layout.install_inf_name
    if install_inf.exists():
        if not install_inf.is_file():
            raise ScriptError(f"Expected install INF to be a file, but it is not.\nPath: {install_inf}")
        return install_inf

    fallback_infs = sorted(path for path in src_display_driver.glob("nv_disp*.inf") if path.is_file())
    if len(fallback_infs) == 1:
        return fallback_infs[0]

    if not fallback_infs:
        raise ScriptError(
            f"Install INF not found.\nExpected file:\n  {install_inf}\nUnder directory:\n  {src_display_driver}"
        )

    available_fallbacks = "\n".join(f"  {path.name}" for path in fallback_infs)
    raise ScriptError(
        "Could not determine which install INF to use.\n"
        f"Expected file:\n  {install_inf}\n"
        "Available nv_disp*.inf files:\n"
        f"{available_fallbacks}"
    )


def copy_display_driver(
    sandbag_dir: Path,
    downloads_dir: Path,
    layout: DriverLayout,
    src_display_driver: Path,
) -> tuple[Path, str]:
    """
    Copy the Display.Driver directory from the given sandbag directory into
    the Downloads directory with the requested naming scheme.

    Returns the full path to the newly created destination directory and the
    selected install INF filename.
    """
    # Extract the version string from the sandbag directory name,
    # e.g. '591.34-sandbag' -> '591.34'.
    name_parts = sandbag_dir.name.split("-")
    if not name_parts or "." not in name_parts[0]:
        raise ScriptError(
            f"Unexpected sandbag directory name format: {sandbag_dir.name}\nExpected something like '591.34-sandbag'."
        )
    version_str = name_parts[0]
    install_inf = find_install_inf(src_display_driver, layout)

    # Build destination directory name:
    #   "<version>-<layout>-Display.Driver"
    build_flavor = format_layout_label(layout)
    dest_name = f"{version_str}-{build_flavor}-Display.Driver"
    dest_dir = downloads_dir / dest_name

    if dest_dir.exists():
        raise ScriptError(
            f"Destination directory already exists:\n  {dest_dir}\n"
            "To avoid mixing files from different runs, please delete it "
            "or move it aside, then rerun this script."
        )

    try:
        shutil.copytree(src_display_driver, dest_dir)
    except OSError as exc:
        raise ScriptError(f"Failed to copy from:\n  {src_display_driver}\nto:\n  {dest_dir}\nError: {exc}") from exc

    return dest_dir, install_inf.name


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Find the latest or a specific prerelease sandbag build for a "
            "given driver version and copy its "
            "preferred GeForce/UDA Display.Driver directory into the "
            "current user's Downloads folder."
        )
    )
    parser.add_argument(
        "version",
        help=(
            "Driver version to search for. Examples:"
            " '591' (latest 591.*-sandbag),"
            " '591.34' (exact), or"
            " '591.*' (list all)."
        ),
    )
    args = parser.parse_args(argv)

    # Check for list mode: version ending with ".*"
    if args.version.endswith(".*"):
        major_str = args.version[:-2]  # Remove ".*"
        try:
            major = int(major_str)
        except ValueError:
            print(
                f"ERROR: Invalid version format. Expected major version number before '.*', got: {major_str!r}",
                file=sys.stderr,
            )
            return 1

        try:
            print("Using SANDBAGS_ROOT:", flush=True)
            print(f"    {SANDBAGS_ROOT}", flush=True)
            matching_dirs = list_sandbag_dirs(major)
            if not matching_dirs:
                print(f"No sandbag directories found for major version {major}.\n{SANDBAGS_ROOT_TIP}", file=sys.stderr)
                return 1
            print("Available sandbag directories:", flush=True)
            for dir_path in matching_dirs:
                print(f"    {dir_path.name}", flush=True)
            return 0
        except ScriptError as exc:
            print("ERROR:", exc, file=sys.stderr)
            return 1

    try:
        print("Using SANDBAGS_ROOT:", flush=True)
        print(f"    {SANDBAGS_ROOT}", flush=True)
        sandbag_dir = find_sandbag_dir(args.version)
        print("Using sandbag directory:", flush=True)
        print(f"    {sandbag_dir}", flush=True)

        layout, src_display_driver = find_display_driver_source(sandbag_dir)
        print("Using driver layout:", flush=True)
        print(f"    {layout.relative_display_driver}", flush=True)

        # Show the full source path before starting the copy
        print("Copying from:", flush=True)
        print(f"    {src_display_driver}", flush=True)

        downloads_dir = get_downloads_dir()
        print("Using Downloads directory:", flush=True)
        print(f"    {downloads_dir}", flush=True)

        dest_dir, install_inf_name = copy_display_driver(sandbag_dir, downloads_dir, layout, src_display_driver)
    except ScriptError as exc:
        print("ERROR:", exc, file=sys.stderr)
        return 1

    # On success, print a helpful next-step message.
    dest_dir_str = str(dest_dir)
    print("Successfully copied Display.Driver to:", flush=True)
    print(f"    {dest_dir_str}", flush=True)
    print()
    print("Next step (pnputil command):", flush=True)
    print(f'  pnputil /add-driver "{dest_dir_str}\\{install_inf_name}" /install', flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

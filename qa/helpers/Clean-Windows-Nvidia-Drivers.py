#!/usr/bin/env python

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

"""NVIDIA Display Driver Cleanup (Remote Desktop Safe)

- Detaches NVIDIA display devices (pnputil /remove-device)
- Deletes NVIDIA display class drivers (pnputil /delete-driver)
- Remote Desktop may flicker briefly but will stay up
- Does NOT reboot automatically
- DEFAULT: DRY RUN (no changes made)
"""

# See also: qa/windows-nvidia-driver-removal.md

import argparse
import subprocess
from typing import Dict, List, Tuple


def run(args: List[str]) -> Tuple[int, str, str]:
    """Run a command and return (exit_code, stdout, stderr)."""
    proc = subprocess.Popen(  # noqa: S603
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    out, err = proc.communicate()
    return proc.returncode, out, err


def disable_windows_auto_driver_updates(dry_run: bool = False) -> None:
    r"""
    Disable Windows automatic driver updates.

    Windows 10/11 will automatically install a GPU driver during reboot if it
    detects a display adapter with no vendor driver attached. This includes:
      - downloading WHQL NVIDIA drivers from Windows Update, or
      - installing a preloaded OEM display driver already present in the OS image.

    When cleaning out NVIDIA display drivers (pnputil /remove-device +
    /delete-driver), this behavior can cause Windows to immediately reinstall a
    default NVIDIA driver on the next reboot — undoing the cleanup and causing
    the system to appear as if the old driver "came back" on its own.

    Setting:
        HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching\SearchOrderConfig = 0

    prevents Windows from installing any device drivers automatically. This keeps
    the system in a stable, driver-free state across reboots, allowing a specific
    NVIDIA driver version to be installed cleanly and deterministically without
    Windows reintroducing an unwanted version.

    This function modifies the registry via `reg add`. It takes effect immediately
    and does not require a reboot.
    """

    print("=== Disabling Windows automatic driver updates ===")

    cmd = [
        "reg",
        "add",
        r"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching",
        "/v",
        "SearchOrderConfig",
        "/t",
        "REG_DWORD",
        "/d",
        "0",
        "/f",
    ]

    print("  >> " + " ".join(cmd))

    if dry_run:
        return

    rc, _unused_out, err = run(cmd)
    if rc != 0:
        print("  ERROR setting registry value:")
        print(err)
    else:
        print("  Windows driver auto-updates disabled.")


def parse_blocks(output: str, key_prefix: str) -> List[Dict[str, str]]:
    """Split pnputil output into blocks separated by blank lines.

    Returns a list of dicts mapping 'Key:' -> 'value'.

    key_prefix is used to filter blocks that contain a specific key,
    e.g. "Instance ID" or "Published Name".
    """
    blocks: List[Dict[str, str]] = []
    current: Dict[str, str] = {}

    for line in output.splitlines():
        line = line.rstrip()
        if not line:
            if current:
                blocks.append(current)
                current = {}
            continue

        if ":" in line:
            # Example: "Instance ID:   PCI\\VEN_10DE..."
            key, value = line.split(":", 1)
            current[key.strip()] = value.strip()
        else:
            # Continuation line - append to last key if any
            if current:
                last_key = list(current.keys())[-1]
                current[last_key] += " " + line.strip()

    if current:
        blocks.append(current)

    # Filter to blocks that have the key_prefix (e.g. "Instance ID" or "Published Name")
    return [b for b in blocks if any(k.startswith(key_prefix) for k in b)]


def remove_nvidia_display_devices(dry_run: bool = False) -> None:
    print("=== Enumerating Display devices (pnputil /enum-devices /class Display) ===")
    rc, out, err = run(["pnputil", "/enum-devices", "/class", "Display"])
    if rc != 0:
        print("ERROR: pnputil /enum-devices failed:")
        print(err)
        return

    blocks = parse_blocks(out, "Instance ID")
    nvidia_devices: List[Tuple[str, str]] = []
    for b in blocks:
        manuf = b.get("Manufacturer Name", "")
        desc = b.get("Device Description", "")
        instance = b.get("Instance ID", "")
        if "nvidia" in manuf.lower() or "nvidia" in desc.lower():
            nvidia_devices.append((instance, desc or manuf))

    if not nvidia_devices:
        print("No NVIDIA display devices found.")
        return

    print("NVIDIA display devices to remove:")
    for inst, desc in nvidia_devices:
        print(f"  {inst}  ({desc})")

    for inst, desc in nvidia_devices:
        args = ["pnputil", "/remove-device", inst]
        print(f"\nRemoving device: {inst} ({desc})")
        print(f"  >> {' '.join(args)}")
        if dry_run:
            continue
        rc, out, err = run(args)
        print(out, end="")
        if err:
            print(err, end="")


def delete_nvidia_display_drivers(dry_run: bool = False) -> None:
    print("\n=== Enumerating Display drivers (pnputil /enum-drivers /class Display) ===")
    rc, out, err = run(["pnputil", "/enum-drivers", "/class", "Display"])
    if rc != 0:
        print("ERROR: pnputil /enum-drivers failed:")
        print(err)
        return

    blocks = parse_blocks(out, "Published Name")
    nvidia_drivers: List[Tuple[str, str]] = []
    for b in blocks:
        provider = b.get("Provider Name", "")
        cls = b.get("Class Name", "")
        published = b.get("Published Name", "")
        version = b.get("Driver Version", "")
        if "nvidia" in provider.lower() and cls.lower().startswith("display"):
            nvidia_drivers.append((published, version))

    if not nvidia_drivers:
        print("No NVIDIA display drivers found in the driver store.")
        return

    print("NVIDIA display drivers to delete:")
    for name, ver in nvidia_drivers:
        print(f"  {name}  (Driver Version: {ver})")

    for name, ver in nvidia_drivers:
        args = ["pnputil", "/delete-driver", name, "/uninstall", "/force"]
        print(f"\nDeleting driver: {name} (Version: {ver})")
        print(f"  >> {' '.join(args)}")
        if dry_run:
            continue
        rc, out, err = run(args)
        print(out, end="")
        if err:
            print(err, end="")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Detach NVIDIA display devices and delete NVIDIA display-class drivers using pnputil (safe over RDP)."
        )
    )
    parser.add_argument(
        "--i-am-sure",
        dest="dry_run",
        action="store_false",
        help=("Actually execute pnputil commands. By default, the script only prints what it would do (dry run)."),
    )
    args = parser.parse_args()

    banner_width = max([len(line) for line in __doc__.splitlines()])
    print("=" * banner_width)
    print(__doc__)
    print("=" * banner_width)
    print()

    if args.dry_run:
        print("THIS IS A DRY RUN: commands will be shown but NOT executed.\n")

    disable_windows_auto_driver_updates(dry_run=args.dry_run)
    remove_nvidia_display_devices(dry_run=args.dry_run)
    delete_nvidia_display_drivers(dry_run=args.dry_run)

    if args.dry_run:
        print("\nDRY RUN complete. Add --i-am-sure to EXECUTE the commands just shown.\n")
    else:
        print(
            "\n=== Reminder for non-VM workstations ===\n"
            "If you are running this script on a permanently owned workstation "
            "(i.e. not a temporary VM), you may want to re-enable automatic driver "
            "updates *after* installing the new NVIDIA driver.\n\n"
            "Restore Windows' default behavior with:\n\n"
            "  PowerShell:\n"
            '    Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching" '
            "-Name SearchOrderConfig -Value 1\n\n"
            "  cmd.exe:\n"
            '    reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching" '
            "/v SearchOrderConfig /t REG_DWORD /d 1 /f\n"
        )
        print(
            "\nDone. You should now reboot the system, e.g.:\n"
            "  Restart-Computer -Force  (PowerShell)\n"
            "or\n"
            "  shutdown /r /t 0         (cmd.exe)\n"
        )


if __name__ == "__main__":
    main()

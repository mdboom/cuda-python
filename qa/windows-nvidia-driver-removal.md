# Safe Remote Removal of NVIDIA Display Drivers (Windows / RDP)

This guide describes how to **safely remove NVIDIA GPU display drivers** on a
remote Windows machine **without losing Remote Desktop access**, even when
Secure Boot prevents unsigned/prerelease drivers from loading.

RDP remains active during this procedure (you may see a momentary flicker).

Related: `qa/helpers/clean_windows_nvidia_drivers.py` automates the procedures outlined below.

## 1. Identify the NVIDIA Display Device

Run:

```
pnputil /enum-devices /class Display
```

Look for the entry corresponding to your GPU, e.g.:

```
Instance ID: PCI\VEN_10DE&DEV_1E02&SUBSYS_12A310DE&REV_A1\4&e631fbe&0&0000
Device Description: NVIDIA TITAN RTX
Class Name: Display
```

Copy the **Instance ID**.

## 2. Detach the GPU from Its Driver (Safe Over RDP)

```
pnputil /remove-device "<INSTANCE ID>"
```

Example:

```
pnputil /remove-device "PCI\VEN_10DE&DEV_1E02&SUBSYS_12A310DE&REV_A1\4&e631fbe&0&0000"
```

- RDP may flicker briefly.
- The system will fall back to **Microsoft Basic Display Adapter**.

## 3. List All NVIDIA Display INFs in the Driver Store

```
pnputil /enum-drivers | findstr /i nvidia
```

Look for entries with:

- Provider Name: NVIDIA
- Class Name: Display
- Original Name: nv_dispi.inf, nv_disp*.inf, etc.

These are the display driver packages that must be removed.

## 4. Remove NVIDIA Display Driver Packages

For each matching INF (e.g. oem0.inf, oem273.inf, etc.):

```
pnputil /delete-driver oemXX.inf /uninstall /force
```

If Windows responds:

```
Driver package will be removed after reboot.
```

That is OK.

## 5. Preventing Windows from Reinstalling a Default Driver

When a Windows system reboots with **no vendor display driver attached** to a GPU,
Windows 10/11 may automatically install a driver using either:

- a WHQL-signed NVIDIA driver from Windows Update, or
- a preloaded OEM driver stored in the system image.

This can happen immediately after cleaning out all NVIDIA display drivers with
`pnputil /remove-device` and `/delete-driver`. In such cases, Windows may
reinstall a default driver during the next reboot, making it appear as though
an old driver “came back” on its own.

To keep the system in a driver-free state across reboots—so that a specific
NVIDIA driver version can be installed cleanly and deterministically—automatic
driver downloads should be disabled before removing drivers.

You can disable Windows automatic driver updates with:

```
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" ^
  /v SearchOrderConfig /t REG_DWORD /d 0 /f
```

This registry change takes effect immediately and does not require a reboot.
Once applied, Windows will no longer attempt to install a GPU driver
automatically.

## 6. Reboot the System

```
Restart-Computer -Force
```

After reboot:

- Device Manager should show **Microsoft Basic Display Adapter**
- `nvidia-smi` will fail (expected)
- No NVIDIA display driver remains
- System is now clean for fresh installation

RDP remains active.

## Notes

- This method avoids using the NVIDIA Installer and works entirely via
  Windows' **PnP Driver Store**, which can be critical for prerelease or
  unpacked driver packages.
- This sequence is safe for remote systems because **RDP uses a software
  display driver**, not the NVIDIA GPU driver.

# NVIDIA GPU Driver Modes & States — Cross-Platform Cheat Sheet

A concise reference for understanding what you may see in `nvidia-smi` across
**Windows** and **Linux**, with an emphasis on CUDA / CUDA Python testing.

## Where to Find These in `nvidia-smi`

### Windows
Look in the **`Driver-Model`** column of the main `nvidia-smi` table.
Examples: `WDDM`, `TCC`, `WDDM-v`.

### Linux
Linux does not have a `Driver-Model` column. Instead:
- **`Disp.A`** shows whether the GPU is driving a display (`On`/`Off`).
- **GOM** (`nvidia-smi -q`) shows compute vs graphics capability.
- **`MIG M.`** shows whether MIG is enabled on supported GPUs.

---

## Rule of Thumb

- **WDDM = graphics stack + potential HAGS**
- **TCC = compute-only, no graphics, no HAGS, no TDR**
- **Linux = always compute+graphics unless GOM/MIG/vGPU restricts it**
- **`Disp.A: Off` is the Linux equivalent of a headless compute node**
- **MIG is only on A100/H100/GH200-class GPUs**

---

## Windows Driver Models (shown in `nvidia-smi` → `Driver-Model`)

### **WDDM**
- Windows Display Driver Model (normal desktop mode)
- All GeForce / TITAN / RTX cards when driving a display
- Supports DirectX, graphics stack, desktop composition
- Subject to TDR (2-second timeout)
- **Allows HAGS / HWS (Hardware-accelerated GPU Scheduling)**

### **TCC**
- Tesla Compute Cluster mode
- Compute-only, **no display**, no DirectX, no HAGS
- No TDR
- Used by A40/A100/V100/Tesla series; some RTX cards when switched to compute mode

### **WDDM-v / GPU-P / vGPU**
- Virtual WDDM mode for VMs using VMware, Hyper-V, GRID, etc.

### **Disabled / Unknown**
- Driver not loaded, device disabled, or `nvidia-smi` doesn’t match installed driver

---

## Windows-Only Concepts (not shown directly in `nvidia-smi`)

### **HAGS / HWS (Hardware-accelerated GPU Scheduling)**
- WDDM-only
- Enabled via Windows Settings or registry (`HwSchMode`)
- CUDA/NVIDIA tools do **not** report it

### **TDR (Timeout Detection & Recovery)**
- WDDM GPUs are reset after ~2 seconds of unresponsive work
- Absent in TCC mode

---

## Linux GPU Operational States (Linux has no WDDM/TCC distinction)

Linux uses a unified driver; operational states appear in `nvidia-smi`.

### **Display Activity (`Disp.A`)**
- `On`  — GPU used by X11/Wayland (desktop-facing)
- `Off` — Headless compute (typical on servers)
- Closest Linux analogue to “display vs compute”

### **GOM — GPU Operation Mode**
(from `nvidia-smi -q`)

- `All_On` — Full graphics + compute (default)
- `Compute` — Graphics pipeline disabled (TCC-like behavior)
- `Low_Double` — Reduced FP64 for power savings
- `High_Quality_Graphics` — Full pro graphics mode

### **MIG Mode (Ampere/Hopper data center GPUs)**
- `Enabled`  — GPU partitioned into MIG instances
- `Disabled` — Full GPU exposed

### **Compute Mode (legacy CUDA mode)**
- `Default`
- `Exclusive_Process`
- `Prohibited`

### **Persistence Mode**
- Controls whether driver stays resident after last CUDA client exits

### **vGPU / SR-IOV Mode**
- `Host`, `Guest`, or `None`

---

## Cross-Platform Mapping

| Concept                  | Windows                     | Linux                        |
|--------------------------|------------------------------|------------------------------|
| Driver model             | **WDDM** or **TCC**         | Unified driver (no split)    |
| Display usage            | WDDM drives desktop          | `Disp.A: On`                 |
| Compute-only mode        | TCC                          | GOM=Compute                  |
| HAGS / HWS               | Possible (WDDM-only)         | Not applicable               |
| TDR resets               | Yes (WDDM)                   | No equivalent                |
| MIG                      | N/A                          | MIG Enabled/Disabled         |
| Virtual GPU              | WDDM-v / GPU-P               | vGPU Guest/Host              |

---

## Minimal Practical Scenarios (for CUDA QA)

| Scenario               | Windows                     | Linux                    |
|------------------------|------------------------------|--------------------------|
| Desktop dev machine    | WDDM + graphics              | `Disp.A: On`             |
| Compute workstation     | WDDM or TCC                  | `Disp.A: Off`            |
| Datacenter server       | TCC                          | GOM=All_On or Compute    |
| Virtualized GPU         | WDDM-v                       | vGPU Guest               |
| MIG server              | N/A                          | MIG Enabled              |

---

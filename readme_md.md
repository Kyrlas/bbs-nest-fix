# BBS Nest Performance & Stability Patch (`Fix-BBSNest.ps1`)

A lightweight, automated patch script for the **BBS Nest** terrain radar utility in Microsoft Flight Simulator (MSFS 2020 / MSFS 2024).

---

##  What Does This Patch Fix?

This script resolves known performance bottlenecks, GPU stalls, and connection issues by patching two files in BBS Nest:

1. **`SubSystem.dll` (Binary Patches)**
   * **SimConnect Reconnect Fix:** Eliminates duplicate SimConnect watcher threads and prevents redundant reconnect attempts when quitting or reloading a flight.
   * **Thread Stability:** Keeps the primary SimConnect listener thread resident in memory to prevent connection drops.
   * **Render Loop Frame-Rate Cap:** Caps internal radar calculation updates to ~20 Hz (50 ms cycle) instead of running unconstrained, significantly reducing CPU spikes and main-thread stutters.
   * **PE Checksum:** Updates the internal Windows PE checksum so the modified binary remains valid.

2. **`shdrsb\terr.frag` (Terrain Fragment Shader)**
   * **GPU Atomic Contention Fix:** Changes unconditional atomic operations (`atomicMax`, `atomicMin`) to guarded conditional checks. This prevents thousands of fragment shader invocations from hammering the GPU memory bus simultaneously, curing shader-induced micro-stutters.
   * **Buffer Coherency:** Flags the height buffer with the `coherent` qualifier to ensure reliable thread synchronization.
   * **Optimized Flag Writes:** Guards redundant state assignments to reduce redundant memory cycles.

---

## Safety & Safeguards

* **Version-Locked (`SHA-256`):** The script validates precomputed cryptographic hashes before altering anything. If your installed files differ by even a single byte (e.g., after an official update), it will refuse to patch.
* **Automatic Backups:** Creates clean `.orig` copies of both files before writing any modifications.
* **Reversible:** Built-in `-Restore` command to revert back to untouched originals at any time.

---

##  Requirements

* Windows 10 / 11
* Windows PowerShell 5.1 or PowerShell 7+
* Administrator privileges (if BBS Nest or MSFS is in a protected system folder such as `C:\Program Files`)

---

##  How to Run the Script

### Step 1: Close BBS Nest and MSFS
Ensure **Microsoft Flight Simulator** and **BBS Nest** are completely shut down. The patch cannot write to files if they are in use.

---

### Step 2: Locate Your BBS Nest Installation

Find where BBS Nest is installed. 

* **MSFS Community Folder:**`
* **Standalone / Custom Folder:** Wherever you extracted BBS Nest (the folder containing `bbs_nest.exe` and `SubSystem.dll`).

Copy `Fix-BBSNest.ps1` directly into that folder and open PowerShell there.

---

### Step 3: Open PowerShell as Administrator

1. Press the **Windows Key**.
2. Type **PowerShell**.
3. Right-click **Windows PowerShell** and choose **Run as administrator**.

---

### Step 4: Navigate to the Folder

Change directory (`cd`) to where your script or BBS Nest folder is located.

*If you copied the script into your BBS Nest folder:*
```powershell
cd "C:\Path\To\Your\BBS Nest"
```
*(Replace with your actual folder path, wrapped in quotation marks).*

---

### Step 5: Unblock the Script & Allow Execution

Windows blocks downloaded PowerShell scripts by default (`PSSecurityException`). Run these commands:

1. **Unblock the file:**
   ```powershell
   Unblock-File -Path .\Fix-BBSNest.ps1
   ```

2. **Temporarily bypass execution policy for this terminal window:**
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   ```

---

### Step 6: Apply the Patch

#### Option A: Check File Status First (Recommended)
Verify whether your files are recognized:
```powershell
.\Fix-BBSNest.ps1 -Check
```
* If it reports `original`, your files are compatible and ready to patch.
* If it reports `unknown`, your files differ from the version this patch was built for.

#### Option B: Run the Patch
```powershell
.\Fix-BBSNest.ps1
```

If the script is located elsewhere, you can pass the target path directly:
```powershell
.\Fix-BBSNest.ps1 -Path "C:\Path\To\BBS Nest"
```

When successful, you will see:
```text
  [ok] SubSystem.dll patched
  [ok] terr.frag patched

Done. Originals saved as *.orig next to the files.
```

---

##  How to Undo / Revert

If you want to restore the original, untouched files:

1. Open PowerShell as Administrator and navigate to the folder.
2. Run:
   ```powershell
   .\Fix-BBSNest.ps1 -Restore
   ```
This restores `SubSystem.dll` and `shdrsb\terr.frag` from the `.orig` backups.

---

## ⚠️ Notes
* If BBS Nest releases an official update, your patched files may be overwritten. Simply re-run this script after updating. If hashes change, wait for an updated version of the patch.
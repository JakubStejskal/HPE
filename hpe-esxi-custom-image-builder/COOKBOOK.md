# Cookbook — Building an HPE Custom ESXi Image with `Build-HpeEsxiImage.ps1`

This kit turns a stock **VMware ESXi base depot** plus an **HPE Service Pack for ProLiant (SPP)**
into a single, all‑in‑one **installable ISO** and **offline bundle** with HPE drivers and
management agents baked in (smartpqi/nhpsa, bnxtnet/bnxtroce, icen/igbn, qlnativefc, amsd, ilo,
sut, ssacli2, storcli/storcli2 …) — the same content as the official *HPE Custom Image for ESXi*.

It uses VMware **Image Builder** (PowerCLI) and the HPE **Custom AddOn** depot that ships inside
the SPP, which is the HPE‑supported slipstream method.

---

## 1. What you get

Running the script produces, in the output folder:

| File | Description |
|------|-------------|
| `<Name>.iso` | Installable ISO — boots UEFI **and** legacy BIOS, for clean installs |
| `<Name>-depot.zip` | Offline bundle / depot — for `esxcli`, Auto Deploy, or vLCM import |
| `<Name>-viblist.csv` | Full VIB manifest of the built image profile |
| `<Name>-report.txt` | Build summary + GATE‑0 OEM‑target audit |
| `logs\build-*.log` | Full transcript of the run |

---

## 2. Prerequisites (one‑time)

**Easiest: run the bundled installer.** It installs and configures everything below, and is
idempotent (safe to re‑run):

```powershell
.\Install-Prereqs.ps1                 # CurrentUser, uses an existing Python
.\Install-Prereqs.ps1 -Scope AllUsers # machine-wide (run elevated)
.\Install-Prereqs.ps1 -InstallPython  # also install Python via winget if missing
```

What it sets up (and what you'd do by hand otherwise):

- **Windows** with **Windows PowerShell 5.1** or **PowerShell 7.x**.
- **VMware PowerCLI** (provides `VMware.ImageBuilder`, v13+):
  ```powershell
  Install-Module VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber
  ```
  (Use `-Scope AllUsers` from an **elevated** prompt for a machine‑wide install.)
- **Python 3.x** — Image Builder's backend for ISO/bundle export — plus its modules:
  ```powershell
  python -m pip install six psutil pyopenssl lxml
  ```
  Point PowerCLI at it once (the installer and the build script also auto‑detect):
  ```powershell
  Set-PowerCLIConfiguration -PythonPath 'C:\Python312\python.exe' -Scope User -Confirm:$false
  ```
- **~8 GB free disk** in the scratch directory.
- **7‑Zip** — only required for the `-Method Packages` fallback (not for the default AddOn method).

> Tip: verify the backend before a real run —
> `Import-Module VMware.ImageBuilder; Add-EsxSoftwareDepot <base>.zip; Get-EsxImageProfile`
> should list profiles without a Python error.

---

## 3. Inputs you supply

1. **Base depot** — the VMware offline bundle, e.g. `VMware-ESXi-9.1.0.0.25370933-depot.zip`
   (the `-depot.zip`, *not* the installer ISO).
2. **SPP ISO** — the HPE Service Pack for ProLiant for your server generation, e.g.
   `P92600_...gen11spp-2026.03.00.00...iso`.

---

## 4. Quick start

### Easiest — just run it (interactive)

```powershell
.\Build-HpeEsxiImage.ps1
```

With no parameters it starts a guided wizard: a **file-picker window opens** for the base depot
and for the HPE SPP ISO (or you can paste a full path — surrounding quotes from "Copy as path"
are handled). It then shows a build plan and asks you to confirm. Nothing to memorize.

### Or pass parameters (scriptable)

```powershell
.\Build-HpeEsxiImage.ps1 `
    -BaseDepot 'D:\iso\VMware-ESXi-9.1.0.0.25370933-depot.zip' `
    -SppIso    'D:\iso\gen11spp-2026.03.00.00.iso'
```

If you give some but not all required inputs, the script prompts only for what's missing.

That's it. The script auto‑detects the ESXi version (→ platform code `910`), picks the matching
`HPE-910-...-Addon-depot.zip` from the SPP, merges, validates, and writes the deliverables to
`.\build\out\`.

Custom name / vendor / output location:

```powershell
.\Build-HpeEsxiImage.ps1 -BaseDepot .\base.zip -SppIso .\spp.iso `
    -Name 'ESXi-9.1.0-25370933-HPE-Gen11' -Vendor 'Contoso' -OutDir 'D:\images'
```

Point directly at an already‑extracted AddOn (no SPP mount):

```powershell
.\Build-HpeEsxiImage.ps1 -BaseDepot .\base.zip -AddonDepot .\HPE-910...Addon-depot.zip
```

---

## 5. Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-BaseDepot` *(required)* | — | VMware base offline bundle `.zip` |
| `-SppIso` | — | HPE SPP ISO (mounted read‑only, auto‑dismounted) |
| `-AddonDepot` | — | Use a specific AddOn `.zip` directly; skips SPP mount |
| `-Platform` | auto | `910`=9.1, `900`=9.0, `803`=8.0.3, `802`=8.0.2, `800`=8.0. Override if auto‑detect is wrong |
| `-Method` | `AddOn` | `AddOn` (recommended) or `Packages` (fallback extraction from `\packages\`) |
| `-WorkDir` | `<script>\build` | Scratch directory |
| `-OutDir` | `<WorkDir>\out` | Deliverables go here |
| `-Name` | auto | Profile + output base name |
| `-Vendor` | `HPE` | Stamped on the profile |
| `-AcceptanceLevel` | `PartnerSupported` | Min acceptance; accepts Partner/Accepted/Certified VIBs |
| `-PythonPath` | auto | `python.exe` for the export backend |
| `-SkipValidation` | off | Skip the post‑build re‑load checklist |

---

## 6. What the script does

1. **Preflight** — checks Image Builder, the Python backend, and free disk.
2. **Mount SPP** read‑only (if needed).
3. **Add base depot**, read `esx-base` → detect build number and platform code.
4. **Locate the HPE AddOn** `\manifest\vmw\HPE-<platform>-...-Addon-depot.zip` (or extract
   smart components from `\packages\` in `-Method Packages`).
5. **Clone** the base `…-standard` profile under your `-Name`/`-Vendor`.
6. **Merge** every HPE OEM VIB **in one call** (so matched pairs like `bnxtnet`/`bnxtroce`
   resolve together). On any failure it retries per‑VIB to name the culprit and **stops** —
   it never force‑installs over a dependency/acceptance error.
7. **GATE‑0 report** — prints the OEM‑target distribution and the upgrade/no‑downgrade map.
8. **Export** the ISO and offline bundle.
9. **Validate** — re‑loads the *exported bundle* from scratch and checks boot‑critical and
   management VIBs are present.
10. **Cleanup** — clears the Image Builder session and dismounts the SPP.

---

## 7. GATE‑0 — reading the OEM targets (important)

HPE driver/management VIBs carry an OEM target string in their version, e.g. `…-1OEM.910.…`:

| OEM string | ESXi platform |
|-----------|----------------|
| `1OEM.910` | 9.1 |
| `1OEM.900` | 9.0 |
| `1OEM.803` / `1OEM.802` / `1OEM.800` | 8.0.3 / 8.0.2 / 8.0 |

**Key point:** the `910`/`900`/… in an **AddOn file name** is the *platform target* of the AddOn
bulletin — **not** the OEM string of the individual VIBs inside it. An `HPE-910` AddOn legitimately
contains VIBs marked `1OEM.900` (and even `1OEM.800/802` for some management agents): HPE certifies
these to **carry across the minor ESXi bump** (9.0 → 9.1). The script merges them onto the 9.1 base
and validates them; a mix of `900`/`800`/`802` in the report is normal and supported.

The build only **stops** if *no* HPE components can be loaded at all, or if a VIB genuinely fails
dependency/acceptance resolution. The report shows the exact split so you can see what landed.

> Cross‑check baked into the design: the AddOn does **not** override `smartpqi`/`nhpsa`/`lsi-mr3`,
> so those stay at the (newer) VMware 9.1 inbox versions — i.e. the image never downgrades a driver.

---

## 8. Verifying the output

- Open `<Name>-report.txt` — confirm the merged component list and `FAILURES: 0`.
- Open `<Name>-viblist.csv` — full manifest; check your boot‑critical storage (`smartpqi` or
  `nhpsa`), NICs (`bnxtnet`/`icen`/`igbn`), FC (`qlnativefc`), and management (`amsdv`/`ilo`/`sut`).
- The script's own validation pass re‑loads the **exported bundle** to prove it is self‑contained.
- **Always test‑boot on real target hardware** (or a VM for a smoke test) before production.

---

## 9. Deploying the image

- **Clean install:** burn/attach `<Name>.iso` (USB, iLO Virtual Media, PXE) and install as usual.
- **Patch/upgrade an existing host from the offline bundle:**
  ```
  esxcli software profile update -d /vmfs/volumes/<ds>/<Name>-depot.zip -p <ProfileName>
  ```
  (copy the bundle to a datastore first; reboot after).
- **Auto Deploy / Image Builder:** import `<Name>-depot.zip` as a software depot.
- **vCenter Lifecycle Manager (vLCM):** you can import the bundle, but for **cluster** lifecycle
  the recommended model is a **Desired Image** = ESXi Base + **HPE Vendor Addon** + a
  **Firmware & Drivers Addon** delivered via **HPE HSM + SPP**. This ISO is **OS + drivers** for
  clean installs; it does **not** manage firmware.

---

## 10. Troubleshooting

| Symptom | Fix |
|---------|-----|
| `VMware.ImageBuilder not installed` | `Install-Module VMware.PowerCLI -Scope CurrentUser` |
| Python / `Get-EsxImageProfile` errors on export | `pip install six psutil pyopenssl lxml`; pass `-PythonPath` |
| Harmless `pkg_resources is deprecated` / a `Thread-… OSError` traceback | Cosmetic noise from the Image Builder Python helper at teardown — ignore; the build is unaffected |
| `No matching AddOn for platform <code>` | The SPP has no AddOn for that ESXi line. Re‑run with `-Platform <code>` for a line it does have, or use `-Method Packages` |
| A VIB fails with a **dependency**/**acceptance** error | The script lists the exact VIB and stops by design. Don't force it — usually means a wrong base/SPP pairing; verify the SPP supports your ESXi version (HPE SPP release notes) |
| `bnxtnet`/`bnxtroce` conflict | Handled automatically — they're added as a set. If you script your own merge, add matched pairs together |
| AllUsers install permission denied | Run PowerShell **as Administrator**, or use `-Scope CurrentUser` |
| Couldn't mount the SPP | Ensure the `.iso` isn't already mounted and you can run `Mount-DiskImage` |

---

## 11. Support & scope notes

- Confirm your **SPP ↔ ESXi** pairing is supported in the **HPE SPP release notes** before shipping.
  The OEM‑target mix (e.g. `900` drivers on a `9.1` base) is expected and supported when the SPP
  release notes list your ESXi version.
- `ilorest` and a few tools are not always shipped as VMware components in every SPP AddOn; their
  absence from the manifest is normal.
- On ESXi 9.x the Agentless Management daemon VIB is named **`amsdv`** (the old `amsd` name was 7.x).
- This image addresses **OS + drivers**. Use **HPE HSM + SPP** for firmware, and **vLCM Desired
  Image** for ongoing cluster lifecycle.
```

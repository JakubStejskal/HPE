# HPE Custom ESXi Image Builder

Build a single, all-in-one **installable ESXi ISO** + **offline bundle** with HPE drivers and
management agents baked in (smartpqi/nhpsa, bnxtnet/bnxtroce, icen/igbn, qlnativefc, amsd, ilo,
sut, ssacli2, storcli/storcli2 …) — the same content as the official *HPE Custom Image for ESXi*.

It merges a stock VMware ESXi base depot with the **HPE Custom AddOn** depot that ships inside an
HPE **Service Pack for ProLiant (SPP)**, using VMware **Image Builder** (PowerCLI). This is the
HPE-supported slipstream method.

> Scope: **OS + drivers** for clean installs. For firmware use HPE HSM + SPP; for cluster lifecycle
> use vCenter Lifecycle Manager (vLCM) Desired Image. This image does not manage firmware.

## Contents

| File | Purpose |
|------|---------|
| [`Install-Prereqs.ps1`](Install-Prereqs.ps1) | One-time setup: installs PowerCLI + the Python Image Builder backend |
| [`Build-HpeEsxiImage.ps1`](Build-HpeEsxiImage.ps1) | The builder — produces the ISO + offline bundle |
| [`COOKBOOK.md`](COOKBOOK.md) | Full instructions: prerequisites, parameters, GATE-0, deploy, troubleshooting |

## Quick start

```powershell
# 1) one-time setup (installs PowerCLI + Python deps, configures the backend)
.\Install-Prereqs.ps1                 # CurrentUser; use -Scope AllUsers (elevated) for machine-wide

# 2) build — just run it; a guided wizard opens file-pickers for the inputs
.\Build-HpeEsxiImage.ps1
```

Run with **no parameters** and it walks you through it: a file-picker window opens for the base
depot and the HPE SPP ISO (or paste a full path — quotes from "Copy as path" are handled), then it
shows a build plan and asks to confirm. Prefer the command line? Pass parameters instead:

```powershell
.\Build-HpeEsxiImage.ps1 `
    -BaseDepot 'D:\iso\VMware-ESXi-9.1.0.0.25370933-depot.zip' `
    -SppIso    'D:\iso\gen11spp-2026.03.00.00.iso'
```

Any missing required input is prompted for.

The build auto-detects the ESXi version (e.g. 9.1 → platform code `910`), picks the matching
`HPE-910-...-Addon-depot.zip` from the SPP, merges it onto the base profile, validates, and writes
the deliverables to `.\build\out\`:

- `<Name>.iso` — installable, UEFI + legacy BIOS bootable
- `<Name>-depot.zip` — offline bundle / depot
- `<Name>-viblist.csv` — full VIB manifest
- `<Name>-report.txt` — build summary + GATE-0 OEM-target audit

`Get-Help .\Build-HpeEsxiImage.ps1 -Full` for all parameters. See **COOKBOOK.md** for details.

## Supported ESXi versions (not just 9.1)

The builder is **version-agnostic**. It reads `esx-base` from your base bundle, derives the HPE
platform code (`X.Y.Z` → `XYZ`) and auto-selects the matching `HPE-<code>-…-Addon-depot.zip` from
the SPP. Output naming adapts too.

| Target ESXi | esx-base | code | AddOn picked |
|---|---|---|---|
| 8.0 U2 | 8.0.2 | `802` | `HPE-802-…-Addon-depot.zip` |
| 8.0 U3 (incl. U3x, e.g. "U3j") | 8.0.3 | `803` | `HPE-803-…-Addon-depot.zip` |
| 9.0 | 9.0.0 | `900` | `HPE-900-…-Addon-depot.zip` |
| 9.1 | 9.1.0 | `910` | `HPE-910-…-Addon-depot.zip` |

You provide (1) the **base offline bundle for that exact build** and (2) an **SPP that ships the
matching `HPE-<code>` AddOn** (for your server generation) — or pass the standalone *HPE Custom
AddOn* with `-AddonDepot <zip>`. A patch level (the "j" in *8.0 U3j*) maps to the same update code
(`803`) and uses the same AddOn. Overrides: `-Platform <code>`, `-AddonDepot <zip>`, `-Method Packages`.
See **COOKBOOK.md → §4b** for full details.

## Requirements

- Windows + Windows PowerShell 5.1 or PowerShell 7.x
- VMware PowerCLI 13+ (`VMware.ImageBuilder`) with a working Python backend — handled by `Install-Prereqs.ps1`
- ~8 GB free disk; 7-Zip only for the `-Method Packages` fallback
- A VMware ESXi base offline bundle (`-depot.zip`) and an HPE SPP ISO

## Notes

- Works for ESXi 8.0.x / 9.0 / 9.1 and Gen10/Gen11 — pass `-Platform <code>` to override auto-detect.
- The `910`/`900`/… in an AddOn *name* is the platform target, not the VIB OEM string; HPE VIBs are
  certified to carry across minor ESXi bumps (see COOKBOOK § GATE-0).
- Build artifacts (`.iso`, `-depot.zip`, `build/`, `logs/`) are intentionally git-ignored.

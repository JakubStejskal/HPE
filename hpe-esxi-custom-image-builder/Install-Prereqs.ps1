<#
.SYNOPSIS
    Installs and verifies everything Build-HpeEsxiImage.ps1 needs:
    VMware PowerCLI (VMware.ImageBuilder) + the Python Image Builder backend modules,
    and points PowerCLI at Python. Idempotent - safe to re-run.

.DESCRIPTION
    1. Ensures TLS 1.2, the NuGet provider, and a trusted PSGallery.
    2. Installs VMware.PowerCLI (skips if already present unless -Force).
    3. Locates Python 3.x (or installs it via winget with -InstallPython) and
       pip-installs: six psutil pyopenssl lxml.
    4. Configures PowerCLI: -PythonPath, CEIP off, ignore invalid certs.
    5. Verifies the backend (imports the modules; loads VMware.ImageBuilder).

.PARAMETER Scope
    CurrentUser (default, no admin) or AllUsers (requires an elevated session).

.PARAMETER PythonPath
    Path to python.exe. Default: auto-detect (PATH / common install dirs).

.PARAMETER InstallPython
    If Python isn't found, install it via winget (Python.Python.3.12).

.PARAMETER Force
    Reinstall PowerCLI even if already present; reinstall pip modules with --upgrade.

.EXAMPLE
    .\Install-Prereqs.ps1
        # CurrentUser PowerCLI + pip deps + config, using an existing Python.

.EXAMPLE
    # From an elevated PowerShell:
    .\Install-Prereqs.ps1 -Scope AllUsers

.EXAMPLE
    .\Install-Prereqs.ps1 -InstallPython
        # also installs Python via winget if missing.

.NOTES
    Internet access to PSGallery (and winget, if used) is required.
#>
[CmdletBinding()]
param(
    [ValidateSet('CurrentUser','AllUsers')] [string]$Scope = 'CurrentUser',
    [string]$PythonPath,
    [switch]$InstallPython,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Info($m){ Write-Host ("[*] " + $m) -ForegroundColor Cyan }
function Ok($m)  { Write-Host ("[+] " + $m) -ForegroundColor Green }
function Warn($m){ Write-Host ("[!] " + $m) -ForegroundColor Yellow }
function Die($m) { Write-Host ("[X] " + $m) -ForegroundColor Red; exit 1 }

Write-Host "=== HPE ESXi Image Builder - prerequisite installer ===" -ForegroundColor White
Info ("PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

# ---------- elevation check for AllUsers ----------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Scope -eq 'AllUsers' -and -not $isAdmin) {
    Die "Scope AllUsers requires an elevated session. Re-run PowerShell as Administrator, or use -Scope CurrentUser."
}
Ok ("Scope: {0}{1}" -f $Scope, $(if($isAdmin){' (elevated)'}else{''}))

# ---------- 1. PSGallery / NuGet / TLS ----------
Info "Preparing PowerShell Gallery"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { Get-PackageProvider -Name NuGet -ForceBootstrap -ErrorAction Stop | Out-Null; Ok "NuGet provider present" }
catch { Warn "Could not bootstrap NuGet automatically: $($_.Exception.Message)" }
try {
    if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Ok "PSGallery set Trusted"
    } else { Ok "PSGallery already Trusted" }
} catch { Warn "Could not set PSGallery trusted: $($_.Exception.Message)" }

# ---------- 2. PowerCLI ----------
$existing = Get-Module -ListAvailable VMware.ImageBuilder | Sort-Object Version -Descending | Select-Object -First 1
if ($existing -and -not $Force) {
    Ok ("VMware.ImageBuilder already installed: {0}" -f $existing.Version)
} else {
    Info ("Installing VMware.PowerCLI (Scope {0}) - this can take several minutes" -f $Scope)
    $p = @{ Name='VMware.PowerCLI'; Scope=$Scope; Force=$true; AllowClobber=$true; SkipPublisherCheck=$true }
    Install-Module @p
    $existing = Get-Module -ListAvailable VMware.ImageBuilder | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $existing) { Die "VMware.ImageBuilder not present after install." }
    Ok ("Installed VMware.ImageBuilder {0}" -f $existing.Version)
}

# ---------- 2b. ensure the LATEST VMware.ImageBuilder ----------
# The VMware.PowerCLI meta-module can pin an older Image Builder. Newer ESXi 9.1
# *patch* depots need the matching (9.1-era) Image Builder, otherwise
# New-EsxImageProfile fails with "File path ... is claimed by multiple non-overlay
# VIBs" between esx-base and esxio-base. So upgrade the standalone module if older.
try {
    $latestIB = (Find-Module VMware.ImageBuilder -ErrorAction Stop).Version
    $haveIB   = (Get-Module -ListAvailable VMware.ImageBuilder | Sort-Object Version -Descending | Select-Object -First 1).Version
    if ([version]$haveIB -lt [version]$latestIB) {
        Info ("Updating VMware.ImageBuilder {0} -> {1}" -f $haveIB,$latestIB)
        Install-Module VMware.ImageBuilder -Scope $Scope -Force -AllowClobber -SkipPublisherCheck
        $haveIB = (Get-Module -ListAvailable VMware.ImageBuilder | Sort-Object Version -Descending | Select-Object -First 1).Version
        Ok ("VMware.ImageBuilder now {0}" -f $haveIB)
    } else { Ok ("VMware.ImageBuilder is current ({0})" -f $haveIB) }
} catch { Warn ("Could not check/update VMware.ImageBuilder: {0}" -f $_.Exception.Message) }

# ---------- 3. Python (must match an Image Builder backend version) ----------
# Image Builder ships a Python backend only for specific 3.x versions (folders
# <module>\server\python-3XX). A too-new Python (e.g. 3.14) makes the backend misbehave
# and the build later fails with "edge.json claimed by multiple non-overlay VIBs".
function Get-IbPythonVersions {
    $m = Get-Module -ListAvailable VMware.ImageBuilder | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $m) { return @() }
    # folders live under <ModuleBase>\<framework>\server\python-3XX
    @(Get-ChildItem $m.ModuleBase -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^python-3(\d+)$' } |
        ForEach-Object { [int]($_.Name -replace '^python-3','') } | Sort-Object -Unique)
}
function Get-PyMinor([string]$exe){ try { $o=(& $exe -c "import sys;print(sys.version_info[1])" 2>$null); if($o){return [int]("$o".Trim())} } catch {}; return $null }
function Find-Python {
    param([string]$Hint,[int[]]$Supported)
    $cands = @()
    if ($Hint) { $cands += $Hint }
    $cands += (Get-Command python  -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | ForEach-Object Source)
    $cands += (Get-Command python3 -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | ForEach-Object Source)
    $cands += (Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | ForEach-Object FullName)
    $cands += 'C:\Python313\python.exe','C:\Python312\python.exe','C:\Python311\python.exe','C:\Python310\python.exe'
    $cands = $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    if ($Supported) { foreach($c in $cands){ $mm=Get-PyMinor $c; if($mm -and ($mm -in $Supported)){ return $c } } }
    if ($cands) { return $cands[0] }
    return $null
}

$ibPy    = Get-IbPythonVersions
$ibPyTxt = if ($ibPy) { "3.$($ibPy[0])-3.$($ibPy[-1])" } else { "unknown" }

$py = Find-Python -Hint $PythonPath -Supported $ibPy
# if nothing found, or the only Python is unsupported, optionally install a supported one
$needInstall = (-not $py) -or ($ibPy -and ((Get-PyMinor $py) -notin $ibPy))
if ($needInstall -and $InstallPython) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info "Installing supported Python 3.12 via winget"
        winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
        $py = Find-Python -Supported $ibPy
    } else { Warn "winget not available; cannot auto-install Python." }
}
if (-not $py) { Die "Python 3.x not found. Install a supported version ($ibPyTxt), e.g. 'winget install Python.Python.3.12', then re-run or pass -PythonPath." }
Ok ("Python: {0}" -f $py)
$pyMinor = Get-PyMinor $py
Ok ("  Python 3.$pyMinor   (Image Builder supports $ibPyTxt)")
if ($ibPy -and ($pyMinor -notin $ibPy)) {
    Warn ("Python 3.$pyMinor is NOT supported by the installed Image Builder (needs $ibPyTxt).")
    Warn  "Image builds will fail with 'edge.json claimed by multiple non-overlay VIBs'."
    Warn  "Install a supported Python (e.g. winget install Python.Python.3.12), then re-run with -PythonPath - or re-run this script with -InstallPython."
}

# ---------- 3b. pip modules ----------
Info "Installing Python Image Builder modules (six psutil pyopenssl lxml)"
# NOTE: pip prints harmless warnings (e.g. "Scripts not on PATH") to stderr. Under Windows
# PowerShell 5.1 with $ErrorActionPreference='Stop' + 2>&1, native stderr is turned into a
# terminating NativeCommandError. So we relax EAP for the native pip calls, suppress that
# specific warning, and treat the Python import test below as the authoritative result.
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& $py -m pip install --upgrade --no-warn-script-location pip 2>&1 | ForEach-Object { Write-Verbose "$_" }
$pipArgs = @('-m','pip','install','--no-warn-script-location','six','psutil','pyopenssl','lxml')
if ($Force) { $pipArgs += '--upgrade' }
& $py @pipArgs 2>&1 | ForEach-Object { Write-Verbose "$_" }
$check = (& $py -c "import six, psutil, OpenSSL, lxml; print('ok')" 2>&1) -join ' '
$ErrorActionPreference = $eap
if ($check -match 'ok') { Ok "Python modules import OK (six, psutil, OpenSSL, lxml)" }
else { Die "Python module verification failed: $check" }

# ---------- 4. configure PowerCLI ----------
Info "Configuring PowerCLI"
Import-Module VMware.ImageBuilder -ErrorAction Stop 3>$null
Set-PowerCLIConfiguration -PythonPath $py -ParticipateInCeip $false -InvalidCertificateAction Ignore -Scope User -Confirm:$false | Out-Null
Ok ("PowerCLI PythonPath set to {0} (User scope), CEIP off" -f $py)

# ---------- 5. final verification ----------
Info "Verifying Image Builder backend"
try {
    # cmdlet availability + module load already proven; confirm config persisted
    $cfg = Get-PowerCLIConfiguration -Scope User
    if ($cfg.PythonPath) { Ok ("Backend configured: {0}" -f $cfg.PythonPath) } else { Warn "PythonPath not reflected in config; pass -PythonPath to the build script." }
} catch { Warn $_.Exception.Message }

Write-Host ""
Ok "PREREQUISITES READY"
Write-Host "Next:" -ForegroundColor White
Write-Host "  .\Build-HpeEsxiImage.ps1 -BaseDepot <VMware-...-depot.zip> -SppIso <spp.iso>" -ForegroundColor Gray

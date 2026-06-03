<#
.SYNOPSIS
    Builds a merged HPE Custom ESXi installable ISO + offline bundle from a VMware base
    depot and an HPE Service Pack for ProLiant (SPP), the HPE-supported slipstream way.

.DESCRIPTION
    Takes the VMware base offline bundle (depot .zip) and an HPE SPP ISO (Gen10/Gen11),
    locates the matching "HPE Custom AddOn for ESXi" depot inside the SPP
    (\manifest\vmw\HPE-<platform>-...-Addon-depot.zip), merges it onto the VMware base
    image profile with VMware Image Builder (PowerCLI), and exports:
        - <Name>.iso          (installable, UEFI + legacy BIOS bootable)
        - <Name>-depot.zip    (offline bundle / depot)
        - <Name>-viblist.csv  (full VIB manifest)
        - <Name>-report.txt   (build + GATE-0 OEM audit report)

    Primary method = the official HPE AddOn depot (recommended, supported).
    Fallback method = extract the individual VMware smart components from \packages\
    (use -Method Packages) for SPPs that ship no AddOn depot.

.PARAMETER BaseDepot
    Path to the VMware base offline bundle, e.g. VMware-ESXi-9.1.0.0.25370933-depot.zip

.PARAMETER SppIso
    Path to the HPE SPP ISO. The script mounts it read-only and finds the AddOn.

.PARAMETER AddonDepot
    (Optional) Path to an already-extracted HPE AddOn depot .zip. If given, -SppIso is
    not required and no ISO is mounted.

.PARAMETER Platform
    (Optional) HPE platform code to select when the SPP has several AddOns:
    910=ESXi 9.1, 900=9.0, 803=8.0.3, 802=8.0.2, 800=8.0. Default: auto-detected from
    the base depot's esx-base version.

.PARAMETER Method
    AddOn (default) | Packages. Packages = fallback extraction from \packages\.

.PARAMETER WorkDir
    Scratch directory. Default: <script dir>\build.

.PARAMETER OutDir
    Output directory for deliverables. Default: <WorkDir>\out.

.PARAMETER Name
    Image profile + output base name. Default: ESXi-<build>-HPE-Custom.

.PARAMETER Vendor
    Vendor string stamped on the profile. Default: HPE.

.PARAMETER AcceptanceLevel
    Profile acceptance level. Default: PartnerSupported (accepts Partner/Accepted/Certified VIBs).

.PARAMETER PythonPath
    Path to python.exe for the Image Builder backend. Default: auto-detected.

.PARAMETER SkipValidation
    Skip the post-build re-load/validation pass.

.EXAMPLE
    .\Build-HpeEsxiImage.ps1 `
        -BaseDepot 'D:\iso\VMware-ESXi-9.1.0.0.25370933-depot.zip' `
        -SppIso    'D:\iso\gen11spp-2026.03.00.00.iso'

.EXAMPLE
    .\Build-HpeEsxiImage.ps1 -BaseDepot .\base.zip -SppIso .\spp.iso -Platform 900 -Name ESXi-9.0-HPE

.NOTES
    Requires: Windows PowerShell 5.1 or PowerShell 7.x, VMware.ImageBuilder (PowerCLI 13+)
    with a working Python backend, ~8 GB free disk, and (for -Method Packages) 7-Zip.
    This image is OS+drivers for clean installs. For cluster lifecycle/firmware use vLCM
    Desired Image (Base + HPE Vendor Addon + SPP via HSM), not this ISO.
#>
[CmdletBinding()]
param(
    [string]$BaseDepot,
    [string]$SppIso,
    [string]$AddonDepot,
    [ValidatePattern('^\d{3}$')] [string]$Platform,
    [ValidateSet('AddOn','Packages')] [string]$Method = 'AddOn',
    [string]$WorkDir,
    [string]$OutDir,
    [string]$Name,
    [string]$Vendor = 'HPE',
    [ValidateSet('PartnerSupported','VMwareAccepted','VMwareCertified','CommunitySupported')]
    [string]$AcceptanceLevel = 'PartnerSupported',
    [string]$PythonPath,
    [switch]$SkipValidation
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------- helpers ----------
function Info($m){ Write-Host ("[*] " + $m) -ForegroundColor Cyan }
function Ok($m)  { Write-Host ("[+] " + $m) -ForegroundColor Green }
function Warn($m){ Write-Host ("[!] " + $m) -ForegroundColor Yellow }
function Die($m) { Write-Host ("[X] " + $m) -ForegroundColor Red; throw $m }
function OemOf([string]$v){
    if ($v -match '1OEM\.(\d{3})') { return $matches[1] }
    if ($v -match '(?<![\d.])(\d)\.0\.0\.\d') { return ('0'+$matches[1]+'0') } # e.g. 8.0.0 -> 080
    return '----'
}

$script:Report = New-Object System.Collections.Generic.List[string]
function Rep($m){ $script:Report.Add($m); Write-Host $m }
function Clear-Depots {
    # robust: wildcard 'Remove-EsxSoftwareDepot *' is unreliable across PowerCLI versions
    try { Get-EsxSoftwareDepot -ErrorAction SilentlyContinue | ForEach-Object { Remove-EsxSoftwareDepot $_ -ErrorAction SilentlyContinue } } catch {}
}

# ---- interactive input helpers ----
function Clear-PathInput([string]$s){
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $s = $s.Trim()
    # strip one layer of surrounding quotes (e.g. paths copied via "Copy as path")
    if ($s.Length -ge 2 -and (($s[0] -eq '"' -and $s[-1] -eq '"') -or ($s[0] -eq "'" -and $s[-1] -eq "'"))) {
        $s = $s.Substring(1, $s.Length - 2)
    }
    return $s.Trim()
}

function Show-FilePicker {
    # Opens a native Open-File dialog. Hosted in an STA runspace so it works under
    # PowerShell 7 (MTA) too. Returns the chosen path, or $null if cancelled/unavailable.
    param([string]$Title,[string]$Filter='All files (*.*)|*.*',[string]$InitialDir)
    try {
        $code = {
            param($Title,$Filter,$InitialDir)
            Add-Type -AssemblyName System.Windows.Forms
            $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = $Title; $dlg.Filter = $Filter; $dlg.Multiselect = $false
            if ($InitialDir -and (Test-Path -LiteralPath $InitialDir)) { $dlg.InitialDirectory = $InitialDir }
            $r = $dlg.ShowDialog($owner)
            $owner.Dispose()
            if ($r -eq [System.Windows.Forms.DialogResult]::OK) { $dlg.FileName } else { '' }
        }
        $ps = [PowerShell]::Create()
        $rs = [RunspaceFactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.ThreadOptions='ReuseThread'; $rs.Open()
        $ps.Runspace = $rs
        [void]$ps.AddScript($code).AddArgument($Title).AddArgument($Filter).AddArgument($InitialDir)
        $res = $ps.Invoke() | Select-Object -Last 1
        $ps.Dispose(); $rs.Close()
        if ([string]::IsNullOrWhiteSpace($res)) { return $null } else { return [string]$res }
    } catch { return $null }
}

function Read-FilePath {
    # Asks for a file: opens a picker first, then accepts a typed/pasted path. Loops until valid.
    param([string]$Prompt,[string]$Filter='All files (*.*)|*.*',[string]$InitialDir)
    Write-Host ""
    Write-Host (">> " + $Prompt) -ForegroundColor White
    Write-Host "   (a file-picker window will open; close/cancel it to type a path instead)" -ForegroundColor DarkGray
    $gui = Show-FilePicker -Title $Prompt -Filter $Filter -InitialDir $InitialDir
    if ($gui -and (Test-Path -LiteralPath $gui)) { Ok ("selected: {0}" -f $gui); return (Resolve-Path -LiteralPath $gui).Path }
    while ($true) {
        $typed = Clear-PathInput (Read-Host "   Paste full path (or 'b' to browse again)")
        if (-not $typed) { Warn "Nothing entered."; continue }
        if ($typed -in 'b','B') {
            $gui = Show-FilePicker -Title $Prompt -Filter $Filter -InitialDir $InitialDir
            if ($gui -and (Test-Path -LiteralPath $gui)) { Ok ("selected: {0}" -f $gui); return (Resolve-Path -LiteralPath $gui).Path }
            continue
        }
        if (Test-Path -LiteralPath $typed) { return (Resolve-Path -LiteralPath $typed).Path }
        Warn "Not found: $typed  — check the path and try again."
    }
}

# ---------- 0. resolve inputs (interactive wizard if missing) ----------
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDepot  = Clear-PathInput $BaseDepot
$SppIso     = Clear-PathInput $SppIso
$AddonDepot = Clear-PathInput $AddonDepot

$needBase = (-not $BaseDepot) -or (-not (Test-Path -LiteralPath $BaseDepot))
$needSrc  = if ($Method -eq 'Packages') { -not $SppIso } else { (-not $AddonDepot) -and (-not $SppIso) }
$interactive = $false

if ($needBase -or $needSrc) {
    $interactive = $true
    Write-Host ""
    Write-Host "===== HPE Custom ESXi Image Builder - interactive setup =====" -ForegroundColor White
    Write-Host "No (valid) input parameters detected - I'll walk you through it." -ForegroundColor DarkGray
    Write-Host "A file-picker opens for each file; or paste a full path (surrounding quotes are OK)." -ForegroundColor DarkGray
    Write-Host "Tip: you can also run it directly, e.g.:  .\Build-HpeEsxiImage.ps1 -BaseDepot <...-depot.zip> -SppIso <...spp.iso>" -ForegroundColor DarkGray
}

$initDir = if ($BaseDepot) { try { Split-Path -LiteralPath $BaseDepot } catch { $here } } else { $here }

if ($needBase) {
    if ($BaseDepot) { Warn "BaseDepot not found: $BaseDepot" }
    $BaseDepot = Read-FilePath -Prompt 'Select the VMware ESXi BASE depot   (VMware-ESXi-...-depot.zip)' `
                    -Filter 'ESXi base depot (*-depot.zip;*.zip)|*-depot.zip;*.zip|All files (*.*)|*.*' -InitialDir $initDir
}
$BaseDepot = (Resolve-Path -LiteralPath $BaseDepot).Path
$initDir   = try { Split-Path -LiteralPath $BaseDepot } catch { $here }

if ($needSrc) {
    if ($Method -eq 'Packages') {
        $SppIso = Read-FilePath -Prompt 'Select the HPE SPP ISO   (required for -Method Packages)' `
                    -Filter 'SPP ISO (*.iso)|*.iso|All files (*.*)|*.*' -InitialDir $initDir
    } else {
        Write-Host ""
        Write-Host ">> Where are the HPE driver/management components?" -ForegroundColor White
        Write-Host "   [1] HPE SPP ISO            (recommended - I'll find the matching AddOn inside)" -ForegroundColor Gray
        Write-Host "   [2] HPE AddOn depot (.zip) (HPE-<platform>-...-Addon-depot.zip)" -ForegroundColor Gray
        $choice = (Read-Host "   Choose 1 or 2 [1]").Trim()
        if ($choice -eq '2') {
            $AddonDepot = Read-FilePath -Prompt 'Select the HPE AddOn depot   (HPE-...-Addon-depot.zip)' `
                            -Filter 'HPE AddOn depot (HPE-*Addon-depot.zip;*.zip)|HPE-*Addon-depot.zip;*.zip|All files (*.*)|*.*' -InitialDir $initDir
        } else {
            $SppIso = Read-FilePath -Prompt 'Select the HPE SPP ISO   (e.g. ...gen11spp...iso)' `
                        -Filter 'SPP ISO (*.iso)|*.iso|All files (*.*)|*.*' -InitialDir $initDir
        }
    }
}

# validate any CLI-supplied source paths (interactive ones are already validated)
if ($AddonDepot) { if (-not (Test-Path -LiteralPath $AddonDepot)) { Die "AddonDepot not found: $AddonDepot" }; $AddonDepot = (Resolve-Path -LiteralPath $AddonDepot).Path }
if ($SppIso)     { if (-not (Test-Path -LiteralPath $SppIso))     { Die "SppIso not found: $SppIso" };       $SppIso     = (Resolve-Path -LiteralPath $SppIso).Path }

# scratch + output dirs (override OutDir interactively; just press Enter for the default)
if (-not $WorkDir) { $WorkDir = Join-Path $here 'build' }
if (-not $OutDir)  { $OutDir  = Join-Path $WorkDir 'out' }
if ($interactive) {
    $od = Clear-PathInput (Read-Host ("`n>> Output folder for the ISO + bundle [{0}]" -f $OutDir))
    if ($od) { $OutDir = $od }
}
$null = New-Item -ItemType Directory -Force -Path $WorkDir,$OutDir
$logDir = Join-Path $WorkDir 'logs'; $null = New-Item -ItemType Directory -Force -Path $logDir

# confirm the plan
$srcShow = if ($AddonDepot) { "AddOn : $AddonDepot" } else { "SPP   : $SppIso" }
Write-Host ""
Write-Host "===== Build plan =====" -ForegroundColor White
Write-Host ("  Base depot : {0}" -f $BaseDepot)
Write-Host ("  HPE source : {0}" -f $srcShow)
Write-Host ("  Method     : {0}" -f $Method)
Write-Host ("  Vendor     : {0}" -f $Vendor)
Write-Host ("  Output dir : {0}" -f $OutDir)
if ($interactive) {
    if ((Read-Host "Proceed with the build? [Y/n]").Trim() -match '^(n|no)$') {
        Write-Host "Aborted by user." -ForegroundColor Yellow; return
    }
}

$transcript = Join-Path $logDir ('build-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $transcript -Force | Out-Null } catch {}

try {
    # ---------- 1. preflight ----------
    Info "Preflight checks"
    $ib = Get-Module -ListAvailable VMware.ImageBuilder | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $ib) { Die "VMware.ImageBuilder not installed. Run:  Install-Module VMware.PowerCLI -Scope CurrentUser" }
    Import-Module VMware.ImageBuilder -ErrorAction Stop 3>$null
    Ok ("VMware.ImageBuilder {0}" -f $ib.Version)

    if (-not $PythonPath) {
        $cfg = (Get-PowerCLIConfiguration -Scope User -ErrorAction SilentlyContinue).PythonPath
        if ($cfg -and (Test-Path $cfg)) { $PythonPath = $cfg }
        else {
            foreach ($c in @((Get-Command python -ErrorAction SilentlyContinue).Source,
                             'C:\Python312\python.exe','C:\Python311\python.exe','C:\Python310\python.exe')) {
                if ($c -and (Test-Path $c)) { $PythonPath = $c; break }
            }
        }
    }
    if (-not $PythonPath -or -not (Test-Path $PythonPath)) {
        Die "Python not found. Install Python 3.x + 'pip install six psutil pyopenssl lxml', then pass -PythonPath."
    }
    Set-PowerCLIConfiguration -PythonPath $PythonPath -ParticipateInCeip $false -Scope Session -Confirm:$false 2>$null | Out-Null
    Ok ("Python backend: {0}" -f $PythonPath)

    $freeGB = [math]::Round((Get-PSDrive -Name ($WorkDir.Substring(0,1)) -ErrorAction SilentlyContinue).Free/1GB,1)
    if ($freeGB -and $freeGB -lt 8) { Warn "Only $freeGB GB free in WorkDir drive (recommend >= 8 GB)." } else { Ok "Free disk: $freeGB GB" }

    # ---------- 2. mount SPP if needed ----------
    $mounted = $null; $sppDrive = $null
    if (-not $AddonDepot -and $SppIso) {
        Info "Mounting SPP ISO (read-only)"
        $mounted  = Mount-DiskImage -ImagePath $SppIso -PassThru
        Start-Sleep -Seconds 2
        $sppDrive = ($mounted | Get-Volume).DriveLetter
        Ok ("SPP mounted at {0}:" -f $sppDrive)
    } elseif ($Method -eq 'Packages' -and $SppIso) {
        Info "Mounting SPP ISO (read-only)"
        $mounted  = Mount-DiskImage -ImagePath $SppIso -PassThru
        Start-Sleep -Seconds 2
        $sppDrive = ($mounted | Get-Volume).DriveLetter
        Ok ("SPP mounted at {0}:" -f $sppDrive)
    }

    # ---------- 3. add base depot, detect build + platform ----------
    Info "Adding base depot"
    Add-EsxSoftwareDepot $BaseDepot | Out-Null
    $esxBase = Get-EsxSoftwarePackage -Name esx-base -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $esxBase) { Die "esx-base not found in base depot — not a valid ESXi offline bundle?" }
    $buildId = ($esxBase.Version -split '-')[-1] -replace '^\d+\.','' ; $buildId = ($esxBase.Version -split '\.')[-1]
    $verTriplet = ($esxBase.Version -split '-')[0]            # e.g. 9.1.0
    if (-not $Platform) {
        $p = $verTriplet -split '\.'
        $Platform = '{0}{1}{2}' -f $p[0],$p[1],$p[2]          # 9.1.0 -> 910
    }
    $baseProf = Get-EsxImageProfile | Where-Object Name -match 'standard' | Select-Object -First 1
    if (-not $baseProf) { $baseProf = Get-EsxImageProfile | Select-Object -First 1 }
    if (-not $Name) { $Name = "ESXi-$($baseProf.Name -replace '^ESXi-','' -replace '-standard$','')-HPE-Custom" }
    Ok ("Base profile: {0}  (esx-base {1}, platform code {2})" -f $baseProf.Name,$esxBase.Version,$Platform)

    # ---------- 4. locate / add HPE content ----------
    if ($Method -eq 'AddOn') {
        if (-not $AddonDepot) {
            $vmw = Join-Path ("${sppDrive}:") 'manifest\vmw'
            if (-not (Test-Path $vmw)) { Die "No \manifest\vmw on SPP. Use -Method Packages." }
            $cand = Get-ChildItem (Join-Path $vmw ("HPE-{0}.*Addon-depot.zip" -f $Platform)) -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cand) {
                $all = Get-ChildItem (Join-Path $vmw 'HPE-*Addon-depot.zip') -ErrorAction SilentlyContinue
                Warn ("No AddOn for platform {0}. Available: {1}" -f $Platform, (($all.Name) -join ', '))
                Die "No matching AddOn. Re-run with -Platform <code> or -Method Packages."
            }
            $AddonDepot = Join-Path $WorkDir $cand.Name
            Copy-Item $cand.FullName $AddonDepot -Force
            Ok ("Using AddOn: {0}" -f $cand.Name)
        }
        Add-EsxSoftwareDepot $AddonDepot | Out-Null
        $hpe = Get-EsxSoftwarePackage | Where-Object { $_.Version -match '1OEM\.' } | Sort-Object Name,Version
    }
    else {
        # --- Packages fallback: extract inner VMware bundles from \packages\ ---
        $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
        if (-not $sevenZip) { foreach($c in 'C:\Program Files\7-Zip\7z.exe','C:\Program Files (x86)\7-Zip\7z.exe'){ if(Test-Path $c){$sevenZip=$c;break} } }
        if (-not $sevenZip) { Die "7-Zip required for -Method Packages. Install 7-Zip." }
        $ext = Join-Path $WorkDir 'hpe-components'
        Get-ChildItem $ext -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Force -Path $ext
        $pkgsDir = Join-Path ("${sppDrive}:") 'packages'
        $comps = Get-ChildItem (Join-Path $pkgsDir '*.zip') -ErrorAction SilentlyContinue
        Info ("Extracting inner bundles from {0} smart components" -f $comps.Count)
        foreach ($c in $comps) {
            $d = Join-Path $ext $c.BaseName; $null = New-Item -ItemType Directory -Force -Path $d
            & $sevenZip e $c.FullName "-o$d" "*.zip" -y -bso0 -bsp0 2>$null | Out-Null
        }
        Get-ChildItem (Join-Path $ext '*\*.zip') | ForEach-Object { try { Add-EsxSoftwareDepot $_.FullName | Out-Null } catch {} }
        # select: HPE OEM VIBs, exclude pure-firmware (CPxxxx names / 8.0.0 targets when building 9.x),
        # dedup by name keeping the version whose OEM target best matches the platform then newest.
        $rank = { param($v) $o = OemOf $v; switch ($o) { $Platform {3} '900' {2} '800' {1} default {0} } }
        $cand = Get-EsxSoftwarePackage | Where-Object {
            $_.Version -match '1OEM\.' -and $_.Name -notmatch '^CP\d' -and (OemOf $_.Version) -ne ('0'+$Platform.Substring(0,1)+'0')
        }
        $hpe = $cand | Group-Object Name | ForEach-Object {
            $_.Group | Sort-Object @{e={& $rank $_.Version}},Version -Descending | Select-Object -First 1
        } | Sort-Object Name
        Warn "Packages fallback is best-effort; AddOn method is preferred where available."
    }

    if (-not $hpe -or $hpe.Count -eq 0) { Die "No HPE components found to merge. Check Platform/Method." }
    Ok ("HPE components to merge: {0}" -f $hpe.Count)

    # ---------- 5. clone + merge ----------
    Info "Cloning base profile and merging HPE components"
    if (Get-EsxImageProfile -Name $Name -ErrorAction SilentlyContinue) { Remove-EsxImageProfile -ImageProfile $Name -Confirm:$false }
    $null = New-EsxImageProfile -CloneProfile $baseProf.Name -Name $Name -Vendor $Vendor -AcceptanceLevel $AcceptanceLevel

    $names  = $hpe.Name | Sort-Object -Unique
    $before = @{}; foreach($v in (Get-EsxImageProfile -Name $Name).VibList | Where-Object {$names -contains $_.Name}){ $before[$v.Name]=$v.Version }

    # add as a single set so matched pairs (e.g. bnxtnet/bnxtroce) resolve together;
    # fall back to per-VIB to pinpoint any failure.
    $failed = New-Object System.Collections.Generic.List[object]
    try {
        Add-EsxSoftwarePackage -ImageProfile $Name -SoftwarePackage $hpe -ErrorAction Stop | Out-Null
    } catch {
        Warn "Set-add failed; retrying per-VIB to locate culprit"
        foreach ($p in $hpe) {
            try { Add-EsxSoftwarePackage -ImageProfile $Name -SoftwarePackage $p -ErrorAction Stop | Out-Null }
            catch { $failed.Add([pscustomobject]@{Name=$p.Name;Version=$p.Version;Reason=$_.Exception.Message}) }
        }
    }

    $prof = Get-EsxImageProfile -Name $Name
    $after = @{}; foreach($v in $prof.VibList | Where-Object {$names -contains $_.Name}){ $after[$v.Name]=$v.Version }

    # ---------- 6. GATE-0 report ----------
    Rep ("==== HPE ESXi Custom Image build report : {0} ====" -f (Get-Date))
    Rep ("Base profile     : {0}" -f $baseProf.Name)
    Rep ("Output profile   : {0}  (Vendor {1}, {2})" -f $Name,$Vendor,$AcceptanceLevel)
    Rep ("HPE source       : {0}  [{1}]" -f $(if($AddonDepot){Split-Path $AddonDepot -Leaf}else{'packages extraction'}),$Method)
    Rep ("Platform code    : {0}" -f $Platform)
    Rep ("Profile VIBs     : {0}" -f $prof.VibList.Count)
    Rep ""
    Rep "---- merged HPE components (version  <- replaced) ----"
    foreach ($n in $names) {
        if ($after[$n]) { Rep ("  {0,-14} {1}   <- {2}" -f $n,$after[$n], $(if($before[$n]){$before[$n]}else{'(new)'})) }
    }
    Rep ""
    Rep "---- GATE-0: OEM target distribution of merged HPE VIBs ----"
    $split = ($names | Where-Object {$after[$_]} | ForEach-Object { OemOf $after[$_] } | Group-Object | Sort-Object Name)
    foreach ($g in $split) { Rep ("  1OEM.{0,-5} : {1}" -f $g.Name,$g.Count) }
    Rep "  (note: the '910/900/...' in an AddOn *name* is the platform target, not the VIB OEM string;"
    Rep "   HPE VIBs are certified to carry across minor ESXi bumps. See cookbook GATE-0.)"
    if ($failed.Count) {
        Rep ""
        Rep ("---- FAILURES ({0}) : reported, NOT force-installed ----" -f $failed.Count)
        foreach ($f in $failed) { Rep ("  {0} {1} :: {2}" -f $f.Name,$f.Version,$f.Reason) }
    }

    if ($failed.Count) { Die "$($failed.Count) component(s) failed to add (see report). Resolve before shipping; not force-installing." }

    # ---------- 7. export ----------
    $outIso = Join-Path $OutDir "$Name.iso"
    $outZip = Join-Path $OutDir "$Name-depot.zip"
    Info "Exporting ISO"
    Export-EsxImageProfile -ImageProfile $Name -ExportToIso $outIso -Force
    Info "Exporting offline bundle"
    Export-EsxImageProfile -ImageProfile $Name -ExportToBundle $outZip -Force
    Ok ("ISO    : {0}  ({1} MB)" -f $outIso,[math]::Round((Get-Item $outIso).Length/1MB,1))
    Ok ("Bundle : {0}  ({1} MB)" -f $outZip,[math]::Round((Get-Item $outZip).Length/1MB,1))

    $prof.VibList | Sort-Object Name | Select-Object Name,Version,Vendor,AcceptanceLevel,CreationDate |
        Export-Csv (Join-Path $OutDir "$Name-viblist.csv") -NoTypeInformation
    $script:Report | Set-Content (Join-Path $OutDir "$Name-report.txt")

    # ---------- 8. validation ----------
    if (-not $SkipValidation) {
        Info "Validating exported bundle (re-load + checklist)"
        Clear-Depots
        Add-EsxSoftwareDepot $outZip | Out-Null
        $vp = Get-EsxImageProfile -Name $Name
        Ok ("Re-loaded profile OK: {0} VIBs, {1}" -f $vp.VibList.Count,$vp.AcceptanceLevel)
        $crit = 'smartpqi','nhpsa','bnxtnet','icen','igbn','qlnativefc','amsdv','ilo','sut','ssacli2'
        foreach ($c in $crit) {
            $v = $vp.VibList | Where-Object Name -eq $c | Select-Object -First 1
            if ($v) { Ok ("  present: {0,-12} {1}" -f $v.Name,$v.Version) } else { Warn ("  absent : {0}" -f $c) }
        }
    }

    Ok "BUILD COMPLETE"
    Write-Host ""
    Write-Host ("Deliverables in: {0}" -f $OutDir) -ForegroundColor Green
    Get-ChildItem $OutDir -Filter "$Name*" | Select-Object Name,Length | Format-Table -AutoSize
    if ($interactive) { Write-Host ""; [void](Read-Host "All done - press Enter to close") }
}
finally {
    # ---------- 9. cleanup ----------
    Clear-Depots
    if ($mounted) { try { Dismount-DiskImage -ImagePath $SppIso | Out-Null; Ok "SPP dismounted." } catch { Warn "Could not dismount SPP: $($_.Exception.Message)" } }
    try { Stop-Transcript | Out-Null } catch {}
}

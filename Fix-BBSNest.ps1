[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Restore,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

# --- known-good SHA-256 of the exact files this patch targets -----------------
$DLL_ORIG  = '3d546cadfe6c96bc6669fbb62e128ada9207d529657aeff966e08ce316344b77'
$DLL_PATCH = '5c6a7940eda224cace56ee0424e644cff98dcc8dcc9cd190c28076e7f2b1438d'
$FRG_ORIG  = 'd81b47ebd618169752458b417717c15fcb11a26b1435dd85d382337091fbb382'
$FRG_PATCH = 'e34eb572128af2d98ef3ef6801be0fb51d17761e721b80e4328a07fdcf722b68'

# --- SubSystem.dll byte edits (offset -> original bytes -> patched bytes) ------
# 4 code edits + the PE checksum field at 0x178, applied to the verified original.
$DLL_EDITS = @(
    @{ Off = 0x8AFC; Old = '7524';           New = '75D2' }            # simconnect: no 2nd connection
    @{ Off = 0x8AE4; Old = '0F8566010000';   New = '0F8556010000' }    # simconnect: watcher stays resident
    @{ Off = 0xA26D; Old = 'E91EE6FFFF';     New = 'C3CCCCCCCC' }      # simconnect: no duplicate watcher on sim quit
    @{ Off = 0xAE7F; Old = '4881C340420F00'; New = '4881C380F0FA02' }  # render loop: ~20 Hz cap
    @{ Off = 0x178;  Old = 'E9C50200';       New = '80B20200' }        # PE checksum
)

# --- shdrsb\terr.frag text edits (applied to the decrypted shader) ------------
$SHADER_KEY   = 'abcdefghijklmnopqrstuvwxyz'
$SHADER_EDITS = @(
    @{ Old = "#version 460 core`r`n";
       New = "#version 460 core`r`n// bbs-nest-fix v1`r`n"; N = 1 }
    @{ Old = 'layout(std430, binding = 0) buffer HeightBuffer';
       New = 'layout(std430, binding = 0) coherent buffer HeightBuffer'; N = 1 }
    @{ Old = 'atomicMax(maxHeight, int(height));';
       New = 'if (int(height) > maxHeight) atomicMax(maxHeight, int(height));'; N = 3 }
    @{ Old = 'atomicMin(minHeight, int(height));';
       New = 'if (int(height) < minHeight) atomicMin(minHeight, int(height));'; N = 1 }
    @{ Old = 'bt30 = 1;'; New = 'if (bt30 == 0) bt30 = 1;'; N = 1 }
    @{ Old = 'bt60 = 1;'; New = 'if (bt60 == 0) bt60 = 1;'; N = 1 }
)

# ---------------------------------------------------------------------------- #
function Sha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}
function HexToBytes([string]$Hex) {
    $o = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $o.Length; $i++) { $o[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    , $o
}
function XorBytes([byte[]]$Bytes, [string]$Key) {
    $k = [System.Text.Encoding]::ASCII.GetBytes($Key)
    for ($i = 0; $i -lt $Bytes.Length; $i++) { $Bytes[$i] = $Bytes[$i] -bxor $k[$i % $k.Length] }
}
function CountOcc([string]$S, [string]$Sub) { ([regex]::Matches($S, [regex]::Escape($Sub))).Count }

function Find-Folder([string]$Explicit) {
    $cands = @()
    if ($Explicit) { $cands += $Explicit }
    if ($PSScriptRoot) { $cands += $PSScriptRoot }
    $cands += (Get-Location).Path
    foreach ($c in $cands) {
        if ($c -and (Test-Path (Join-Path $c 'SubSystem.dll'))) { return (Resolve-Path $c).Path }
    }
    # fall back to MSFS UserCfg.opt -> InstalledPackagesPath\Community\BBS Nest
    $cfgs = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache\UserCfg.opt'),
        (Join-Path $env:APPDATA      'Microsoft Flight Simulator\UserCfg.opt'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt'),
        (Join-Path $env:APPDATA      'Microsoft Flight Simulator 2024\UserCfg.opt')
    )
    foreach ($cfg in $cfgs) {
        if (Test-Path $cfg) {
            $m = Select-String -Path $cfg -Pattern 'InstalledPackagesPath\s+"([^"]+)"' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m) {
                $p = Join-Path $m.Matches[0].Groups[1].Value 'Community\BBS Nest'
                if (Test-Path (Join-Path $p 'SubSystem.dll')) { return $p }
            }
        }
    }
    return $null
}

function Classify([string]$File, [string]$Orig, [string]$Patched) {
    if (-not (Test-Path $File)) { return 'missing' }
    $h = Sha256 ([System.IO.File]::ReadAllBytes($File))
    if ($h -eq $Orig)    { return 'original' }
    if ($h -eq $Patched) { return 'patched' }
    return 'unknown'
}

function Backup([string]$File) {
    $bak = "$File.orig"
    if (-not (Test-Path $bak)) { Copy-Item -LiteralPath $File -Destination $bak -Force }
}

function Apply-Dll([string]$File) {
    $b = [System.IO.File]::ReadAllBytes($File)
    foreach ($e in $DLL_EDITS) {
        $old = HexToBytes $e.Old
        for ($i = 0; $i -lt $old.Length; $i++) {
            if ($b[$e.Off + $i] -ne $old[$i]) { throw "unexpected byte at 0x$('{0:X}' -f ($e.Off + $i))" }
        }
        $new = HexToBytes $e.New
        [Array]::Copy($new, 0, $b, $e.Off, $new.Length)
    }
    if ((Sha256 $b) -ne $DLL_PATCH) { throw 'result hash mismatch - aborted, file not written' }
    Backup $File
    [System.IO.File]::WriteAllBytes($File, $b)
}

function Apply-Shader([string]$File) {
    $enc = [System.Text.Encoding]::GetEncoding(28591)   # Latin-1: byte<->char is 1:1 for 0-255
    $b = [System.IO.File]::ReadAllBytes($File)
    XorBytes $b $SHADER_KEY
    $txt = $enc.GetString($b)
    foreach ($e in $SHADER_EDITS) {
        if ((CountOcc $txt $e.Old) -ne $e.N) { throw "shader pattern count off for: $($e.Old)" }
        $txt = $txt.Replace($e.Old, $e.New)
    }
    $out = $enc.GetBytes($txt)
    XorBytes $out $SHADER_KEY
    if ((Sha256 $out) -ne $FRG_PATCH) { throw 'shader result hash mismatch - aborted, file not written' }
    Backup $File
    [System.IO.File]::WriteAllBytes($File, $out)
}

function Restore-One([string]$File) {
    $bak = "$File.orig"
    if (Test-Path $bak) { Copy-Item -LiteralPath $bak -Destination $File -Force; return $true }
    return $false
}

# ---------------------------------------------------------------------------- #
Write-Host "BBS Nest fix v1.0`n"

$dir = Find-Folder $Path
if (-not $dir) {
    Write-Host "Couldn't find the BBS Nest folder." -ForegroundColor Yellow
    Write-Host "Put this script in the BBS Nest folder, or run: .\Fix-BBSNest.ps1 `"path\to\BBS Nest`""
    return
}
$dll = Join-Path $dir 'SubSystem.dll'
$frg = Join-Path $dir 'shdrsb\terr.frag'
Write-Host "Folder: $dir`n"

if (Get-Process bbs_nest -ErrorAction SilentlyContinue) {
    Write-Host "BBS Nest is running. Close it (and the sim if the radar is active) and re-run." -ForegroundColor Yellow
    return
}

$dstate = Classify $dll $DLL_ORIG $DLL_PATCH
$sstate = Classify $frg $FRG_ORIG $FRG_PATCH
Write-Host ("  SubSystem.dll     : {0}" -f $dstate)
Write-Host ("  shdrsb\terr.frag  : {0}`n" -f $sstate)

if ($Check) { return }

if ($Restore) {
    $a = Restore-One $dll
    $b = Restore-One $frg
    if ($a) { Write-Host "  restored SubSystem.dll" } else { Write-Host "  SubSystem.dll: no backup" }
    if ($b) { Write-Host "  restored shdrsb\terr.frag" } else { Write-Host "  terr.frag: no backup" }
    return
}

if ($dstate -eq 'unknown') {
    Write-Host "SubSystem.dll doesn't match the version this fix targets (BBS Nest was probably" -ForegroundColor Yellow
    Write-Host "updated). Nothing changed." -ForegroundColor Yellow
    return
}

if ($dstate -eq 'original') { Apply-Dll $dll; Write-Host "  [ok] SubSystem.dll patched" }
else { Write-Host "  SubSystem.dll already patched" }

if ($sstate -eq 'original') { Apply-Shader $frg; Write-Host "  [ok] terr.frag patched" }
elseif ($sstate -eq 'patched') { Write-Host "  terr.frag already patched" }
else { Write-Host "  terr.frag $sstate - skipped (DLL fix still applies)" -ForegroundColor Yellow }

Write-Host "`nDone. Originals saved as *.orig next to the files."
Write-Host "Undo: .\Fix-BBSNest.ps1 -Restore    Re-run after any BBS Nest update."

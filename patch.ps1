#Requires -Version 5.1
<#
  PotPlayer 4K frame-doubling patcher.

  Removes the hardcoded 1920x1200 cap from PotPlayer's SVPflow .avs scripts
  and adds a dedicated 4K parameter branch. Works on top of an ALREADY
  installed PotPlayer - it does not ship or install any third-party binaries.

  Usage:
    patch.cmd              apply (elevates itself, UAC prompt)
    patch.cmd -Revert      restore the backups
    patch.cmd -Uninstall   same as -Revert

  ASCII-only on purpose (Windows PowerShell reads .ps1 as ANSI without BOM).
#>
param(
    [switch]$Revert,
    [switch]$Uninstall,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
if ($Uninstall) { $Revert = $true }

$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$backupDir = Join-Path $here 'backup'
$logFile   = Join-Path $here 'patch.log'
$profiles  = @('Fastest', 'Fast', 'Medium', 'High', 'Highest')
$marker    = '4K tier (added'
$oldCap    = 'zub < 2305000'
$newCap    = 'zub < 99999999'

function Write-Both([string]$t) {
    Write-Host $t
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t) -Encoding UTF8
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Requesting administrator rights (UAC prompt)...' -ForegroundColor Yellow
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Revert) { $a += '-Revert' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a
    return
}

# --- locate PotPlayer -----------------------------------------------------
$candidates = @()
foreach ($key in @(
    'HKLM:\SOFTWARE\DAUM\PotPlayer64',
    'HKLM:\SOFTWARE\WOW6432Node\DAUM\PotPlayer',
    'HKCU:\SOFTWARE\DAUM\PotPlayer64')) {
    $p = (Get-ItemProperty -Path $key -Name 'ProgramPath' -ErrorAction SilentlyContinue).ProgramPath
    if ($p) { $candidates += (Split-Path $p -Parent) }
}
$candidates += 'C:\Program Files\DAUM\PotPlayer'
$candidates += 'C:\Program Files (x86)\DAUM\PotPlayer'

$potDir = $candidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'PotPlayerMini64.exe')) } | Select-Object -First 1
if (-not $potDir) {
    Write-Both 'ERROR: PotPlayer not found. Install PotPlayer 64-bit first.'
    if (-not $NoPause) { Write-Host 'Press any key to exit.'; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    exit 1
}
Write-Both ("PotPlayer: " + $potDir)

# --- version check --------------------------------------------------------
# PotPlayerMini64.exe has no version resource, so take it from uninstall.exe
# (ProductVersion, e.g. 1.7.23159.0) and fall back to the registry build tag.
$testedMajor = '1.7'
$potVer = ''
$uninst = Join-Path $potDir 'uninstall.exe'
if (Test-Path $uninst) {
    $v = (Get-Item $uninst).VersionInfo.ProductVersion
    if ($v -and $v -notmatch '^0\.0') { $potVer = $v }
}
if (-not $potVer) {
    $r = (Get-ItemProperty 'HKCU:\SOFTWARE\DAUM\PotPlayer64' -Name 'ProgramVersion' -ErrorAction SilentlyContinue).ProgramVersion
    if ($r) { $potVer = $r }
}
Write-Both ("Version: " + $(if ($potVer) { $potVer } else { 'unknown (could not read)' }))

if ($potVer -and $potVer -notmatch ('^' + [regex]::Escape($testedMajor))) {
    Write-Both ("WARNING: patched and tested on PotPlayer {0}.xxxxx, this build is {1}." -f $testedMajor, $potVer)
    Write-Host ("WARNING: this build reports {0}; tested on {1}.xxxxx." -f $potVer, $testedMajor) -ForegroundColor Yellow
    Write-Host 'The .avs layout may have changed. The patch will skip any file it cannot recognise.' -ForegroundColor Yellow
    Write-Both 'Continuing - unrecognised files will be skipped, not modified.'
}

# --- prerequisites --------------------------------------------------------
$missingSvp = @()
foreach ($dll in 'svpflow1.dll', 'svpflow2.dll') {
    if (-not (Test-Path (Join-Path $potDir $dll))) { $missingSvp += $dll }
}
if ($missingSvp.Count -gt 0) {
    Write-Both ("WARNING: not found in PotPlayer folder: " + ($missingSvp -join ', '))
    Write-Both 'These DLLs come with the SVPflow / SVP package and are NOT shipped by this patcher.'
    Write-Both 'Install SVP (svp-team.com) so the DLLs end up next to PotPlayerMini64.exe, then run again.'
}

$found = @($profiles | Where-Object { Test-Path (Join-Path $potDir ($_ + '.avs')) })
if ($found.Count -eq 0) {
    Write-Both 'ERROR: no .avs profile scripts found in the PotPlayer folder.'
    Write-Both 'This patch only applies to installs that already have the frame-doubling mod.'
    if (-not $NoPause) { Write-Host 'Press any key to exit.'; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    exit 1
}
Write-Both ("Profiles found: " + ($found -join ', '))

# --- revert ---------------------------------------------------------------
if ($Revert) {
    if (-not (Test-Path $backupDir)) { Write-Both 'No backups found - nothing to restore.'; return }
    $restored = 0
    foreach ($n in $profiles) {
        $bak = Join-Path $backupDir ($n + '.avs')
        if (Test-Path $bak) {
            Copy-Item $bak (Join-Path $potDir ($n + '.avs')) -Force
            Write-Both ("restored " + $n + '.avs')
            $restored++
        }
    }
    if ($restored -eq 0) {
        Write-Both 'No backups found - nothing to restore.'
    } else {
        Write-Both ("Revert done: {0} file(s). Restart PotPlayer." -f $restored)
    }
    if (-not $NoPause) { Write-Host 'Press any key to exit.'; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    return
}

# --- apply ----------------------------------------------------------------
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }

# 4K parameters per quality profile (tuned for >= 2560x1440)
$P = @{
    'Fastest' = @{ sup='{pel:1,scale:{up:0},gpu:1,full:false}'; csup='{pel:1,scale:{up:2},gpu:0,full:false}'; ana='{block:{w:32,h:32,overlap:0},main:{search:{coarse:{type:2,distance:-6}}}}'; cana='{vectors:2,block:{w:32,h:32},main:{search:{coarse:{type:2,distance:-6}}}}'; sm='cubic:0,linear:false,algo:13,scene:{mode:2}'; csm='cubic:0,linear:false,algo:1,scene:{mode:2}' }
    'Fast'    = @{ sup='{pel:1,scale:{up:0},gpu:1,full:false}'; csup='{pel:1,scale:{up:2},gpu:0,full:false}'; ana='{block:{w:32,h:32,overlap:0},main:{search:{coarse:{distance:-10}}}}'; cana='{vectors:2,block:{w:32,h:32},main:{search:{coarse:{type:2,distance:-6},distance:0}}}'; sm='algo:13,scene:{}'; csm='algo:11,scene:{mode:1}' }
    'Medium'  = @{ sup='{pel:1,scale:{up:0},gpu:1,full:false}'; csup='{pel:1,scale:{up:2},gpu:0,full:false}'; ana='{block:{w:32,h:32,overlap:1},main:{search:{coarse:{distance:-10,bad:{sad:2000,range:24}}}}}'; cana='{vectors:2,block:{w:32,h:32,overlap:1},main:{search:{coarse:{distance:-10,bad:{sad:2000,range:24}}}}}'; sm='algo:13,scene:{}'; csm='algo:11,scene:{mode:1}' }
    'High'    = @{ sup='{pel:1,scale:{up:0},gpu:1,full:false}'; csup='{pel:1,scale:{up:2},gpu:0,full:false}'; ana='{block:{w:32,h:32,overlap:1},main:{search:{coarse:{distance:-10,bad:{sad:2000}}}}}'; cana='{block:{w:32,h:32,overlap:1},main:{search:{coarse:{distance:-10,bad:{sad:2000,range:24}}}}}'; sm='algo:13,scene:{}'; csm='algo:13,scene:{mode:1}' }
    'Highest' = @{ sup='{pel:1,scale:{up:0},gpu:1,full:false}'; csup='{pel:1,scale:{up:2},gpu:0,full:false}'; ana='{block:{w:32,h:32,overlap:1},main:{search:{coarse:{distance:-10,bad:{sad:2000}}}},refine:[{thsad:65000}]}'; cana='{block:{w:32,h:32,overlap:1},main:{search:{coarse:{distance:-10,bad:{sad:2000}}}}}'; sm='cubic:0,linear:false,algo:13,scene:{}'; csm='cubic:0,linear:false,algo:13,scene:{}' }
}

function Build-Block($p) {
@"
# --- 4K tier (added; original script refused anything above 1920x1200) ---
zub > 2304000 ? eval("""
`tglobal super_params = (gpu>=1) ? "$($p.sup)" : "$($p.csup)"
`tglobal analyse_params = (gpu>=1) ? "$($p.ana)" : "$($p.cana)"
`tglobal smoothfps_params = (gpu>=1) ? "{"""+gpuid+""",rate:{"""+rate+"""},$($p.sm)}" : "{rate:{"""+rate+"""},$($p.csm)}"
""") : eval(""" """)
 
"@
}

$patched = 0
foreach ($n in $profiles) {
    $src = Join-Path $potDir ($n + '.avs')
    if (-not (Test-Path $src)) { continue }

    $text = [System.IO.File]::ReadAllText($src)
    if ($text.Contains($marker)) { Write-Both ("SKIP " + $n + '.avs (already patched)'); continue }

    Copy-Item $src (Join-Path $backupDir ($n + '.avs')) -Force

    if ($text.Contains($oldCap)) { $text = $text.Replace($oldCap, $newCap) }
    else { Write-Both ("WARN " + $n + '.avs: resolution cap not found - check the file version') }

    $anchor = 'function interpolate(clip src)'
    if ($text.Contains($anchor)) {
        $text = $text.Replace($anchor, ((Build-Block $P[$n]) + $anchor))
    } else {
        Write-Both ("ERROR " + $n + '.avs: anchor "function interpolate" not found, skipped')
        continue
    }

    [System.IO.File]::WriteAllText($src, $text, [System.Text.Encoding]::ASCII)
    Write-Both ("PATCHED " + $n + '.avs')
    $patched++
}

Write-Both ''
Write-Both ("Done. Patched {0} file(s). Backups: {1}" -f $patched, $backupDir)
Write-Both 'Restart PotPlayer and test a 4K clip. Rollback: patch.cmd -Revert'
if (-not $NoPause) { Write-Host 'Press any key to exit.'; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }

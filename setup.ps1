#Requires -RunAsAdministrator
<#
  firefox-win-dev / setup.ps1

  Idempotent. Run it on first logon (Autounattend does), or any time later to
  converge the machine. Every step checks before it acts.

    1. winget up to date
    2. Dev Drive at D:  (RAW partition or RAW disk -> ReFS Dev Drive)
    3. winget configure -f fx-dev.winget
    4. MozillaBuild
    5. Environment (MOZBUILD_STATE_PATH, SCCACHE_DIR) + Defender exclusions
    6. git config for a large tree on Windows
    7. clone firefox + mach bootstrap (unless -SkipTree)

  Usage:  .\setup.ps1 [-DevDriveLetter D] [-SrcRoot D:\src] [-SkipTree]
#>
[CmdletBinding()]
param(
    [string]$DevDriveLetter = 'D',
    [string]$SrcRoot        = "$($DevDriveLetter):\src",
    [string]$FirefoxRemote  = 'https://github.com/mozilla-firefox/firefox',
    [string]$Mozconfig      = 'mozconfig.debug',   # in .\mozconfigs
    [switch]$SkipTree
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
# Terminating errors otherwise surface as "setup.ps1: line 1"; say where they really happened.
trap {
    Write-Host ("`nFAILED at setup.ps1:{0}  {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()) -ForegroundColor Red
    break
}
try { Start-Transcript -Path (Join-Path $Here 'setup.log') -Append | Out-Null } catch {}   # everything below also lands in C:\fxsetup\setup.log
function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. winget
Step 'winget: ensure available and >= 1.11 (dscv3 processor)'
function Get-WinGetVersion {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $null }
    $raw = (& winget --version 2>$null | Select-Object -First 1) -replace '^v', ''
    try { [version](($raw -split '[-+]')[0]) } catch { $null }
}
$minWinGet = [version]'1.11.0'
$wg = Get-WinGetVersion
if (-not $wg -or $wg -lt $minWinGet) {
    # Only touch App Installer when we must. -Latest chases GitHub's newest release and its
    # post-check fails if the update doesn't land (common right after first logon); the
    # module's pinned version is the reliable fallback.
    if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
        Install-PackageProvider -Name NuGet -Force | Out-Null
        Install-Module Microsoft.WinGet.Client -Force -Scope AllUsers
    }
    Import-Module Microsoft.WinGet.Client
    try { Repair-WinGetPackageManager -AllUsers -Latest }
    catch {
        Write-Warning "Repair-WinGetPackageManager -Latest failed ($($_.Exception.Message.Trim())); trying the module's pinned version"
        try { Repair-WinGetPackageManager -AllUsers } catch { Write-Warning "Repair-WinGetPackageManager failed: $($_.Exception.Message.Trim())" }
    }
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    $wg = Get-WinGetVersion
}
if (-not $wg) { throw 'winget is not available. Open Microsoft Store > Library and update "App Installer", then re-run C:\fxsetup\setup.ps1' }
if ($wg -lt $minWinGet) { throw "winget $wg is older than $minWinGet; update App Installer from the Microsoft Store, then re-run" }
Write-Host "  winget $wg"

# ------------------------------------------------------------- 2. Dev Drive
Step "Dev Drive: ensure ${DevDriveLetter}: is a Dev Drive"
$vol = Get-Volume -DriveLetter $DevDriveLetter -ErrorAction SilentlyContinue
if ($vol -and $vol.FileSystemType -eq 'ReFS') {
    Write-Host "  ${DevDriveLetter}: already ReFS, assuming Dev Drive."
} else {
    # Candidate A: a partition with no filesystem (Autounattend leaves #4 RAW).
    $part = Get-Partition | Where-Object { $_.Size -ge 50GB -and -not $_.IsSystem } |
        Where-Object { $v = $_ | Get-Volume -ErrorAction SilentlyContinue; -not $v -or -not $v.FileSystem } |
        Select-Object -First 1
    # Candidate B: a RAW second disk (VM with two virtual disks).
    if (-not $part) {
        $disk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Size -ge 50GB } | Select-Object -First 1
        if ($disk) {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT
            $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize
        }
    }
    if (-not $part) { throw "No RAW partition/disk >= 50 GB to turn into a Dev Drive. Free one up or pass -SkipTree and place the tree elsewhere." }
    # In a VM the install DVD usually grabs the first free letter (D:). Evict optical drives to a
    # high letter so the Dev Drive gets the letter everything else (mozconfigs, docs) assumes.
    $occupant = Get-Volume -DriveLetter $DevDriveLetter -ErrorAction SilentlyContinue
    if ($occupant -and $occupant.DriveType -eq 'CD-ROM') {
        $free = (90..69 | ForEach-Object { [string][char]$_ }) |
            Where-Object { -not (Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue) -and -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } |
            Select-Object -First 1
        $cd = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($DevDriveLetter):'"
        Set-CimInstance -InputObject $cd -Property @{ DriveLetter = "${free}:" }
        Write-Host "  moved optical drive ${DevDriveLetter}: -> ${free}:"
    } elseif ($occupant) {
        throw "${DevDriveLetter}: is taken by a $($occupant.DriveType) volume ($($occupant.FileSystemLabel)); pass -DevDriveLetter <other> or free it"
    }
    # Explicit identifiers: piping a CIM partition object into Set-Partition binds several
    # parameter sets at once ("Parameter set cannot be resolved").
    if ($part.DriveLetter -ne $DevDriveLetter) {
        Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter $DevDriveLetter
    }
    # Dev Drive = ReFS + Defender performance mode + trusted. Needs Win11 22H2+. Two documented
    # ways; format.com is the fallback if this Storage module build lacks/rejects -DevDrive.
    try {
        Format-Volume -DriveLetter $DevDriveLetter -DevDrive -FileSystemLabel 'Dev' -Confirm:$false -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Format-Volume -DevDrive failed ($($_.Exception.Message.Trim())); using format.com /DevDrv"
        & "$env:SystemRoot\System32\format.com" "${DevDriveLetter}:" /DevDrv /Q /Y /V:Dev | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "format.com /DevDrv failed ($LASTEXITCODE)" }
    }
    $chk = Get-Volume -DriveLetter $DevDriveLetter
    if ($chk.FileSystemType -ne 'ReFS') { throw "${DevDriveLetter}: is $($chk.FileSystemType), expected ReFS (Dev Drive)" }
    Write-Host "  Formatted ${DevDriveLetter}: as Dev Drive."
}
New-Item -ItemType Directory -Force -Path $SrcRoot, "$($DevDriveLetter):\.mozbuild", "$($DevDriveLetter):\sccache" | Out-Null

# --------------------------------------------------------- 3. winget configure
Step 'winget configure: converge machine state'
winget configure -f (Join-Path $Here 'fx-dev.winget') --accept-configuration-agreements --disable-interactivity
if ($LASTEXITCODE -ne 0) { throw "winget configure failed ($LASTEXITCODE)" }
# Refresh PATH so git/python from this session are visible below.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

# ------------------------------------------------------------ 4. MozillaBuild
Step 'MozillaBuild: ensure C:\mozilla-build'
if (-not (Test-Path 'C:\mozilla-build\start-shell.bat')) {
    $exe = "$env:TEMP\MozillaBuildSetup-Latest.exe"
    Invoke-WebRequest -UseBasicParsing 'https://ftp.mozilla.org/pub/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe' -OutFile $exe
    # NSIS installer -> /S is silent. Verify against the current release once.
    Start-Process $exe -ArgumentList '/S' -Wait
}
$mbBin = 'C:\mozilla-build\bin'
$machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
if ($machinePath -notlike "*$mbBin*") {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$mbBin", 'Machine')
    $env:Path += ";$mbBin"
}

# ------------------------------------------------- 5. environment + Defender
Step 'Environment: mach state + sccache on the Dev Drive'
[Environment]::SetEnvironmentVariable('MOZBUILD_STATE_PATH', "$($DevDriveLetter):\.mozbuild", 'Machine')
[Environment]::SetEnvironmentVariable('SCCACHE_DIR',         "$($DevDriveLetter):\sccache",  'Machine')
$env:MOZBUILD_STATE_PATH = "$($DevDriveLetter):\.mozbuild"
$env:SCCACHE_DIR         = "$($DevDriveLetter):\sccache"

# Dev Drive already runs Defender in performance mode; these cover the C: bits.
foreach ($p in 'C:\mozilla-build', "$env:LOCALAPPDATA\Temp") {
    Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
}
# Bare metal: don't let the power plan throttle a 40-minute build.
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null   # High performance (no-op if absent)

# ------------------------------------------------------------ 6. git config
Step 'git: settings for a very large tree on Windows'
git config --global core.longpaths true
git config --global core.fscache true
git config --global core.preloadindex true
git config --global core.untrackedCache true
git config --global core.autocrlf false
git config --global fetch.writeCommitGraph true
git config --global feature.manyFiles true
git config --global maintenance.auto false   # let `git maintenance start` own it per repo

# ------------------------------------------------- 7. tree + mach bootstrap
if ($SkipTree) { Write-Host "`n-SkipTree given; done."; exit 0 }

$fx = Join-Path $SrcRoot 'firefox'
Step "firefox: ensure clone at $fx"
if (-not (Test-Path (Join-Path $fx 'mach'))) {
    git clone $FirefoxRemote $fx
    git -C $fx maintenance start
}
Copy-Item (Join-Path $Here "mozconfigs\$Mozconfig") (Join-Path $fx 'mozconfig') -Force

Step 'mach bootstrap (non-interactive; downloads pinned toolchains incl. MSVC/SDK bundle)'
Push-Location $fx
try {
    # mach from PowerShell needs C:\mozilla-build\bin on PATH (done above) and
    # a native python on PATH (winget). Documented as experimental; the
    # fallback is running the same command from start-shell.bat.
    .\mach.ps1 --no-interactive bootstrap --application-choice='Firefox for Desktop'
    if ($LASTEXITCODE -ne 0) { throw "mach bootstrap failed ($LASTEXITCODE)" }
} finally { Pop-Location }

Write-Host "`nDone. Reboot once (long paths / Dev Mode), then:  cd $fx ; .\mach.ps1 build" -ForegroundColor Green

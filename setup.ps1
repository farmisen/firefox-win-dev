#Requires -RunAsAdministrator
<#
  firefox-win-dev / setup.ps1

  Idempotent. Run it on first logon (Autounattend does), or any time later to
  converge the machine. Every step checks before it acts.

    0. drivers under .\drivers (pnputil), then wait until DNS answers
    1. winget up to date
    2. Dev Drive at D:  (RAW partition or RAW disk -> ReFS Dev Drive)
    3. winget configure -f fx-dev.winget  (then quiet Store/OS auto-updates)
    4. MozillaBuild
    5. Environment (MOZBUILD_STATE_PATH, SCCACHE_DIR) + Defender exclusions
    6. git config for a large tree on Windows
    7. clone the requested tree(s) + mach bootstrap (unless -SkipTree). These run as the
       logged-on user, NOT elevated: extracting toolchains elevated leaves them owned by
       Administrators and unreadable to the developer's own shell (see Invoke-Unelevated).
       A leftover-permissions check follows as a safety net
    8. guest tools (VMware) - always last: the driver swap blacks out the console until a
       restart, so nothing that needs the session may run after it

  Usage:  .\setup.ps1 [-Products firefox,enterprise-firefox] [-DevDriveLetter D] [-SrcRoot D:\src] [-SkipTree] [-AllowWindowsUpdate]

  Products (comma-separated; each gets its own clone under SrcRoot and its own mozconfig):
    firefox             https://github.com/mozilla-firefox/firefox
    enterprise-firefox  https://github.com/mozilla/enterprise-firefox (branch enterprise-main),
                        mozconfig additionally sources build/win64/mozconfig.enterprise
#>
[CmdletBinding()]
param(
    [string]$DevDriveLetter = 'D',
    [string]$SrcRoot        = "$($DevDriveLetter):\src",
    [string[]]$Products     = @('firefox'),        # "a,b" from -File is one string; split below
    [string]$Mozconfig      = 'mozconfig.debug',   # in .\mozconfigs
    [switch]$SkipTree,
    [switch]$AllowWindowsUpdate
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
# $ErrorActionPreference='Stop' (set above, and right for cmdlets) makes Windows PowerShell 5.1
# promote a *native* command's stderr into a terminating NativeCommandError as soon as its streams
# are redirected - and "2>$null" counts as redirecting. Native tools use stderr for warnings and
# progress perfectly legitimately (powercfg on an absent power plan, Set-ExecutionPolicy noting a
# more specific scope), so run those with the preference relaxed and judge them by exit code.
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Command)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command } finally { $ErrorActionPreference = $old }
}

# --------------------------------------------------------------- 0. network
Step 'drivers: install anything staged under .\drivers'
# Windows 11 ARM has no inbox driver for VMware's virtual NICs; bootstrap.sh stages Fusion's
# ARM64 vmxnet3 driver under .\drivers. Offer whatever is there to PnP. A driver that matches
# no device just lands in the driver store (Parallels/QEMU NICs work with inbox drivers).
$drivers = Join-Path $Here 'drivers'
if (Test-Path $drivers) {
    Get-ChildItem $drivers -Recurse -Filter *.inf | ForEach-Object {
        Write-Host "  pnputil /add-driver $($_.FullName) /install"
        pnputil /add-driver $_.FullName /install | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "    $_" }
    }
}

# ------------------------------------------------------------ 0b. network
Step 'network: wait for DNS'
# First logon fires before the network stack has finished identifying the connection, and the
# Store (used by winget configure --enable) then fails with 0x80072ee7 "name not resolved".
# Nothing below is worth attempting until DNS answers.
function Test-Dns { [bool](Resolve-DnsName www.microsoft.com -DnsOnly -ErrorAction SilentlyContinue) }
$deadline = (Get-Date).AddMinutes(5)
while (-not (Test-Dns) -and (Get-Date) -lt $deadline) { Write-Host '  waiting for DNS...'; Start-Sleep -Seconds 5 }
if (Test-Dns) {
    Write-Host "  DNS ok via $((Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).InterfaceDescription)"
} else {
    Write-Host '  network adapters:'
    Get-NetAdapter | Format-Table Name, InterfaceDescription, Status | Out-Host
    Write-Host '  PnP network-class devices not OK (a missing driver shows up here):'
    Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object Status -ne 'OK' | Format-Table FriendlyName, Status, InstanceId | Out-Host
    throw 'no DNS after 5 minutes: the VM has no working NIC (driver missing?) or the hypervisor network is down. Fix that, then re-run C:\fxsetup\setup.ps1'
}

# ---------------------------------------------------------------- 1. winget
Step 'winget: ensure available and >= 1.11 (dscv3 processor)'
function Find-WinGet {
    # Prefer the exe inside the App Installer package: it works before the per-user
    # execution alias exists and regardless of what PATH the elevated session inherited.
    $pkg = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if ($pkg) { $exe = Join-Path $pkg.InstallLocation 'winget.exe'; if (Test-Path $exe) { return $exe } }
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}
function Invoke-WinGet {
    # The Store can auto-update App Installer mid-run: the package directory moves and winget.exe
    # is briefly gone or unlaunchable ("Program 'winget.exe' failed to run: Access is denied").
    # Enabling the configuration feature is itself what triggers that update, so the very next
    # call often lands in the window. Resolve the path every call and retry through it. A normal
    # non-zero EXIT does not throw, so it still passes back to the caller's $LASTEXITCODE check;
    # only a failure to launch (throw) or a missing exe is retried.
    for ($try = 1; $try -le 6; $try++) {
        $exe = Find-WinGet
        if ($exe) {
            try { & $exe @args; return }
            catch {
                if ($try -ge 6) { throw }
                Write-Warning ("winget.exe could not launch ({0}); App Installer may be updating, retry {1}/6 in 20s" -f $_.Exception.Message.Trim(), $try)
            }
        } else {
            if ($try -ge 6) { throw 'winget.exe vanished (App Installer update in progress?). Wait a minute and re-run C:\fxsetup\setup.ps1' }
            Write-Warning "winget.exe not found (App Installer update in progress?); retry $try/6 in 20s"
        }
        Start-Sleep -Seconds 20
    }
}
function Get-WinGetVersion($exe) {
    $raw = (Invoke-Native { & $exe --version } 2>$null | Select-Object -First 1) -replace '^v', ''
    try { [version](($raw -split '[-+]')[0]) } catch { $null }
}
$minWinGet = [version]'1.11.0'
$WinGet = Find-WinGet
if (-not $WinGet) {
    # Right after first logon the inbox package is staged but not yet registered for this
    # user. Register it ourselves (no network) and give the deployment a few minutes.
    Write-Host '  winget not registered for this user yet; registering the inbox App Installer package'
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { Write-Warning "Add-AppxPackage: $($_.Exception.Message.Trim())" }
    $deadline = (Get-Date).AddMinutes(4); $t0 = Get-Date
    while (-not ($WinGet = Find-WinGet) -and (Get-Date) -lt $deadline) {
        Write-Host ("`r  waiting for App Installer registration ... {0:mm\:ss}" -f ((Get-Date) - $t0)) -NoNewline
        Start-Sleep -Seconds 5
    }
    Write-Host ''
}
$wg = if ($WinGet) { Get-WinGetVersion $WinGet }
if (-not $wg -or $wg -lt $minWinGet) {
    # Last resort, needs the network (GitHub): the module's Repair pulls the msixbundle.
    Write-Warning "winget missing or older than $minWinGet (found: $wg); trying Repair-WinGetPackageManager"
    if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
        Install-PackageProvider -Name NuGet -Force | Out-Null
        Install-Module Microsoft.WinGet.Client -Force -Scope AllUsers
    }
    Import-Module Microsoft.WinGet.Client
    try { Repair-WinGetPackageManager -AllUsers } catch { Write-Warning "Repair-WinGetPackageManager failed: $($_.Exception.Message.Trim())" }
    $WinGet = Find-WinGet
    $wg = if ($WinGet) { Get-WinGetVersion $WinGet }
}
if (-not $WinGet) { throw 'winget is not available. Open Microsoft Store > Library and update "App Installer", then re-run C:\fxsetup\setup.ps1' }
if ($wg -lt $minWinGet) { throw "winget $wg is older than $minWinGet; update App Installer from the Microsoft Store, then re-run" }
Write-Host "  winget $wg  ($WinGet)"

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
    if ($part.DriveLetter -eq $DevDriveLetter) {
        # a previous run already assigned the letter to our RAW partition; nothing to evict
    } elseif ($occupant -and $occupant.DriveType -eq 'CD-ROM') {
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
    # ways: format.com /DevDrv first (deterministic); Format-Volume -DevDrive as fallback, since
    # on 25H2 the cmdlet's -DevDrive switch trips "Parameter set cannot be resolved".
    & "$env:SystemRoot\System32\format.com" "${DevDriveLetter}:" /DevDrv /Q /Y /V:Dev | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "format.com /DevDrv exited $LASTEXITCODE; trying Format-Volume -DevDrive"
        Format-Volume -DriveLetter $DevDriveLetter -DevDrive -Confirm:$false -ErrorAction Stop | Out-Null
    }
    $chk = Get-Volume -DriveLetter $DevDriveLetter
    if ($chk.FileSystemType -ne 'ReFS') { throw "${DevDriveLetter}: is $($chk.FileSystemType), expected ReFS (Dev Drive)" }
    Write-Host "  Formatted ${DevDriveLetter}: as Dev Drive."
}
# This script runs elevated, but the developer's shell will not be. Give the user full control
# of the volume with inheritance so mach can later delete/replace toolchains under .mozbuild.
# The inheritable ACE on the root is what matters; /T only exists to fix content that predates
# it. On a re-run the drive holds a Firefox checkout (~500k files) and that walk takes minutes
# for nothing, so check the root first and recurse only when the ACE is actually missing.
$devUser = $env:USERNAME
$rootAce = "${devUser}:(OI)(CI)(F)"
$rootAcl = Invoke-Native { icacls "$($DevDriveLetter):\" } 2>&1 | Out-String
if ($rootAcl -like "*$rootAce*") {
    Write-Host "  ${DevDriveLetter}: $devUser already has inheritable full control"
} else {
    Write-Host "  ${DevDriveLetter}: granting full control to $devUser (recursive, slow if the drive has content)"
    Invoke-Native { icacls "$($DevDriveLetter):\" /grant "${devUser}:(OI)(CI)F" /T /C /Q } 2>&1 | Out-Null
}
New-Item -ItemType Directory -Force -Path $SrcRoot, "$($DevDriveLetter):\.mozbuild", "$($DevDriveLetter):\sccache" | Out-Null

# --------------------------------------------------------- 3. winget configure
Step 'winget configure: converge machine state'
# Fresh machines gate the configuration feature behind a one-time admin acknowledgement,
# which also pulls the configuration components from the Store. Store access is flaky in
# the first minutes after logon (and App Installer may be updating itself), so retry.
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Invoke-WinGet configure --enable
    if ($LASTEXITCODE -eq 0) { break }
    Write-Warning "winget configure --enable exited $LASTEXITCODE (attempt $attempt/3); retrying in 20s"
    Start-Sleep -Seconds 20
}
# Applying is declarative and idempotent: a unit already in the desired state is a no-op, so a
# retry only re-attempts what did not take. Individual package units fail transiently often
# enough (a flaky download, a Store hiccup, "Fast Cache data not found" out of the winget
# resource) that one bad unit should not sink a 40-minute provision. Converge, then insist.
$cfg = Join-Path $Here 'fx-dev.winget'
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Invoke-WinGet configure -f $cfg --accept-configuration-agreements --disable-interactivity
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq 3) { throw "winget configure still failing after $attempt attempts ($LASTEXITCODE); see the unit marked [FAIL] above" }
    Write-Warning "winget configure exited $LASTEXITCODE (attempt $attempt/3); re-applying only what did not take, in 30s"
    Start-Sleep -Seconds 30
}
# Refresh PATH so git/python from this session are visible below.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

# --------------------------------------------------- 3b. quiet auto-updates
Step 'auto-update policy: lock down after winget has what it needs'
# Set AFTER winget configure, not in the answer file: disabling Store auto-download before first
# logon also blocks winget configure --enable from fetching its configuration components from the
# Store (fails 0x80004004 "Operation aborted"). By now those components are in, so lock it down:
# no silent App Installer/winget swap and no toolchain drift on a box meant to be reproducible.
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name AutoDownload -PropertyType DWord -Value 2 -Force | Out-Null
Write-Host '  Store auto-update disabled'
if ($AllowWindowsUpdate) {
    Write-Host '  OS Windows Update left on (-AllowWindowsUpdate)'
} else {
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Host '  OS Windows Update auto-install disabled'
}

# ------------------------------------------------------------ 4. MozillaBuild
Step 'MozillaBuild: ensure C:\mozilla-build'
if (-not (Test-Path 'C:\mozilla-build\start-shell.bat')) {
    $exe = "$env:TEMP\MozillaBuildSetup-Latest.exe"
    $url = 'https://ftp.mozilla.org/pub/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe'
    Write-Host "  downloading $url"
    # curl.exe ships with Windows: progress bar, and -C - resumes a partial file from an interrupted run.
    & "$env:SystemRoot\System32\curl.exe" -fL --progress-bar -C - -o $exe $url
    if ($LASTEXITCODE -ne 0) { throw "MozillaBuild download failed (curl exit $LASTEXITCODE)" }
    Write-Host ("  downloaded {0:N0} MB" -f ((Get-Item $exe).Length / 1MB))
    # NSIS installer: /S is silent by design, so show a heartbeat instead. Typically 1-3 minutes.
    $proc = Start-Process $exe -ArgumentList '/S' -PassThru
    $t0 = Get-Date
    while (-not $proc.HasExited) {
        Write-Host ("`r  installing MozillaBuild (silent) ... {0:mm\:ss}" -f ((Get-Date) - $t0)) -NoNewline
        Start-Sleep -Seconds 2
    }
    Write-Host ""
    if ($proc.ExitCode -ne 0) { throw "MozillaBuild installer exited $($proc.ExitCode)" }
    Remove-Item $exe -ErrorAction SilentlyContinue
}
Write-Host "  C:\mozilla-build present"
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

# Windows client editions ship with ExecutionPolicy=Restricted, which blocks mach.ps1 (and every
# other local .ps1). RemoteSigned = local scripts run, downloaded ones must be signed. Windows
# PowerShell and PowerShell 7 keep separate policies, so set both.
foreach ($shell in 'powershell.exe', 'pwsh.exe') {
    if (Get-Command $shell -ErrorAction SilentlyContinue) {
        # We are launched with -ExecutionPolicy Bypass (the first-logon command does that), which
        # sets the *Process* scope. Setting LocalMachine still succeeds, but the child then prints
        # "... overridden by a policy defined at a more specific scope" to stderr, which is why
        # this needs Invoke-Native. The machine policy is set regardless; see the echo below.
        Invoke-Native { & $shell -NoProfile -Command 'Set-ExecutionPolicy -Scope LocalMachine RemoteSigned -Force' } 2>&1 | Out-Null
    }
}
$effective = (Get-ExecutionPolicy -Scope LocalMachine)
Write-Host "  execution policy (LocalMachine): $effective"

# Dev Drive already runs Defender in performance mode; these cover the C: bits.
foreach ($p in 'C:\mozilla-build', "$env:LOCALAPPDATA\Temp") {
    Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
}
# Bare metal: don't let the power plan throttle a 40-minute build.
Invoke-Native { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c } 2>&1 | Out-Null  # High performance (absent on many Win11 images)
# Never blank the console or suspend: unattended provisioning and long builds generate no input,
# and the stock 5-minute display timeout makes a working VM look like a hung one (black window).
foreach ($s in 'monitor-timeout-ac', 'monitor-timeout-dc', 'standby-timeout-ac', 'standby-timeout-dc') {
    Invoke-Native { powercfg /change $s 0 } 2>&1 | Out-Null
}
Write-Host '  display blanking and sleep disabled'

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

# Guest tools go in LAST, once nothing else needs the interactive session. The installer swaps
# the display and input drivers and cannot finish binding them until a restart: run it earlier and
# the console goes black with dead input for the remainder, which wedges anything using that
# session (winget configure hangs) and makes a working VM look hung. Nothing else needs Tools -
# the guest NIC comes from the vmxnet3 driver injected in step 0. Called at the end of whichever
# path we take, so the long clone/bootstrap stays watchable.
function Install-GuestTools {
    Step 'guest tools: VMware Tools when this is a VMware guest without it'
    $maker = (Get-CimInstance Win32_ComputerSystem).Manufacturer
    if ($maker -match 'VMware') {
        if (Get-Service VMTools -ErrorAction SilentlyContinue) {
            Write-Host '  VMware Tools already installed'
        } else {
            $toolsSetup = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } |
                ForEach-Object { Join-Path "$($_.DriveLetter):\" 'setup.exe' } |
                Where-Object { (Test-Path $_) -and ((Get-Item $_).VersionInfo.CompanyName -match 'VMware|Broadcom') } |
                Select-Object -First 1
            if ($toolsSetup) {
                Write-Host "  installing VMware Tools from $toolsSetup (silent, reboot deferred)..."
                $p = Start-Process $toolsSetup -ArgumentList '/S /v"/qn REBOOT=R"' -Wait -PassThru
                if ($p.ExitCode -in 0, 3010) { Write-Host "  VMware Tools installed (exit $($p.ExitCode)); the console stays black until you restart" }
                else { Write-Warning "VMware Tools setup exited $($p.ExitCode); continuing without Tools" }
            } else {
                Write-Host '  no VMware Tools CD attached; skipping (vm.sh attaches it when Fusion/Workstation ships it)'
            }
        }
    } elseif ($maker -match 'Parallels') {
        Write-Host '  Parallels guest: install Parallels Tools from the host with  prlctl installtools <vm>'
    } else {
        Write-Host "  not a VMware guest ($maker); nothing to do"
    }
}

# ------------------------------------------------- 7. tree(s) + mach bootstrap
# The clone and mach bootstrap must NOT run elevated, even though this script does.
#
# Python 3.12 on Windows honours the POSIX mode passed to os.mkdir by synthesising a security
# descriptor, and tarfile.makedir() creates every extracted directory with mode 0o700, intending
# to relax it later via chmod. 0o700 means owner-only, so the descriptor comes out *protected*
# (SYSTEM + Administrators + OWNER RIGHTS, inheritance discarded) and the later chmod cannot undo
# it: on Windows os.chmod only flips the read-only attribute. Access then hinges entirely on
# OWNER RIGHTS, i.e. on who owns the directory. Extract while elevated and the owner is
# BUILTIN\Administrators, which a normal shell holds deny-only under UAC - so the developer
# cannot even list the toolchains mach just installed for them, and the next build dies with
# "PermissionError: [WinError 5] Access is denied". Run these as the logged-on user and the
# owner is that user, OWNER RIGHTS grants them, and the protected DACL stops mattering.
# (This is why ordinary Firefox devs, who never bootstrap elevated, do not hit it.)
function Invoke-Unelevated {
    param(
        [Parameter(Mandatory)][string]$WorkingDir,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Label
    )
    $task    = 'fxdev-unelevated'
    $cmdFile = Join-Path $Here 'unelevated.cmd'
    $started = Join-Path $Here 'unelevated.started'
    $marker  = Join-Path $Here 'unelevated.rc'
    Remove-Item $started, $marker -Force -ErrorAction SilentlyContinue
    # The script reports two things back through the filesystem rather than through schtasks
    # status, whose wording is localised and which lags behind the process: "I started" and
    # "I finished with this exit code".
    @(
        '@echo off'
        "echo 1> ""$started"""
        "cd /d ""$WorkingDir"""
        $Command
        "echo %ERRORLEVEL%> ""$marker"""
    ) | Set-Content -Path $cmdFile -Encoding ASCII
    # /IT with /RU and no /RP runs in the logged-on user's interactive session on an interactive
    # token, so no password is needed; omitting /RL HIGHEST leaves it on the filtered, that is
    # non-elevated, token.
    Invoke-Native { schtasks /create /tn $task /tr $cmdFile /sc once /st 00:00 /ru $env:USERNAME /it /f } 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    Invoke-Native { schtasks /run /tn $task } 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Invoke-Native { schtasks /delete /tn $task /f } 2>&1 | Out-Null; return $null }

    # $null means "nothing ran, it is safe to fall back". Only valid before the command starts:
    # returning it afterwards is how an earlier version got a second git clone racing the first.
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path $started) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (-not (Test-Path $started)) {
        Invoke-Native { schtasks /delete /tn $task /f } 2>&1 | Out-Null
        return $null
    }

    Write-Host "  running as $env:USERNAME (not elevated): $Label"
    # It is running, so from here we never return $null - we wait for its exit code however long
    # it takes. The cap only exists so a killed task cannot hang provisioning forever.
    $hardStop = (Get-Date).AddHours(4)
    while (-not (Test-Path $marker) -and (Get-Date) -lt $hardStop) { Start-Sleep -Seconds 15 }
    Invoke-Native { schtasks /delete /tn $task /f } 2>&1 | Out-Null
    if (-not (Test-Path $marker)) { Write-Warning "$Label did not report an exit code within 4h"; return 1 }
    try { return [int]((Get-Content $marker -Raw).Trim()) } catch { return 1 }
}

if ($SkipTree) { Install-GuestTools; Write-Host "`n-SkipTree given; done. Reboot once."; exit 0 }

$Catalog = @{
    'firefox'            = @{ Remote = 'https://github.com/mozilla-firefox/firefox';   Branch = $null;              Include = $null }
    'enterprise-firefox' = @{ Remote = 'https://github.com/mozilla/enterprise-firefox'; Branch = 'enterprise-main';  Include = 'enterprise' }
}
$Products = @($Products | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $Products) {
    if (-not $Catalog.ContainsKey($name)) { throw "unknown product '$name'; known: $($Catalog.Keys -join ', ')" }
}

$isArm64 = $env:PROCESSOR_ARCHITECTURE -eq 'ARM64'
$trees = @()
foreach ($name in $Products) {
    $spec = $Catalog[$name]
    $tree = Join-Path $SrcRoot $name
    $trees += $tree
    Step "${name}: ensure clone at $tree"
    if (-not (Test-Path (Join-Path $tree 'mach'))) {
        # A directory here without a mach in it is a clone that never finished (interrupted, or
        # two clones racing). git refuses to clone into it, which would block every later run,
        # and there is nothing worth keeping, so clear it out.
        if (Test-Path $tree) {
            Write-Warning "$tree exists but has no mach: discarding the incomplete clone"
            Remove-Item $tree -Recurse -Force -ErrorAction Stop
        }
        $branchArg = if ($spec.Branch) { " --branch $($spec.Branch)" } else { '' }
        $rc = Invoke-Unelevated -WorkingDir $SrcRoot -Label "git clone $name" `
                -Command "git clone$branchArg $($spec.Remote) ""$tree"""
        if ($null -eq $rc) {
            Write-Warning 'could not drop privileges; cloning elevated (the ACL check below will repair what it can)'
            $cloneArgs = @('clone')
            if ($spec.Branch) { $cloneArgs += @('--branch', $spec.Branch) }
            git @cloneArgs $spec.Remote $tree
            $rc = $LASTEXITCODE
        }
        if ($rc -ne 0) { throw "git clone of $name failed ($rc)" }
        git -C $tree maintenance start
    }

    # mozconfig = product-specific include(s) + the chosen generic template.
    $lines = @("# generated by firefox-win-dev setup.ps1 for $name; template: $Mozconfig")
    if ($spec.Include -eq 'enterprise') {
        if ($isArm64) {
            # build/win64/mozconfig.enterprise pins x86_64; on ARM64 take the common part + our target.
            $lines += '. "$topsrcdir/build/mozconfig.common.enterprise"'
            $lines += 'ac_add_options --target=aarch64-pc-windows-msvc'
        } else {
            $lines += '. "$topsrcdir/build/win64/mozconfig.enterprise"'
        }
    }
    $lines += Get-Content (Join-Path $Here "mozconfigs\$Mozconfig")
    Set-Content -Path (Join-Path $tree 'mozconfig') -Value $lines -Encoding ascii

    Step "${name}: mach bootstrap (non-interactive; pinned toolchains incl. MSVC/SDK bundle, cached in $env:MOZBUILD_STATE_PATH)"
    # mach from PowerShell needs C:\mozilla-build\bin on PATH (done above) and a native python on
    # PATH (winget). Documented as experimental; verified working on 25H2. Unelevated: see the
    # note on Invoke-Unelevated - this is the step whose toolchain directories go unreadable
    # otherwise.
    $machCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ' +
               '".\mach.ps1 --no-interactive bootstrap --application-choice=''Firefox for Desktop''"'
    $rc = Invoke-Unelevated -WorkingDir $tree -Label "mach bootstrap $name" -Command $machCmd
    if ($null -eq $rc) {
        Write-Warning 'could not drop privileges; bootstrapping elevated (the ACL check below will repair what it can)'
        Push-Location $tree
        try {
            .\mach.ps1 --no-interactive bootstrap --application-choice='Firefox for Desktop'
            $rc = $LASTEXITCODE
        } finally { Pop-Location }
    }
    if ($rc -ne 0) { throw "mach bootstrap failed for $name ($rc)" }
}

# Safety net for the tarfile/os.mkdir(0o700) descriptor described above: with bootstrap run
# unelevated this should find nothing, but it still covers a box provisioned before that fix, or
# one where dropping privileges failed and we fell back to running elevated. Probing is cheap
# (one Get-Acl per toolchain, no recursion), so only pay for takeown/icacls on the subtrees that
# are actually unreadable.
Step 'toolchains: check permissions bootstrap left behind'
$broken = @()
foreach ($d in Get-ChildItem $env:MOZBUILD_STATE_PATH -Directory -ErrorAction SilentlyContinue) {
    try { Get-Acl $d.FullName -ErrorAction Stop | Out-Null } catch { $broken += $d.FullName }
}
if (-not $broken) {
    Write-Host '  all readable'
} else {
    Write-Host "  $($broken.Count) unreadable; taking ownership and regranting"
    foreach ($b in $broken) {
        Write-Host "    $b"
        Invoke-Native { takeown /f $b /r /d y } 2>&1 | Out-Null
        Invoke-Native { icacls $b /grant "${devUser}:(OI)(CI)F" /t /c /q } 2>&1 | Out-Null
    }
    $still = @($broken | Where-Object { try { Get-Acl $_ -ErrorAction Stop | Out-Null; $false } catch { $true } })
    if ($still) { Write-Warning "still unreadable after repair: $($still -join ', ')" }
}

Install-GuestTools

Write-Host "`nDone. Reboot once (long paths / Dev Mode / guest tools), then:" -ForegroundColor Green
foreach ($t in $trees) { Write-Host "  cd $t ; .\mach.ps1 build" -ForegroundColor Green }

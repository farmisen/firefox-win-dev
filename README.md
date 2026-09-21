# firefox-win-dev

Reproducible Windows 11 setup for native Firefox development (x64 and ARM64),
identical for VMs and bare metal. Companion to `firefox-win64-cross-toolchain`:
that one builds Windows Firefox *from* Linux; this one stands up a Windows box
that builds it natively with a fast iteration loop.

```
Autounattend.xml      OS install, disk layout, local account, first-logon hook
setup.ps1             idempotent converge script (rerun any time)
fx-dev.winget         declarative machine state (WinGet Configuration, DSC v3)
mozconfigs/           debug (default loop) and opt (investigations)
```

## First boot

1. Edit `Autounattend.xml`: replace `PASSWORD_HERE` (2x) and the raw URL in
   `FirstLogonCommands`, or ship the repo on the media at
   `sources\$OEM$\$1\fxsetup\` so nothing is downloaded.
2. ARM64 media only:
   `(Get-Content Autounattend.xml) -replace 'processorArchitecture="amd64"','processorArchitecture="arm64"' | Set-Content Autounattend.xml`
3. Put the XML at the root of the ISO/USB. Boot. Walk away (~45–90 min incl.
   the first `mach bootstrap` toolchain download).
4. Reboot once, then `cd D:\src\firefox; .\mach.ps1 build`.

VM: give disk 0 >= 220 GB, **or** a second disk >= 100 GB and set
`Extend=true` on partition 3 / drop partition 4 in the XML.
Bare metal: same XML on a USB; it wipes disk 0.

## Reconverge / drift

```powershell
.\setup.ps1                          # everything, skips what's already done
winget configure test -f fx-dev.winget   # report drift only
```

## Reviewing other people's work without touching your tree

```powershell
cd D:\src\firefox
git worktree add ..\fx-pr-1234 main
cd ..\fx-pr-1234
gh pr checkout 1234
Copy-Item ..\..\firefox-win-dev\mozconfigs\mozconfig.debug .\mozconfig
.\mach.ps1 build       # its own obj-debug, shares sccache with the main tree
```

## Design notes

* **Dev Drive (ReFS) for `src`, objdirs, `.mozbuild`, sccache.** Defender runs in
  performance mode there; only the C: bits get explicit exclusions.
* **No Visual Studio install.** `mach bootstrap` fetches the pinned MSVC + SDK
  bundle (same hydration the cross toolchain does). Build Tools is commented
  out in `fx-dev.winget` for people who want the debugger UI.
* **MozillaBuild is the one imperative install.** Not in winget; `setup.ps1`
  handles it with a presence check.
* **mach from PowerShell** (`mach.ps1`) is what the script uses; it's still
  documented as experimental upstream. If it misbehaves, run the same
  `bootstrap`/`build` from `C:\mozilla-build\start-shell.bat`.

## Things to verify once on a real machine

* winget package IDs (`winget search`), MozillaBuild `/S` silent flag.
* Partition 4 is seen as RAW by `Get-Partition` after setup (Candidate A in
  `setup.ps1`); otherwise the second-disk path (Candidate B) is the fallback.
* The exact `mach bootstrap` application-choice string for your tree revision.

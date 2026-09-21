# firefox-win-dev

Reproducible Windows 11 setup for native Firefox development (x64 and ARM64),
identical for VMs and bare metal. Companion to `firefox-win64-cross-toolchain`:
that one builds Windows Firefox *from* Linux; this one stands up a Windows box
that builds it natively with a fast iteration loop.

```
bootstrap.sh                   one shot: render XML + fetch ISO + remaster  (Linux/macOS host)
scripts/build-autounattend.sh  Autounattend.template.xml -> build/Autounattend.xml
scripts/fetch-iso.sh           official Win11 ISO from Microsoft (stdlib Python port of Fido's API calls)
scripts/make-iso.sh            put the XML at the ISO root, or build a sidecar ISO
scripts/vm.sh                  create + start a throwaway VM: qemu | vmware | parallels
Autounattend.template.xml      OS install, disk layout, local account, first-logon hook
setup.ps1                      idempotent converge script, runs on the Windows box
fx-dev.winget                  declarative machine state (WinGet Configuration, DSC v3)
mozconfigs/                    debug (default loop) and opt (investigations)
```

## Build the install media (on your Linux host)

```bash
sudo apt install p7zip-full genisoimage        # once

# A) first logon pulls setup.ps1 & co. from the repo (needs the remote to exist)
./bootstrap.sh --arch x64 \
  --setup-url https://raw.githubusercontent.com/<org>/firefox-win-dev/main \
  --key-file ~/.win11-pro.key                  # optional; omit to install unlicensed

# B) embed this checkout's setup.ps1 (+ fx-dev.winget, mozconfigs/) on the media
./bootstrap.sh --arch x64 --setup-file ./setup.ps1 --key-file ~/.win11-pro.key
```

Exactly one of `--setup-url` / `--setup-file` is required. Both prompt for the
local account password and write `build/win11-x64-unattended.iso`. B is what
you want while iterating on `setup.ps1` (no push per try) and for machines
without network at first logon; A is what you want for a shared, pinned URL.

`--arch arm64` for Windows on ARM VMs/machines. `--iso path.iso` reuses an ISO
you already have. `--sidecar` skips the 6 GB remaster and produces a tiny ISO
holding the XML (and, with `--setup-file`, the `fxsetup` folder): attach it as
a **second** CD-ROM next to the stock Windows ISO in a VM (Setup scans every
removable root for `Autounattend.xml`; the first-logon hook scans every drive
for `fxsetup\setup.ps1`).

Secrets never touch the tree: the password is prompted (or `FXWD_PASSWORD`),
the key comes from `--key-file` / `FXWD_PRODUCT_KEY`, and everything rendered
is under `build/` (gitignored, mode 600). The XML stores the password
base64-obfuscated, not encrypted; treat the ISO accordingly.

## Testing the media locally (QEMU/KVM, x64)

Layer by layer, cheapest first:

```bash
# 1. Rendering only -- seconds. Inspect build/Autounattend.xml by eye.
FXWD_PASSWORD=test ./scripts/build-autounattend.sh --setup-file ./setup.ps1

# 2. Media assembly without the 6 GB download -- ~1 s.
./scripts/make-iso.sh --sidecar --fxsetup-dir .   # or: ./bootstrap.sh --sidecar --setup-file ./setup.ps1

# 3. Full media (downloads the ISO once; reused afterwards).
./bootstrap.sh --arch x64 --setup-file ./setup.ps1

# 4. Boot it. Unattended install ~10 min, then setup.ps1 + mach bootstrap ~30-60 min.
./scripts/vm.sh                                 # QEMU/KVM on Linux; window if $DISPLAY, else VNC :5900
./scripts/vm.sh --hypervisor vmware             # VMware Workstation / Fusion (via vmrun)
./scripts/vm.sh --hypervisor parallels          # Parallels Desktop (macOS; needs --arch arm64 media)
./scripts/vm.sh --fresh                         # destroy the VM and reinstall
./scripts/vm.sh --iso build/win11-x64.iso --sidecar build/autounattend-sidecar.iso

# ...or in one go: build the media and start the VM
./bootstrap.sh --arch x64 --setup-file ./setup.ps1 --vm qemu
```

What "pass" looks like: Setup never asks a question, reboots into the `fxdev`
desktop on its own, a PowerShell window runs `setup.ps1`, `D:` shows up as a
Dev Drive, and after the final reboot `cd D:\src\firefox; .\mach.ps1 build` starts
compiling. What to watch for on a first run: the disk-layout step (partition 4
left RAW), the first reboot (must come from the disk, not the CD -- see notes in
`vm.sh`), and the winget/MozillaBuild steps in `setup.ps1`.

`vm.sh` picks the hypervisor from the host when `--hypervisor` is omitted (QEMU on
Linux; Parallels, else VMware Fusion, on macOS). All backends use the same shape:
UEFI, SATA disk + CD (stock Windows has those drivers), e1000e NAT, no TPM, and
no forced boot order — the empty disk falls through to the CD once, then
Windows Boot Manager wins. QEMU needs `qemu-system-x86 ovmf` and a user in the
`kvm` group. ARM64 guests need an ARM64 host: Parallels or Fusion on Apple
Silicon, or QEMU with KVM on an ARM Linux box (under TCG it's unusably slow).

## First boot

1. Boot the ISO (UEFI). Walk away (~45–90 min incl. the first `mach bootstrap`
   toolchain download).
2. Reboot once, then `cd D:\src\firefox; .\mach.ps1 build`.

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

* `fetch-iso.py`: the request sequence is ported from Fido and Microsoft can
  change it; edition ids are read from Fido.ps1 at run time so releases roll
  over without edits. Compare the printed SHA-256 with the download page once.
* `make-iso.sh`: boots in your hypervisor of choice (genisoimage `-udf -iso-level 3`
  is the standard Win11 remaster recipe, but check once).
* winget package IDs (`winget search`), MozillaBuild `/S` silent flag.
* Partition 4 is seen as RAW by `Get-Partition` after setup (Candidate A in
  `setup.ps1`); otherwise the second-disk path (Candidate B) is the fallback.
* The exact `mach bootstrap` application-choice string for your tree revision.

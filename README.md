# firefox-win-dev

Unattended, reproducible Windows 11 machine for native Firefox development, in a
VM (QEMU, VMware, Parallels) or on bare metal. One command builds the install
media; the machine installs itself, then clones and bootstraps the tree(s).

```
bootstrap.sh                   build the media (and optionally start a VM)
scripts/vm.sh                  create + start a dev VM: qemu | vmware | parallels
scripts/fetch-iso.sh           official Windows 11 ISO from Microsoft
scripts/make-iso.sh            remaster the ISO with the answer file, or build a sidecar ISO
scripts/build-autounattend.sh  render Autounattend.template.xml
Autounattend.template.xml      OS install, disk layout, local account, first-logon hook
setup.ps1                      runs on the Windows box; idempotent, re-run any time
fx-dev.winget                  tools + OS settings (WinGet Configuration)
mozconfigs/                    debug (default) and opt
```

## Quick start

```bash
sudo apt install p7zip-full genisoimage            # Linux host, once

# dev VM on this host (QEMU on Linux; Parallels/Fusion on macOS)
./bootstrap.sh --arch x64 --setup-file ./setup.ps1 --vm

# bare metal: same media on a USB stick (it wipes disk 0 of the machine it boots)
./bootstrap.sh --arch x64 --setup-file ./setup.ps1
```

You are asked for the local account password; everything else is unattended.
About 10 minutes to the desktop, then 30-60 minutes of `setup.ps1` (tools, Dev
Drive, clone, `mach bootstrap`). Reboot once, then:

```powershell
cd D:\src\firefox
.\mach.ps1 build
```

## Options

| flag | |
|---|---|
| `--setup-file ./setup.ps1` | embed this checkout's `setup.ps1` (+ `fx-dev.winget`, `mozconfigs/`) on the media |
| `--setup-url URL` | instead, fetch them at first logon from a raw URL (e.g. `https://raw.githubusercontent.com/<org>/firefox-win-dev/main`) |
| `--product P` | `firefox` (default) and/or `enterprise-firefox`; repeat for both |
| `--arch x64\|arm64` | Windows on ARM needs an ARM64 host (Apple Silicon, ARM Linux) |
| `--key-file PATH` | Windows product key; omit to install unactivated |
| `--username NAME` | local admin account (default `fxdev`; no spaces, the build breaks on them) |
| `--vm [--hypervisor H] [--vm-fresh]` | start a VM after building; `H` = `qemu`, `vmware`, `parallels` (default from host) |
| `--iso PATH` | reuse an ISO you already have |
| `--sidecar` | tiny ISO with only the answer file, to attach next to a stock Windows ISO |

`vm.sh` takes `--name`, `--cpus`, `--ram`, `--disk` (defaults: half the host's
cores and RAM, 260 GB sparse disk) and `--fresh`. Several VMs can coexist.

Secrets stay out of the tree: password prompted (or `FXWD_PASSWORD`), key from
`--key-file` (or `FXWD_PRODUCT_KEY`), rendered files under gitignored `build/`.
The answer file stores the password base64-obfuscated, not encrypted.

## What you get

- `D:` is a Dev Drive (ReFS): `D:\src\<product>`, `D:\.mozbuild` (toolchains), `D:\sccache`
- Git, Python, PowerShell 7, Windows Terminal, VS Code, WinDbg, GitHub CLI, MozillaBuild
- long paths, Developer Mode, `RemoteSigned` execution policy, Defender exclusions
- per product: a clone (enterprise-firefox on `enterprise-main`) with a generated
  `mozconfig` (template + `build/win64/mozconfig.enterprise` for enterprise), bootstrapped

No Visual Studio: `mach bootstrap` fetches the pinned MSVC + SDK bundle.
Work from PowerShell (`.\mach.ps1 ...`) or MozillaBuild's bash
(`C:\mozilla-build\start-shell.bat`); both use the same tree and caches.

## Re-running / iterating on setup.ps1

`setup.ps1` checks before every step, so it can be re-run at any time, also
with other arguments (`C:\fxsetup\setup.ps1 -Products enterprise-firefox`).
To test a change without reinstalling, serve the repo from the host and pull it
into the VM:

```bash
python3 -m http.server 8000          # on the host, in this repo
```
```powershell
irm http://<host>:8000/setup.ps1 -OutFile C:\fxsetup\setup.ps1
C:\fxsetup\setup.ps1
```

`<host>` from inside the guest: QEMU `10.0.2.2`, VMware `.1` of the vmnet8
subnet (`ipconfig` shows the gateway `.2`; the host is `.1`), Parallels
`10.211.55.2`. `winget configure test -f C:\fxsetup\fx-dev.winget` reports drift.

## Status

Verified end to end on Windows 11 25H2 x64 with QEMU/KVM and VMware Workstation
on Linux, through `mach build`. Not yet exercised: ARM64 media, Parallels,
`--setup-url` mode, bare metal.

Disk layout expects a single disk >= 220 GB (partition 4 is left RAW and becomes
the Dev Drive). For a VM with two disks, set `Extend=true` on partition 3 and drop
partition 4 in the template; the RAW second disk is picked up instead.

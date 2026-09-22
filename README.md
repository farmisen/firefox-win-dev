# firefox-win-dev

Unattended Windows 11 machine for native Firefox development, in a VM (QEMU,
VMware, Parallels) or on bare metal. One command builds the install media; the
machine installs itself, then clones and bootstraps the tree(s).

```
bootstrap.sh                   build the media (and optionally start a VM)
scripts/vm.sh                  create + start a dev VM: qemu | vmware | parallels
scripts/fetch-iso.sh           official Windows 11 ISO from Microsoft
scripts/make-iso.sh            remaster the ISO with the answer file, or build a sidecar ISO
scripts/build-autounattend.sh  render Autounattend.template.xml
scripts/export-vm.sh           package a provisioned VM into one portable artifact
Autounattend.template.xml      OS install, disk layout, local account, first-logon hook
setup.ps1                      runs on the Windows box; idempotent, re-run any time
fx-dev.winget                  tools + OS settings (WinGet Configuration)
mozconfigs/                    debug (default) and opt
```

## Quick start

```bash
sudo apt install p7zip-full genisoimage            # Linux host, once
brew install p7zip cdrtools                        # macOS host, once

# dev VM on this host (QEMU on Linux; Parallels/Fusion on macOS)
./bootstrap.sh --arch x64 --setup-file ./setup.ps1 --vm

# bare metal: same media on a USB stick (it wipes disk 0 of the machine it boots)
./bootstrap.sh --arch x64 --setup-file ./setup.ps1
```

You are asked for the local account password; everything else is unattended
(~10 min to the desktop, then 30-60 min of `setup.ps1`). Reboot once, then:

```powershell
cd D:\src\firefox
.\mach.ps1 build
```

## Options

| flag | |
|---|---|
| `--setup-file ./setup.ps1` | embed this checkout's `setup.ps1` (+ `fx-dev.winget`, `mozconfigs/`) on the media |
| `--setup-url URL` | fetch them at first logon instead, e.g. `https://raw.githubusercontent.com/farmisen/firefox-win-dev/main` |
| `--product P` | `firefox` (default) and/or `enterprise-firefox`; repeat for both |
| `--skip-tree` | provision the toolchain but skip the Firefox clone: a lean box to snapshot and share with `scripts/export-vm.sh` |
| `--arch x64\|arm64` | Windows on ARM needs an ARM64 host (Apple Silicon, ARM Linux). Windows 11 ARM has no inbox driver for VMware NICs; with `--setup-file` on a Mac that has Fusion, its vmxnet3 driver is staged into `fxsetup/drivers` and setup.ps1 installs it before touching the network |
| `--key-file PATH` | Windows product key; omit to install unactivated (Microsoft's public generic KMS client key for the edition is fetched at render time so Setup never stops at the key page) |
| `--allow-windows-update` | leave OS Windows Update auto-updates on; default off, so a build VM does not download/reboot mid-build. Store app auto-update is always off (it swaps winget mid-setup) |
| `--username NAME` | local admin account (default `fxdev`; no spaces) |
| `--vm [--hypervisor H] [--vm-fresh]` | start a VM after building; `H` = `qemu`, `vmware`, `parallels` (default from host). On VMware the Tools ISO is attached as an extra CD and setup.ps1 installs it silently (reboot deferred) |
| `--iso PATH` | reuse an ISO you already have |
| `--sidecar` | tiny ISO with only the answer file, to attach next to a stock Windows ISO |

`vm.sh` takes `--name`, `--cpus`, `--ram`, `--disk` (defaults: half the host's
cores and RAM, 260 GB sparse disk) and `--fresh`.

Rendered files (they contain the password, base64-obfuscated) live under the
gitignored `build/`.

## What you get

- `D:` is a Dev Drive (ReFS): `D:\src\<product>`, `D:\.mozbuild` (toolchains), `D:\sccache`
- Git, Python, PowerShell 7, Windows Terminal, VS Code, WinDbg, GitHub CLI, MozillaBuild
- long paths, Developer Mode, `RemoteSigned` execution policy, Defender exclusions
- per product: a clone (enterprise-firefox on `enterprise-main`) with a generated
  `mozconfig` (template + `build/win64/mozconfig.enterprise` for enterprise), bootstrapped
- no Visual Studio (`mach bootstrap` fetches the MSVC + SDK bundle); use PowerShell
  (`.\mach.ps1`) or MozillaBuild's bash, same tree and caches

## Reuse / share a VM

To avoid rebuilding, or to hand a ready box to a coworker, snapshot a
toolchain-only VM and export it:

```sh
# build a lean box (toolchain, Dev Drive, MozillaBuild; no Firefox clone)
./bootstrap.sh --arch arm64 --setup-file ./setup.ps1 --skip-tree --vm

# after first-logon setup finishes, package it
scripts/export-vm.sh --hypervisor vmware              # your own reuse: an .ova
scripts/export-vm.sh --hypervisor vmware --sysprep    # to share: new machine SID, runs OOBE
```

Each recipient imports the artifact and runs `C:\fxsetup\setup.ps1` (no
`-SkipTree`) to clone Firefox on their own copy. Export one artifact per
hypervisor: an ARM64 VMware image will not boot on Parallels, and vice versa.
Use `--sysprep` when sharing so clones are not SID-identical; skip it for your
own reuse.

## Notes

`setup.ps1` skips what is already done: re-run it any time, also with other
arguments (`C:\fxsetup\setup.ps1 -Products enterprise-firefox`). On a box where
setup never got as far as step 5 the execution policy is still `Restricted`, so
launch it the way first logon does:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\fxsetup\setup.ps1 -Products enterprise-firefox
```

Guest tools install last and defer their reboot, so the console goes black at
the very end of a run. That is expected: restart and it comes back.

The disk layout expects one disk >= 220 GB (partition 4 is left RAW and becomes
the Dev Drive).

Verified through `mach build` on Windows 11 25H2 x64 with QEMU/KVM and VMware
Workstation on Linux. Not yet exercised: ARM64, Parallels, `--setup-url`, bare metal.

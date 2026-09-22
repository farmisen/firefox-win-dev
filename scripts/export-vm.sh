#!/usr/bin/env bash
# firefox-win-dev / scripts/export-vm.sh
#
# Package a provisioned dev VM into one portable artifact, so you can reuse it
# without rebuilding or hand it to a coworker. Point it at a VM built with
# ./bootstrap.sh --skip-tree (toolchain only, no Firefox clone): that image is
# ~30-40 GB and each person clones on their own copy. A full-build VM is 100 GB+
# and its checkout is stale the moment someone else uses it.
#
#   --name NAME        VM to export (default firefox-win-dev)
#   --hypervisor H     vmware|parallels|qemu (default from host, like vm.sh)
#   --out PATH         output artifact (default build/export/<name>-<date>.<ext>)
#   --sysprep          generalize Windows first (new machine SID, runs OOBE on the
#                      recipient's first boot). Needs the VM running with guest tools
#                      and the account password (--pass or FXWD_PASSWORD). Skip it for
#                      your own reuse; use it to share, so clones are not SID-identical.
#   --zero             fill the guest's free space with zeroes (Sysinternals sdelete)
#                      before shutting down, so compaction and compression have
#                      something to reclaim. Deleted files leave their old blocks on
#                      the virtual disk; without this the artifact carries them.
#                      Needs the VM running with guest tools, the password, and guest
#                      network access (sdelete is downloaded if absent). Slow - it
#                      writes the whole free extent - but it is what makes the image
#                      meaningfully smaller.
#   --user U           guest account for --sysprep/--zero (default fxdev)
#   --pass P           guest password for those (or FXWD_PASSWORD; prompted if unset)
#
# Cross-hypervisor sharing does not work: an ARM64 VMware image will not boot on
# Parallels and vice versa. Export one artifact per hypervisor your team uses.
#   VMware:    an .ova (ovftool), imports into Fusion/Workstation
#   Parallels: the .pvm bundle, tarred
#   QEMU:      a compressed qcow2 disk
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
name=firefox-win-dev hv="" out="" sysprep=0 zero=0 guser=fxdev gpass="${FXWD_PASSWORD:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name=$2; shift 2;;
    --hypervisor) hv=$2; shift 2;;
    --out) out=$2; shift 2;;
    --sysprep) sysprep=1; shift;;
    --zero) zero=1; shift;;
    --user) guser=$2; shift 2;;
    --pass) gpass=$2; shift 2;;
    -h|--help) sed -n '2,32p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

os=$(uname -s)
if [[ -z "$hv" ]]; then
  if [[ $os == Darwin ]]; then hv=$(command -v prlctl >/dev/null && echo parallels || echo vmware)
  else hv=qemu; fi
fi
stamp=$(date +%Y%m%d)
outdir="$here/build/export"; mkdir -p "$outdir"

fusion=/Applications/VMware\ Fusion.app/Contents
vmrun=$(command -v vmrun || echo "$fusion/Public/vmrun")
ovftool=$(command -v ovftool || echo "$fusion/Library/VMware OVF Tool/ovftool")
vdiskmanager=$(command -v vmware-vdiskmanager || echo "$fusion/Library/vmware-vdiskmanager")

need_pass() {
  [[ -n "$gpass" ]] || { read -rsp "Password for guest account '$guser': " gpass; echo >&2; }
}

# Zero the guest's free space so the disk actually compacts. Deleting a file inside the guest
# only unlinks it; the blocks still hold data on the virtual disk, so vdiskmanager -k has nothing
# to reclaim and ovftool compresses the garbage faithfully. sdelete -z writes zeroes over the
# free extent, which collapses under both. Sysinternals ships per-arch binaries; pick by the
# guest's own architecture. Failures per volume are tolerated (ReFS Dev Drives may refuse).
zero_guest() {  # $1 = vmrun flavor, $2 = vmx path
  local flavor=$1 vmx=$2
  need_pass
  echo "zeroing free space in the guest (slow; this is what shrinks the image)..." >&2
  "$vmrun" -T "$flavor" -gu "$guser" -gp "$gpass" runProgramInGuest "$vmx" \
    'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -Command '
      $ErrorActionPreference = "Stop"
      $dir = "C:\fxsetup\sdelete"
      $exe = switch ($env:PROCESSOR_ARCHITECTURE) {
        "ARM64" { "sdelete64a.exe" } "AMD64" { "sdelete64.exe" } default { "sdelete.exe" }
      }
      if (-not (Test-Path (Join-Path $dir $exe))) {
        New-Item -ItemType Directory -Force $dir | Out-Null
        Invoke-WebRequest -UseBasicParsing https://download.sysinternals.com/files/SDelete.zip -OutFile "$dir\SDelete.zip"
        Expand-Archive "$dir\SDelete.zip" -DestinationPath $dir -Force
      }
      $sd = Join-Path $dir $exe
      foreach ($v in Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq "Fixed" }) {
        $d = "$($v.DriveLetter):"
        Write-Host "  zeroing $d ($($v.FileSystemType), $([int]($v.SizeRemaining/1GB)) GB free)"
        & $sd -accepteula -nobanner -z $d
        if ($LASTEXITCODE -ne 0) { Write-Warning "  sdelete on $d exited $LASTEXITCODE; continuing" }
      }
    ' || echo "  (zeroing failed; exporting without it)" >&2
}

# Generalize Windows in the guest and wait for the sysprep-triggered shutdown. Resets the
# machine SID and leaves the image at OOBE, so each recipient's first boot is a clean setup.
sysprep_guest() {  # $1 = vmrun flavor, $2 = vm identifier (vmx path or name)
  local flavor=$1 id=$2
  need_pass
  echo "sysprep: generalizing Windows (this reboots then powers off the guest)..." >&2
  "$vmrun" -T "$flavor" -gu "$guser" -gp "$gpass" runProgramInGuest "$id" -interactive \
    'C:\Windows\System32\Sysprep\Sysprep.exe' /generalize /oobe /shutdown
  echo "  waiting for the guest to power off..." >&2
  local deadline=$(( $(date +%s) + 600 ))
  while "$vmrun" -T "$flavor" list | grep -qF "$id"; do
    (( $(date +%s) < deadline )) || { echo "guest did not power off within 10 min; check sysprep in the VM" >&2; exit 1; }
    sleep 5
  done
}

export_vmware() {
  local dir="$here/build/vm/vmware/$name" vmx
  vmx="$dir/$name.vmx"
  [[ -f "$vmx" ]] || { echo "no VMware VM at $vmx (build one first)" >&2; exit 2; }
  [[ -x "$ovftool" ]] || { echo "ovftool not found (ships with VMware Fusion/Workstation)" >&2; exit 1; }
  local flavor=ws; [[ $os == Darwin ]] && flavor=fusion
  # Zeroing needs the guest up, so it runs before whatever shuts it down.
  (( zero )) && zero_guest "$flavor" "$vmx"
  # Soft, never hard: a hard stop discards the guest's write cache and can leave
  # correctly-sized, zero-filled files inside the image.
  if (( sysprep )); then sysprep_guest "$flavor" "$vmx"
  else "$vmrun" -T "$flavor" stop "$vmx" soft 2>/dev/null || true; fi
  # Compact the disk (reclaims freed blocks). Needs the VM off and no snapshots.
  if [[ -x "$vdiskmanager" && -f "$dir/disk.vmdk" ]]; then
    echo "compacting disk..." >&2; "$vdiskmanager" -k "$dir/disk.vmdk" >/dev/null || echo "  (compaction skipped)" >&2
  fi
  # ovftool would embed every connected CD image, including the 7.5 GB install ISO. Export a
  # sanitized copy of the vmx with the CD-ROM drives removed; the disk (sata0:0) stays.
  local tmpx="$dir/export-$name.vmx"
  grep -Ev '^sata0:[123]\.' "$vmx" > "$tmpx"
  trap 'rm -f "$tmpx"' RETURN
  out=${out:-$outdir/$name-$stamp.ova}
  echo "exporting -> $out ..." >&2
  "$ovftool" --compress=9 --overwrite --targetType=OVA --name="$name" "$tmpx" "$out"
  echo "done -> $out"
  echo "  import: open it in VMware Fusion/Workstation (ARM64 OVA needs an ARM VMware host)."
}

export_parallels() {
  command -v prlctl >/dev/null || { echo "prlctl not found (Parallels Desktop)" >&2; exit 1; }
  local home
  home=$(prlctl list -i "$name" 2>/dev/null | sed -n 's/^Home: //p')
  [[ -n "$home" && -d "$home" ]] || { echo "no Parallels VM named '$name'" >&2; exit 2; }
  if (( sysprep )); then
    [[ -n "$gpass" ]] || { read -rsp "Password for guest account '$guser': " gpass; echo >&2; }
    prlctl exec "$name" --user "$guser" 'C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown' || true
    echo "  waiting for the guest to power off..." >&2
    while [[ "$(prlctl status "$name" 2>/dev/null)" == *running* ]]; do sleep 5; done
  else
    prlctl stop "$name" 2>/dev/null || true
  fi
  prlctl list -i "$name" | grep -qi 'compact' 2>/dev/null || true
  prl_disk_tool compact --hdd "$home/harddisk.hdd" >/dev/null 2>&1 || echo "  (compaction skipped)" >&2
  out=${out:-$outdir/$name-$stamp.pvm.tgz}
  echo "exporting -> $out ..." >&2
  tar czf "$out" -C "$(dirname "$home")" "$(basename "$home")"
  echo "done -> $out"
  echo "  import: unpack, then open the .pvm in Parallels Desktop (Apple Silicon host)."
}

export_qemu() {
  local dir="$here/build/vm/qemu/$name" disk
  disk="$dir/disk.qcow2"
  [[ -f "$disk" ]] || { echo "no QEMU disk at $disk" >&2; exit 2; }
  command -v qemu-img >/dev/null || { echo "qemu-img not found" >&2; exit 1; }
  (( sysprep )) && echo "warning: --sysprep needs a guest agent on QEMU; run sysprep by hand, then export" >&2
  out=${out:-$outdir/$name-$stamp.qcow2}
  echo "exporting (compressing qcow2) -> $out ..." >&2
  qemu-img convert -O qcow2 -c "$disk" "$out"
  echo "done -> $out"
  echo "  import: point scripts/vm.sh at a build/vm/qemu/<name>/disk.qcow2 copy of it, or boot it directly."
}

case "$hv" in
  vmware) export_vmware;; parallels) export_parallels;; qemu) export_qemu;;
  *) echo "--hypervisor must be vmware, parallels or qemu" >&2; exit 2;;
esac

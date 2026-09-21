#!/usr/bin/env bash
# firefox-win-dev / scripts/make-iso.sh
#
# Put a rendered Autounattend.xml onto install media.
#
#   --iso PATH          source Windows 11 ISO (from fetch-iso.sh or elsewhere)
#   --xml PATH          rendered answer file (default build/Autounattend.xml)
#   --out PATH          (default build/win11-<arch>-unattended.iso)
#   --sidecar           instead of remastering, build a tiny ISO holding only
#                       Autounattend.xml: attach it as a 2nd CD-ROM in a VM.
#                       Setup scans every removable-drive root for the file.
#   --fxsetup-dir PATH  embed this dir (setup.ps1, fx-dev.winget, mozconfigs/) on
#                       the media: sources/$OEM$/$1/fxsetup on a remaster (Setup
#                       copies it to C:\fxsetup), /fxsetup on a sidecar. Pair with
#                       an XML rendered via --setup-file.
#
# Requires: 7z (extract), genisoimage (author). Both are in Ubuntu's repos.
# Output is UEFI-bootable (efisys_noprompt.bin, so a VM never waits for a key
# press) and, when the source has boot/etfsboot.com (x64), BIOS-bootable too.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
iso="" xml="$here/build/Autounattend.xml" out="" sidecar=0 fxsetup_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) iso=$2; shift 2;;
    --xml) xml=$2; shift 2;;
    --out) out=$2; shift 2;;
    --sidecar) sidecar=1; shift;;
    --fxsetup-dir) fxsetup_dir=$2; shift 2;;
    -h|--help) sed -n '2,21p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -f "$xml" ]] || { echo "missing $xml (run scripts/build-autounattend.sh first)" >&2; exit 2; }
[[ -z "$fxsetup_dir" || -f "$fxsetup_dir/setup.ps1" ]] || { echo "--fxsetup-dir: $fxsetup_dir/setup.ps1 not found" >&2; exit 2; }
command -v genisoimage >/dev/null || { echo "genisoimage not found (apt install genisoimage)" >&2; exit 1; }

if (( sidecar )); then
  out=${out:-$here/build/autounattend-sidecar.iso}
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cp "$xml" "$tmp/Autounattend.xml"
  [[ -n "$fxsetup_dir" ]] && cp -r "$fxsetup_dir" "$tmp/fxsetup"
  genisoimage -quiet -J -r -V AUTOUNATTEND -o "$out" "$tmp"
  echo "sidecar ISO -> $out  (attach as second CD-ROM alongside the stock Windows ISO)"
  exit 0
fi

[[ -f "$iso" ]] || { echo "--iso PATH is required for a remaster" >&2; exit 2; }
command -v 7z >/dev/null || { echo "7z not found (apt install p7zip-full)" >&2; exit 1; }
base=$(basename "$iso" .iso)
out=${out:-$here/build/$base-unattended.iso}

work=$(mktemp -d -p "$here/build" extract.XXXXXX); trap 'rm -rf "$work"' EXIT
echo "extracting $iso -> $work ..." >&2
7z x -bso0 -bsp1 -o"$work" "$iso"

cp "$xml" "$work/Autounattend.xml"
if [[ -n "$fxsetup_dir" ]]; then
  dst="$work/sources/\$OEM\$/\$1/fxsetup"
  mkdir -p "$dst"
  cp -r "$fxsetup_dir"/. "$dst"/
fi

boot_args=()
if [[ -f "$work/boot/etfsboot.com" ]]; then
  boot_args+=(-b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -eltorito-alt-boot)
fi
efi=efi/microsoft/boot/efisys_noprompt.bin
[[ -f "$work/$efi" ]] || efi=efi/microsoft/boot/efisys.bin
[[ -f "$work/$efi" ]] || { echo "no EFI boot image found in ISO" >&2; exit 1; }
boot_args+=(-e "$efi" -no-emul-boot)

label=$(7z l -slt "$iso" 2>/dev/null | sed -n 's/^Label = //p' | head -n1)
echo "authoring $out ..." >&2
genisoimage -quiet \
  -udf -iso-level 3 -allow-limited-size -J -joliet-long -relaxed-filenames -D \
  -V "${label:-WIN11_UNATTENDED}" \
  "${boot_args[@]}" \
  -o "$out" "$work"

echo "done -> $out"
echo "  VM:         attach as CD-ROM, UEFI firmware, >= 220 GB disk (or 2 disks, see README)"
echo "  Bare metal: dd/ventoy/Rufus it to USB; it will WIPE disk 0 of whatever it boots on"

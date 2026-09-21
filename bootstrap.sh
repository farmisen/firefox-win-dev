#!/usr/bin/env bash
# firefox-win-dev / bootstrap.sh
#
# One shot: render Autounattend.xml, fetch the official Win11 ISO, remaster
# it with the answer file at the root. Everything lands in build/ (gitignored).
#
#   ./bootstrap.sh --arch x64 ( --setup-url https://raw.githubusercontent.com/<org>/firefox-win-dev/main
#                             | --setup-file ./setup.ps1 ) \
#                  [--username fxdev] [--key-file ~/.win11-pro.key] [--iso existing.iso] [--sidecar]
#                  [--vm qemu|vmware|parallels]
#
#   --setup-url    first logon downloads setup.ps1 & co. from this URL
#   --setup-file   embed this setup.ps1 (+ sibling fx-dev.winget, mozconfigs/) on
#                  the media instead; no network needed until setup.ps1 itself runs
#   --iso PATH     skip the download, use this ISO
#   --sidecar      don't remaster; produce a tiny second ISO with the XML (and,
#                  with --setup-file, the fxsetup folder)
#   --vm HV        after building the media, create + start a VM on that
#                  hypervisor (scripts/vm.sh); --vm-fresh recreates it from scratch
#   Any other flag is passed through to scripts/build-autounattend.sh
#   (--password is accepted but you'll be prompted if you omit it, which is
#   the better habit).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

arch=x64 iso="" sidecar=0 setup_file="" vm="" vm_args=() render_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)    arch=$2; render_args+=(--arch "$2"); shift 2;;
    --iso)     iso=$2; shift 2;;
    --sidecar) sidecar=1; shift;;
    --vm)      vm=$2; shift 2;;
    --vm-fresh) vm_args+=(--fresh); shift;;
    --setup-file) setup_file=$2; render_args+=(--setup-file "$2"); shift 2;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *)         render_args+=("$1"); shift;;
  esac
done

"$here/scripts/build-autounattend.sh" "${render_args[@]}"

# --setup-file: stage setup.ps1 and the companions it expects next to itself.
embed=()
if [[ -n "$setup_file" ]]; then
  src_dir=$(cd "$(dirname "$setup_file")" && pwd)
  for f in fx-dev.winget mozconfigs/mozconfig.debug mozconfigs/mozconfig.opt; do
    [[ -f "$src_dir/$f" ]] || { echo "--setup-file: expected $src_dir/$f next to setup.ps1" >&2; exit 2; }
  done
  stage="$here/build/fxsetup"; rm -rf "$stage"; mkdir -p "$stage/mozconfigs"
  cp "$setup_file" "$stage/setup.ps1"
  cp "$src_dir/fx-dev.winget" "$stage/"
  cp "$src_dir"/mozconfigs/mozconfig.* "$stage/mozconfigs/"
  embed=(--fxsetup-dir "$stage")
fi

if (( sidecar )); then
  "$here/scripts/make-iso.sh" --sidecar "${embed[@]}"
  # A sidecar is only useful next to the stock ISO, so a VM needs that too.
  if [[ -n "$vm" ]]; then
    iso=${iso:-$here/build/win11-$arch.iso}
    [[ -f "$iso" ]] || "$here/scripts/fetch-iso.sh" --arch "$arch" --out "$iso"
    exec "$here/scripts/vm.sh" --hypervisor "$vm" --arch "$arch" --iso "$iso" --sidecar "$here/build/autounattend-sidecar.iso" "${vm_args[@]}"
  fi
  exit 0
fi

if [[ -z "$iso" ]]; then
  iso="$here/build/win11-$arch.iso"
  [[ -f "$iso" ]] || "$here/scripts/fetch-iso.sh" --arch "$arch" --out "$iso"
fi

out="$here/build/win11-$arch-unattended.iso"
"$here/scripts/make-iso.sh" --iso "$iso" --out "$out" "${embed[@]}"

if [[ -n "$vm" ]]; then
  exec "$here/scripts/vm.sh" --hypervisor "$vm" --arch "$arch" --iso "$out" "${vm_args[@]}"
fi

#!/usr/bin/env bash
# firefox-win-dev / bootstrap.sh
#
# One shot: render Autounattend.xml, fetch the official Win11 ISO, remaster
# it with the answer file at the root. Everything lands in build/ (gitignored).
#
#   ./bootstrap.sh --arch x64 --setup-url https://raw.githubusercontent.com/<org>/firefox-win-dev/main \
#                  [--username fxdev] [--key-file ~/.win11-pro.key] [--iso existing.iso] [--sidecar] [--offline]
#
#   --iso PATH     skip the download, use this ISO
#   --sidecar      don't remaster; produce a tiny second ISO with just the XML
#   --offline      also embed setup.ps1/fx-dev.winget/mozconfigs on the media
#                  so first logon doesn't need to reach --setup-url
#   Any other flag is passed through to scripts/build-autounattend.sh
#   (--password is accepted but you'll be prompted if you omit it, which is
#   the better habit).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

arch=x64 iso="" sidecar=0 offline=0 render_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)    arch=$2; render_args+=(--arch "$2"); shift 2;;
    --iso)     iso=$2; shift 2;;
    --sidecar) sidecar=1; shift;;
    --offline) offline=1; shift;;
    -h|--help) sed -n '2,17p' "$0"; exit 0;;
    *)         render_args+=("$1"); shift;;
  esac
done

"$here/scripts/build-autounattend.sh" "${render_args[@]}"

if (( sidecar )); then
  "$here/scripts/make-iso.sh" --sidecar
  exit 0
fi

if [[ -z "$iso" ]]; then
  iso="$here/build/win11-$arch.iso"
  [[ -f "$iso" ]] || "$here/scripts/fetch-iso.sh" --arch "$arch" --out "$iso"
fi

oem=()
if (( offline )); then
  stage="$here/build/oem"; rm -rf "$stage"; mkdir -p "$stage"
  cp "$here/setup.ps1" "$here/fx-dev.winget" "$stage"/
  cp -r "$here/mozconfigs" "$stage"/
  oem=(--oem-dir "$stage")
fi

"$here/scripts/make-iso.sh" --iso "$iso" --out "$here/build/win11-$arch-unattended.iso" "${oem[@]}"

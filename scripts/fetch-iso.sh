#!/usr/bin/env bash
# firefox-win-dev / scripts/fetch-iso.sh
#
# Download the official Windows 11 ISO from Microsoft.
#
#   --arch x64|arm64      (default x64)
#   --lang "English"      Fido language name (default English; "English International" for en-GB)
#   --out PATH            (default build/win11-<arch>.iso)
#
# How: Microsoft's download page issues 24h URLs through a session API. Fido
# (pbatard/Fido, the script Rufus uses) speaks that API and is maintained, so
# we drive it with PowerShell. No sudo: if `pwsh` isn't on PATH we unpack a
# pinned PowerShell tarball into .tools/. Override pins with:
#   PWSH_VERSION   (default: latest GitHub release)
#   FIDO_REF       git ref of pbatard/Fido (default: master; pin a commit for reproducibility)
#
# Microsoft publishes SHA-256 hashes on the download page but not via this
# API, so the script prints the hash for you to compare by eye once.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
arch=x64 lang="English" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) arch=$2; shift 2;;
    --lang) lang=$2; shift 2;;
    --out)  out=$2; shift 2;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ "$arch" == x64 || "$arch" == arm64 ]] || { echo "--arch must be x64 or arm64" >&2; exit 2; }
out=${out:-$here/build/win11-$arch.iso}
mkdir -p "$here/build" "$here/.tools"

# ---- pwsh -----------------------------------------------------------------
pwsh=$(command -v pwsh || true)
if [[ -z "$pwsh" ]]; then
  host_arch=$(uname -m)
  case "$host_arch" in
    x86_64) tarch=x64;;
    aarch64|arm64) tarch=arm64;;
    *) echo "unsupported host arch $host_arch; install pwsh manually" >&2; exit 1;;
  esac
  ver=${PWSH_VERSION:-$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')}
  dir="$here/.tools/pwsh-$ver"
  if [[ ! -x "$dir/pwsh" ]]; then
    echo "fetching PowerShell $ver ($tarch) into .tools/ ..." >&2
    mkdir -p "$dir"
    curl -fL --progress-bar \
      "https://github.com/PowerShell/PowerShell/releases/download/v$ver/powershell-$ver-linux-$tarch.tar.gz" \
      | tar xz -C "$dir"
    chmod +x "$dir/pwsh"
  fi
  pwsh="$dir/pwsh"
fi

# ---- Fido -----------------------------------------------------------------
fido_ref=${FIDO_REF:-master}
fido="$here/.tools/Fido-$fido_ref.ps1"
if [[ ! -f "$fido" ]]; then
  curl -fsSL "https://raw.githubusercontent.com/pbatard/Fido/$fido_ref/Fido.ps1" -o "$fido"
fi
echo "Fido.ps1 sha256: $(sha256sum "$fido" | cut -d' ' -f1)  (ref $fido_ref)" >&2

# ---- URL + download -------------------------------------------------------
echo "asking Microsoft for a Windows 11 $arch ISO URL ($lang) ..." >&2
url=$("$pwsh" -NoProfile -NonInteractive -File "$fido" \
        -Win 11 -Rel Latest -Ed Pro -Lang "$lang" -Arch "$arch" -GetUrl | tail -n1)
[[ "$url" == https://* ]] || { echo "Fido did not return a URL:"; echo "$url"; exit 1; } >&2

echo "downloading -> $out (URL valid ~24h; curl -C - resumes)" >&2
curl -fL -C - --progress-bar -o "$out" "$url"
echo "sha256: $(sha256sum "$out" | cut -d' ' -f1)"
echo "Compare against the hash list at https://www.microsoft.com/software-download/windows11 once."

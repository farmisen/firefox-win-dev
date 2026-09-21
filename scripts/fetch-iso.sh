#!/usr/bin/env bash
# firefox-win-dev / scripts/fetch-iso.sh
#
# Download the official Windows 11 ISO from Microsoft.
#
#   --arch x64|arm64      (default x64)
#   --lang REGEX          on Microsoft's language name (default ^English$;
#                         'English International' is en-GB)
#   --out PATH            (default build/win11-<arch>.iso)
#   --url-only            print the (24h) URL instead of downloading
#
# Thin wrapper over scripts/fetch-iso.py, which talks to Microsoft's download
# API directly (stdlib Python, no PowerShell). Fido.ps1 is fetched into .tools/
# purely as data, to read the current product edition ids; pin it with
# FIDO_REF=<commit> for reproducibility.
#
# Microsoft publishes SHA-256 hashes on the download page but not via this
# API, so the script prints the hash for you to compare by eye once.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
exec python3 "$here/scripts/fetch-iso.py" "$@"

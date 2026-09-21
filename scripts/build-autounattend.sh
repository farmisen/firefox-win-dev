#!/usr/bin/env bash
# firefox-win-dev / scripts/build-autounattend.sh
#
# Render Autounattend.template.xml -> build/Autounattend.xml
#
#   --arch x64|arm64          (default x64)
#   --username NAME           local admin, no spaces (default fxdev)
#   --password PW             or omit to be prompted (never echoed)
#   --key-file PATH           file containing a Windows product key (optional)
#   --setup-url URL           raw base URL the first-logon hook fetches from
#   --computer-name NAME      (default fx-win11-<arch>)
#   --edition NAME            image name in install.wim (default "Windows 11 Pro")
#   --out PATH                (default build/Autounattend.xml)
#
# Env alternatives (keep secrets out of shell history):
#   FXWD_PASSWORD, FXWD_PRODUCT_KEY, FXWD_SETUP_URL
#
# The rendered file contains the account password (base64-obfuscated, NOT
# encrypted) and the key. build/ is gitignored; treat the output like a secret.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
arch=x64 username=fxdev password="${FXWD_PASSWORD:-}" key="${FXWD_PRODUCT_KEY:-}"
setup_url="${FXWD_SETUP_URL:-}" computer_name="" edition="Windows 11 Pro"
out="$here/build/Autounattend.xml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)          arch=$2; shift 2;;
    --username)      username=$2; shift 2;;
    --password)      password=$2; shift 2;;
    --key-file)      key=$(tr -d '[:space:]' < "$2"); shift 2;;
    --setup-url)     setup_url=$2; shift 2;;
    --computer-name) computer_name=$2; shift 2;;
    --edition)       edition=$2; shift 2;;
    --out)           out=$2; shift 2;;
    -h|--help)       sed -n '2,22p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

case "$arch" in
  x64)   xml_arch=amd64;;
  arm64) xml_arch=arm64;;
  *) echo "--arch must be x64 or arm64" >&2; exit 2;;
esac
[[ "$username" =~ ^[A-Za-z][A-Za-z0-9_-]{0,19}$ ]] \
  || { echo "username must be 1-20 chars, letters/digits/_/-, no spaces (Firefox build breaks on spaces)" >&2; exit 2; }
[[ -n "$setup_url" ]] || { echo "--setup-url (or FXWD_SETUP_URL) is required, e.g. https://raw.githubusercontent.com/<org>/firefox-win-dev/main" >&2; exit 2; }
setup_url=${setup_url%/}
computer_name=${computer_name:-fx-win11-$arch}

if [[ -z "$password" ]]; then
  read -rsp "Password for local account '$username': " password; echo >&2
  read -rsp "Again: " password2; echo >&2
  [[ "$password" == "$password2" ]] || { echo "passwords differ" >&2; exit 2; }
fi
[[ -n "$password" ]] || { echo "empty password not allowed (AutoLogon needs one)" >&2; exit 2; }

# Windows Setup expects base64( UTF-16LE( password + "Password" ) ).
pw_b64=$(printf '%s' "${password}Password" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)

key_setup="" key_specialize=""
if [[ -n "$key" ]]; then
  key=${key^^}
  [[ "$key" =~ ^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$ ]] || { echo "product key must look like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX" >&2; exit 2; }
  key_setup="<ProductKey><Key>$key</Key><WillShowUI>OnError</WillShowUI></ProductKey>"
  key_specialize="<ProductKey>$key</ProductKey>"
fi

mkdir -p "$(dirname "$out")"
# Placeholders are replaced with python to avoid sed escaping problems in b64/URLs.
python3 - "$here/Autounattend.template.xml" "$out" \
  "$xml_arch" "$username" "$pw_b64" "$key_setup" "$key_specialize" \
  "$setup_url" "$computer_name" "$edition" <<'PY'
import sys, xml.dom.minidom
src, dst, arch, user, pw, ks, ksp, url, cn, ed = sys.argv[1:]
s = open(src, encoding="utf-8").read()
for k, v in {"@@ARCH@@": arch, "@@USERNAME@@": user, "@@PASSWORD_B64@@": pw,
             "@@PRODUCT_KEY_SETUP@@": ks, "@@PRODUCT_KEY_SPECIALIZE@@": ksp,
             "@@SETUP_URL@@": url, "@@COMPUTERNAME@@": cn, "@@EDITION@@": ed}.items():
    s = s.replace(k, v)
import re
left = sorted(set(re.findall(r"@@[A-Z0-9_]+@@", s)))
if left: sys.exit(f"unrendered placeholders: {left}")
xml.dom.minidom.parseString(s)          # well-formedness check
open(dst, "w", encoding="utf-8", newline="\r\n").write(s)
PY
chmod 600 "$out"
echo "rendered $out  (arch=$arch user=$username key=$([[ -n $key ]] && echo yes || echo no))"

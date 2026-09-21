#!/usr/bin/env bash
# firefox-win-dev / scripts/test-vm.sh
#
# Boot install media in a throwaway QEMU/KVM VM to test the unattended flow
# end to end. x64 only (Windows on ARM under TCG emulation is unusably slow).
#
#   --iso PATH        default build/win11-x64-unattended.iso
#   --sidecar PATH    attach a 2nd CD (e.g. build/autounattend-sidecar.iso);
#                     pair it with the *stock* ISO via --iso to test that path
#   --disk 260G       virtual disk size (layout in the XML needs >= 220G; sparse)
#   --ram 8G  --cpus 8
#   --fresh           wipe disk + NVRAM and reinstall
#   --vnc             force VNC on 127.0.0.1:5900 (default when $DISPLAY is unset)
#
# Design notes
# * No -boot/bootindex: OVMF then follows its own NVRAM BootOrder. Fresh vars
#   try the DVD first; Windows Setup writes "Windows Boot Manager" to the top
#   on its first reboot, so the VM stops booting the (no-prompt) CD by itself.
#   If it ever loops back into Setup:  echo eject cd0 | nc -N 127.0.0.1 4444
# * AHCI + e1000e only: stock Windows media has no virtio drivers.
# * No TPM: swtpm isn't required because the XML sets the LabConfig bypasses.
#   Install swtpm and add a tpm-tis if you want to test without them.
# * Stock Windows Firewall + user-mode NAT: guest can reach the internet
#   (winget, MozillaBuild, git clone), host cannot reach the guest. Add
#   hostfwd rules to the -nic line once setup.ps1 enables OpenSSH/RDP.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
dir="$here/build/vm"
iso="$here/build/win11-x64-unattended.iso" sidecar="" disk_size=260G ram=8G cpus=8 fresh=0 vnc=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) iso=$2; shift 2;;
    --sidecar) sidecar=$2; shift 2;;
    --disk) disk_size=$2; shift 2;;
    --ram) ram=$2; shift 2;;
    --cpus) cpus=$2; shift 2;;
    --fresh) fresh=1; shift;;
    --vnc) vnc=1; shift;;
    -h|--help) sed -n '2,15p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -f "$iso" ]] || { echo "missing $iso (run ./bootstrap.sh or pass --iso)" >&2; exit 2; }
[[ -w /dev/kvm ]] || { echo "/dev/kvm not writable: sudo usermod -aG kvm $USER, then re-login" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "apt install qemu-system-x86 ovmf" >&2; exit 1; }
code=/usr/share/OVMF/OVMF_CODE_4M.fd vars_src=/usr/share/OVMF/OVMF_VARS_4M.fd
[[ -f $code && -f $vars_src ]] || { echo "OVMF 4M images not found (apt install ovmf)" >&2; exit 1; }

mkdir -p "$dir"
(( fresh )) && rm -f "$dir/disk.qcow2" "$dir/OVMF_VARS.fd"
[[ -f "$dir/disk.qcow2" ]] || qemu-img create -q -f qcow2 "$dir/disk.qcow2" "$disk_size"
[[ -f "$dir/OVMF_VARS.fd" ]] || cp "$vars_src" "$dir/OVMF_VARS.fd"

display=(-display gtk,gl=off)
if (( vnc )) || [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  display=(-vnc 127.0.0.1:0)
  echo "headless: connect a VNC viewer to 127.0.0.1:5900" >&2
fi

cds=(-drive "id=cd0,if=none,format=raw,media=cdrom,file=$iso" -device ide-cd,drive=cd0,bus=ahci.1)
if [[ -n "$sidecar" ]]; then
  cds+=(-drive "id=cd1,if=none,format=raw,media=cdrom,file=$sidecar" -device ide-cd,drive=cd1,bus=ahci.2)
fi

echo "monitor: nc 127.0.0.1 4444   (e.g. 'eject cd0', 'system_powerdown', 'quit')" >&2
exec qemu-system-x86_64 \
  -name firefox-win-dev-test \
  -enable-kvm -machine q35 -cpu host -smp "$cpus" -m "$ram" \
  -rtc base=localtime \
  -drive "if=pflash,format=raw,readonly=on,file=$code" \
  -drive "if=pflash,format=raw,file=$dir/OVMF_VARS.fd" \
  -device ahci,id=ahci \
  -drive "id=disk0,if=none,format=qcow2,discard=unmap,file=$dir/disk.qcow2" -device ide-hd,drive=disk0,bus=ahci.0 \
  "${cds[@]}" \
  -nic user,model=e1000e \
  -device qemu-xhci -device usb-tablet -device usb-kbd \
  -vga std \
  "${display[@]}" \
  -monitor telnet:127.0.0.1:4444,server,nowait

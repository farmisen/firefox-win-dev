#!/usr/bin/env bash
# firefox-win-dev / scripts/vm.sh
#
# Create (once) and start a Windows 11 development VM from the install media, on
# the hypervisor of your choice. Same knobs everywhere; the backend translates.
# The result is a full dev machine (Dev Drive, toolchains, tree) for anyone
# without Windows hardware, not just a place to test the media.
#
#   --hypervisor qemu|vmware|parallels   (default: qemu on Linux, parallels on
#                                         macOS if prlctl exists, else vmware)
#   --arch x64|arm64      what the ISO contains (default x64). Must match the
#                         host on Apple Silicon (Parallels / Fusion run ARM64 only).
#   --iso PATH            default build/win11-<arch>-unattended.iso
#   --sidecar PATH        attach a 2nd CD (build/autounattend-sidecar.iso with
#                         the *stock* ISO on --iso)
#   --name NAME           VM name / directory (default firefox-win-dev); several can coexist
#   --disk 260G           virtual disk (the answer file's layout needs >= 220G; sparse)
#   --cpus N  --ram SIZE  default: half the host's cores (min 4) and half its RAM
#                         (8G..32G); a Firefox build wants all it can get
#   --fresh               destroy the VM (disk, NVRAM, config) and start over
#   --vnc                 qemu only: force headless VNC on 127.0.0.1:5900
#
# Boot order everywhere: hard disk first, CD second, and never forced. An empty
# disk falls through to the CD on the first boot; once Windows Setup has written
# "Windows Boot Manager" to the firmware NVRAM the disk wins, so the no-prompt
# CD never re-enters Setup. If a hypervisor does not fall through, eject the CD
# after the first reboot (per-backend hints are printed).
#
# Guest devices are chosen so stock Windows media has drivers: AHCI/SATA disks
# and an e1000e NIC. No TPM anywhere; the answer file bypasses the check.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
name=firefox-win-dev
hv="" arch=x64 iso="" sidecar="" disk=260G ram="" cpus="" fresh=0 vnc=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hypervisor) hv=$2; shift 2;;
    --name) name=$2; shift 2;;
    --arch) arch=$2; shift 2;;
    --iso) iso=$2; shift 2;;
    --sidecar) sidecar=$2; shift 2;;
    --disk) disk=$2; shift 2;;
    --ram) ram=$2; shift 2;;
    --cpus) cpus=$2; shift 2;;
    --fresh) fresh=1; shift;;
    --vnc) vnc=1; shift;;
    -h|--help) sed -n '2,31p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

os=$(uname -s) host_arch=$(uname -m)
if [[ -z "$hv" ]]; then
  if [[ $os == Darwin ]]; then hv=$(command -v prlctl >/dev/null && echo parallels || echo vmware)
  else hv=qemu; fi
fi
iso=${iso:-$here/build/win11-$arch-unattended.iso}
[[ -f "$iso" ]] || { echo "missing $iso (run ./bootstrap.sh or pass --iso)" >&2; exit 2; }
[[ -z "$sidecar" || -f "$sidecar" ]] || { echo "missing sidecar $sidecar" >&2; exit 2; }
if [[ $os == Darwin && $host_arch == arm64 && $arch != arm64 && $hv != qemu ]]; then
  echo "Apple Silicon $hv runs ARM64 guests only; build with --arch arm64" >&2; exit 2
fi
iso=$(cd "$(dirname "$iso")" && pwd)/$(basename "$iso")
[[ -n "$sidecar" ]] && sidecar=$(cd "$(dirname "$sidecar")" && pwd)/$(basename "$sidecar")

# Sizing defaults from the host: half the cores (>= 4), half the RAM clamped to 8..32 GB.
if [[ -z "$cpus" ]]; then
  n=$(nproc 2>/dev/null || sysctl -n hw.ncpu); cpus=$(( n / 2 )); (( cpus < 4 )) && cpus=4
fi
if [[ -z "$ram" ]]; then
  if [[ $os == Darwin ]]; then host_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )); else host_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1048576 )); fi
  g=$(( host_gb / 2 )); (( g < 8 )) && g=8; (( g > 32 )) && g=32; ram="${g}G"
fi

# 260G -> 260 (GB) / 266240 (MB) for tools that want integers
disk_gb=${disk%[GgBb]}; disk_gb=${disk_gb%[Gg]}
ram_mb=$(( ${ram%[GgBb]} * 1024 )); [[ $ram == *[Mm]* ]] && ram_mb=${ram%[Mm]*}
dir="$here/build/vm/$hv/$name"

run_qemu() {
  local bin=qemu-system-x86_64 code=/usr/share/OVMF/OVMF_CODE_4M.fd vars=/usr/share/OVMF/OVMF_VARS_4M.fd machine="q35" cpu="host" accel=(-enable-kvm)
  if [[ $arch == arm64 ]]; then
    bin=qemu-system-aarch64 code=/usr/share/AAVMF/AAVMF_CODE.fd vars=/usr/share/AAVMF/AAVMF_VARS.fd machine="virt" cpu="cortex-a72" accel=()
    [[ $host_arch == aarch64 ]] && { cpu=host; accel=(-enable-kvm); }
    [[ ${#accel[@]} -eq 0 ]] && echo "warning: ARM64 guest under TCG emulation is extremely slow" >&2
  fi
  command -v $bin >/dev/null || { echo "$bin not found (apt install qemu-system)" >&2; exit 1; }
  [[ -f $code && -f $vars ]] || { echo "UEFI firmware not found at $code (apt install ovmf / qemu-efi-aarch64)" >&2; exit 1; }
  [[ $arch == x64 && ! -w /dev/kvm ]] && { echo "/dev/kvm not writable: sudo usermod -aG kvm $USER, re-login" >&2; exit 1; }
  mkdir -p "$dir"; (( fresh )) && rm -f "$dir/disk.qcow2" "$dir/VARS.fd"
  [[ -f "$dir/disk.qcow2" ]] || qemu-img create -q -f qcow2 "$dir/disk.qcow2" "$disk"
  [[ -f "$dir/VARS.fd" ]] || cp "$vars" "$dir/VARS.fd"
  local display=(-display gtk,gl=off)
  if (( vnc )) || [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then display=(-vnc 127.0.0.1:0); echo "headless: VNC on 127.0.0.1:5900" >&2; fi
  local cds=(-drive "id=cd0,if=none,format=raw,media=cdrom,file=$iso" -device ide-cd,drive=cd0,bus=ahci.1)
  [[ -n "$sidecar" ]] && cds+=(-drive "id=cd1,if=none,format=raw,media=cdrom,file=$sidecar" -device ide-cd,drive=cd1,bus=ahci.2)
  echo "qemu monitor: nc 127.0.0.1 4444  ('eject cd0', 'system_reset', 'quit')" >&2
  exec $bin -name "$name" "${accel[@]}" -machine "$machine" -cpu "$cpu" -smp "$cpus" -m "$ram" -rtc base=localtime \
    -drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$dir/VARS.fd" \
    -device ahci,id=ahci \
    -drive "id=disk0,if=none,format=qcow2,discard=unmap,file=$dir/disk.qcow2" -device ide-hd,drive=disk0,bus=ahci.0 \
    "${cds[@]}" -nic user,model=e1000e -device qemu-xhci -device usb-tablet -device usb-kbd -vga std \
    "${display[@]}" -monitor telnet:127.0.0.1:4444,server,nowait
}

run_vmware() {
  # Workstation (Linux/Windows) or Fusion (macOS). Needs vmrun; disk via vmware-vdiskmanager or qemu-img.
  local vmrun vdisk flavor=ws
  vmrun=$(command -v vmrun || ls "/Applications/VMware Fusion.app/Contents/Public/vmrun" 2>/dev/null || true)
  [[ -n "$vmrun" ]] || { echo "vmrun not found (VMware Workstation/Fusion)" >&2; exit 1; }
  [[ $os == Darwin ]] && flavor=fusion
  vdisk=$(command -v vmware-vdiskmanager || ls "/Applications/VMware Fusion.app/Contents/Library/vmware-vdiskmanager" 2>/dev/null || true)
  local vmx="$dir/$name.vmx"
  if (( fresh )) && [[ -f "$vmx" ]]; then "$vmrun" -T $flavor stop "$vmx" hard 2>/dev/null || true; rm -rf "$dir"; fi
  mkdir -p "$dir"
  if [[ ! -f "$dir/disk.vmdk" ]]; then
    if [[ -n "$vdisk" ]]; then "$vdisk" -c -s "${disk_gb}GB" -a lsilogic -t 0 "$dir/disk.vmdk" >/dev/null
    else qemu-img create -q -f vmdk -o subformat=monolithicSparse "$dir/disk.vmdk" "$disk"; fi
  fi
  # guestOS: the Windows 10 type avoids Workstation's vTPM + encryption requirement for "windows11-64";
  # the answer file bypasses the TPM check, so it installs fine. ARM (Fusion on Apple Silicon) has one type.
  local guest=windows9-64; [[ $arch == arm64 ]] && guest=arm-windows11-64
  # VMware Tools installer, attached as one more CD-ROM for setup.ps1's guest-tools step
  # (Windows Setup ignores a CD without an answer file). Fusion ships one per arch;
  # Workstation on Linux has x64 only.
  local tools_iso="" tools_arch=x86_x64; [[ $arch == arm64 ]] && tools_arch=arm64
  for t in "/Applications/VMware Fusion.app/Contents/Library/isoimages/$tools_arch/windows.iso" /usr/lib/vmware/isoimages/windows.iso; do
    if [[ -f $t ]]; then tools_iso=$t; break; fi
  done
  [[ -n "$tools_iso" ]] || echo "warning: VMware Tools ISO not found; guest gets no Tools (display resize, clipboard, vmrun guest ops)" >&2
  {
    echo '.encoding = "UTF-8"'; echo 'config.version = "8"'; echo 'virtualHW.version = "20"'
    echo "displayName = \"$name\""; echo "guestOS = \"$guest\""; echo 'firmware = "efi"'
    echo "memsize = \"$ram_mb\""; echo "numvcpus = \"$cpus\""; echo "cpuid.coresPerSocket = \"$cpus\""
    echo 'nvram = "nvram"'; echo 'tools.syncTime = "TRUE"'
    # PCI topology Workstation's wizard always writes. Without the PCIe root ports (pciBridge4-7)
    # a PCIe device such as e1000e gets "No PCIe slot available" and vmware-vmx segfaults.
    echo 'pciBridge0.present = "TRUE"'
    for b in 4 5 6 7; do echo "pciBridge$b.present = \"TRUE\""; echo "pciBridge$b.virtualDev = \"pcieRootPort\""; echo "pciBridge$b.functions = \"8\""; done
    echo 'vmci0.present = "TRUE"'
    echo 'sata0.present = "TRUE"'
    echo 'sata0:0.present = "TRUE"'; echo 'sata0:0.fileName = "disk.vmdk"'
    echo 'sata0:1.present = "TRUE"'; echo 'sata0:1.deviceType = "cdrom-image"'; echo "sata0:1.fileName = \"$iso\""; echo 'sata0:1.startConnected = "TRUE"'
    if [[ -n "$sidecar" ]]; then echo 'sata0:2.present = "TRUE"'; echo 'sata0:2.deviceType = "cdrom-image"'; echo "sata0:2.fileName = \"$sidecar\""; echo 'sata0:2.startConnected = "TRUE"'; fi
    if [[ -n "$tools_iso" ]]; then echo 'sata0:3.present = "TRUE"'; echo 'sata0:3.deviceType = "cdrom-image"'; echo "sata0:3.fileName = \"$tools_iso\""; echo 'sata0:3.startConnected = "TRUE"'; fi
    # Windows 11 ARM has no inbox driver for e1000e (x64 does). Fusion's ARM guests use vmxnet3
    # with VMware's driver, which bootstrap.sh stages under fxsetup/drivers for setup.ps1 to install.
    local nic=e1000e; [[ $arch == arm64 ]] && nic=vmxnet3
    echo 'ethernet0.present = "TRUE"'; echo 'ethernet0.connectionType = "nat"'; echo "ethernet0.virtualDev = \"$nic\""; echo 'ethernet0.addressType = "generated"'
    echo 'usb.present = "TRUE"'; echo 'usb_xhci.present = "TRUE"'; echo 'svga.autodetect = "TRUE"'
    echo 'msg.autoAnswer = "TRUE"'   # no modal dialogs on first start
  } > "$vmx"
  echo "vmx: $vmx" >&2
  echo "if it re-enters Setup after the first reboot: '$vmrun -T $flavor stop \"$vmx\" hard', then set sata0:1.startConnected = \"FALSE\" and start again" >&2
  exec "$vmrun" -T $flavor start "$vmx"
}

run_parallels() {
  command -v prlctl >/dev/null || { echo "prlctl not found (Parallels Desktop, macOS)" >&2; exit 1; }
  if (( fresh )) && prlctl list -a --no-header -o name | grep -qx "$name"; then
    prlctl stop "$name" --kill >/dev/null 2>&1 || true; prlctl delete "$name" >/dev/null
  fi
  if ! prlctl list -a --no-header -o name | grep -qx "$name"; then
    # --ostype takes only a family (windows); the version goes in --distribution.
    prlctl create "$name" --distribution win-11 >/dev/null
    local bios=efi64; [[ $arch == arm64 ]] && bios=efi-arm64
    prlctl set "$name" --cpus "$cpus" --memsize "$ram_mb" --bios-type "$bios" >/dev/null
    prlctl set "$name" --device-set hdd0 --size "$(( disk_gb * 1024 ))" >/dev/null
    prlctl set "$name" --device-set cdrom0 --image "$iso" --connect >/dev/null
    [[ -n "$sidecar" ]] && prlctl set "$name" --device-add cdrom --image "$sidecar" --connect >/dev/null
    prlctl set "$name" --device-bootorder "hdd0 cdrom0" >/dev/null
    prlctl set "$name" --device-set net0 --type shared >/dev/null 2>&1 || true
  fi
  echo "if it re-enters Setup after the first reboot: prlctl set $name --device-set cdrom0 --disconnect" >&2
  # prlctl start alone runs the VM headless when the Parallels Desktop app is not
  # open. Launch the app first, then open the VM bundle so its console window shows.
  home=$(prlctl list -i "$name" | sed -n 's/^Home: //p')
  open -a "Parallels Desktop" 2>/dev/null || true
  prlctl start "$name"
  [[ -n "$home" ]] && open "$home" 2>/dev/null || true
}

case "$hv" in
  qemu) run_qemu;; vmware) run_vmware;; parallels) run_parallels;;
  *) echo "--hypervisor must be qemu, vmware or parallels" >&2; exit 2;;
esac

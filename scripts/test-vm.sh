#!/usr/bin/env bash
# Compatibility shim: the QEMU backend now lives in scripts/vm.sh.
exec "$(dirname "$0")/vm.sh" --hypervisor qemu "$@"

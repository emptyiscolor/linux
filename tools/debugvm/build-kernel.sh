#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build a debuggable x86_64 kernel for the tools/debugvm QEMU VM.
#
# Configures an out-of-tree build from x86_64_defconfig plus
# kernel/configs/kvm_guest.config plus configs/debug.config, builds bzImage and
# modules, and stages modules where run-vm.sh can hand them to the guest.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

JOBS=$(nproc)
KASAN=0
RECONFIG=0
CLEAN=0
MENUCONFIG=0

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

Options:
  -j, --jobs N      parallel build jobs (default: $(nproc))
      --kasan       also merge configs/kasan.config
      --reconfig    regenerate .config from the fragments, discarding local
                    changes to it (implied the first time)
      --menuconfig  run menuconfig after merging the fragments
      --clean       remove the build directory first
  -o, --out DIR     artifact directory (default: $DEBUGVM_OUT_DEFAULT,
                    override with \$DEBUGVM_OUT)
  -h, --help        this text

Artifacts, under the build directory:
  arch/x86/boot/bzImage   kernel run-vm.sh boots
  vmlinux                 unstripped image for gdb
  vmlinux-gdb.py          gdb helper script entry point
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	-j | --jobs) JOBS=$2; shift 2 ;;
	-j*) JOBS=${1#-j}; shift ;;
	--kasan) KASAN=1; shift ;;
	--reconfig) RECONFIG=1; shift ;;
	--menuconfig) MENUCONFIG=1; RECONFIG=1; shift ;;
	--clean) CLEAN=1; RECONFIG=1; shift ;;
	-o | --out) DEBUGVM_OUT=$2; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

debugvm_init_paths

need_cmd make
need_cmd gcc
need_cmd bison
need_cmd flex
need_cmd bc

[ "$CLEAN" = 1 ] && rm -rf -- "$BUILD_DIR"
mkdir -p -- "$BUILD_DIR"

[ -f "$BUILD_DIR/.config" ] || RECONFIG=1

fragments=("$KDIR/kernel/configs/kvm_guest.config" "$HERE/configs/debug.config")
[ "$KASAN" = 1 ] && fragments+=("$HERE/configs/kasan.config")

if [ "$RECONFIG" = 1 ]; then
	info "configuring in $BUILD_DIR"
	make -C "$KDIR" O="$BUILD_DIR" x86_64_defconfig
	# -m only merges; olddefconfig below resolves the new dependencies.
	(cd "$KDIR" && ./scripts/kconfig/merge_config.sh -m -O "$BUILD_DIR" \
		"$BUILD_DIR/.config" "${fragments[@]}")
	make -C "$KDIR" O="$BUILD_DIR" olddefconfig
	[ "$MENUCONFIG" = 1 ] && make -C "$KDIR" O="$BUILD_DIR" menuconfig
else
	info "reusing existing $BUILD_DIR/.config (--reconfig to regenerate)"
	make -C "$KDIR" O="$BUILD_DIR" olddefconfig
fi

for sym in CONFIG_DEBUG_INFO CONFIG_GDB_SCRIPTS; do
	config_is_set "$sym" ||
		warn "$sym is not set in the final .config; gdb will be much less useful"
done
if config_is_set CONFIG_RANDOMIZE_BASE; then
	warn "CONFIG_RANDOMIZE_BASE survived the merge; run-vm.sh passes nokaslr"
fi

# scripts_gdb creates the vmlinux-gdb.py link gdb auto-loads.  The kernel
# Makefile only hangs it off the "all" target, so ask for it explicitly.
info "building bzImage and modules with -j$JOBS"
make -C "$KDIR" O="$BUILD_DIR" -j"$JOBS" bzImage modules scripts_gdb

info "staging modules in $MODULES_DIR"
rm -rf -- "$MODULES_DIR"
make -C "$KDIR" O="$BUILD_DIR" -j"$JOBS" modules_install \
	INSTALL_MOD_PATH="$MODULES_DIR" INSTALL_MOD_STRIP=1 >/dev/null

release=$(cat "$BUILD_DIR/include/config/kernel.release")
info "built $release"
info "  bzImage: $BZIMAGE"
info "  vmlinux: $VMLINUX"
info "  modules: $MODULES_DIR/lib/modules/$release"
info "next: ./build-rootfs.sh   then   ./run-vm.sh --gdb"

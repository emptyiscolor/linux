# SPDX-License-Identifier: GPL-2.0
# Shared helpers for the tools/debugvm scripts.  Sourced, not executed.

KDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DEBUGVM_OUT_DEFAULT="${XDG_CACHE_HOME:-$HOME/.cache}/kernel-debugvm"
DEBUGVM_OUT="${DEBUGVM_OUT:-$DEBUGVM_OUT_DEFAULT}"

# Debian release and guest hostname used by build-rootfs.sh.
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
GUEST_HOSTNAME="${GUEST_HOSTNAME:-debugvm}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m==> warning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		die "$1 not found in PATH${2:+ (install $2)}"
}

# Fill in the derived paths.  Call after option parsing, so that --out is honoured.
debugvm_init_paths() {
	BUILD_DIR="$DEBUGVM_OUT/build"
	MODULES_DIR="$DEBUGVM_OUT/modules"
	ROOTFS="${DEBUGVM_ROOTFS:-$DEBUGVM_OUT/rootfs.ext4}"
	BZIMAGE="$BUILD_DIR/arch/x86/boot/bzImage"
	VMLINUX="$BUILD_DIR/vmlinux"
	mkdir -p -- "$DEBUGVM_OUT"
}

config_is_set() {
	grep -qx "$1=y" "$BUILD_DIR/.config" 2>/dev/null
}

kernel_release() {
	[ -f "$BUILD_DIR/include/config/kernel.release" ] ||
		die "no kernel build in $BUILD_DIR; run ./build-kernel.sh first"
	cat "$BUILD_DIR/include/config/kernel.release"
}

# qemu -drive needs the format spelled out; infer it from the file name.
image_format() {
	case $1 in
	*.qcow2) echo qcow2 ;;
	*) echo raw ;;
	esac
}

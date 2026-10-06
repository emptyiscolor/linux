#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Attach gdb to the QEMU gdb stub opened by run-vm.sh --gdb.
#
# Loads vmlinux from the build directory together with the kernel's own gdb
# scripts (scripts/gdb, enabled by CONFIG_GDB_SCRIPTS), which add lx-dmesg,
# lx-ps, lx-symbols and friends.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

PORT=1234
HOST=localhost
GDB=${GDB:-gdb}
BREAK=

usage() {
	cat <<EOF
Usage: ${0##*/} [options] [-- extra gdb args]

Options:
      --port N     gdb stub port (default: $PORT)
      --host H     gdb stub host (default: $HOST)
  -b, --break SYM  break at SYM before continuing (e.g. start_kernel)
  -o, --out DIR    artifact directory (default: $DEBUGVM_OUT_DEFAULT)
  -h, --help       this text

Useful once attached:
  lx-dmesg            kernel log buffer
  lx-ps               task list
  lx-symbols          load symbols for the modules the guest has loaded
  lx-mounts, lx-lsmod, lx-device-list-tree
  hbreak <function>   hardware breakpoint (needed before paging is up)
See Documentation/process/debugging/gdb-kernel-debugging.rst.
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--port) PORT=$2; shift 2 ;;
	--host) HOST=$2; shift 2 ;;
	-b | --break) BREAK=$2; shift 2 ;;
	-o | --out) DEBUGVM_OUT=$2; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	--) shift; break ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

debugvm_init_paths
need_cmd "$GDB"

[ -f "$VMLINUX" ] || die "no vmlinux at $VMLINUX; run ./build-kernel.sh first"
[ -f "$BUILD_DIR/vmlinux-gdb.py" ] ||
	warn "no vmlinux-gdb.py in $BUILD_DIR; rebuild with CONFIG_GDB_SCRIPTS=y for lx-* commands"

# gdb refuses to auto-load scripts from directories it has not been told to
# trust, and the lx-* commands import from the build tree.
init=$(mktemp -- "${TMPDIR:-/tmp}/debugvm-gdbinit.XXXXXX")
trap 'rm -f -- "$init"' EXIT
cat > "$init" <<EOF
set confirm off
set pagination off
set print pretty on
add-auto-load-safe-path $BUILD_DIR
add-auto-load-safe-path $KDIR
directory $KDIR
set substitute-path /usr/src/linux $KDIR
file $VMLINUX
target remote $HOST:$PORT
EOF
[ -n "$BREAK" ] && printf 'hbreak %s\ncontinue\n' "$BREAK" >> "$init"

info "attaching $GDB to $HOST:$PORT with $VMLINUX"
exec "$GDB" -q -x "$init" "$@"

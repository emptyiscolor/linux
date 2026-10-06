#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Boot the kernel built by build-kernel.sh in QEMU against the Debian rootfs
# built by build-rootfs.sh, optionally stopped at reset with the gdb stub open.
#
# With --gdb, QEMU is started with -s -S: nothing executes until a debugger
# attaches on port 1234 and continues it, which is what you want for breakpoints
# in early boot.  ./gdb.sh attaches with vmlinux and the kernel's gdb scripts.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

GDB=0
GDB_PORT=1234
WAIT=1
MEMORY=2G
SMP=2
SSH_PORT=2222
SNAPSHOT=0
KVM=auto
GRAPHIC=0
SHARE=
APPEND_EXTRA=
QEMU=qemu-system-x86_64

usage() {
	cat <<EOF
Usage: ${0##*/} [options] [-- extra qemu args]

Options:
      --gdb               open the gdb stub and stop the guest at reset (-s -S)
      --gdb-no-wait       open the gdb stub but let the guest boot (-s)
      --gdb-port N        gdb stub port (default: $GDB_PORT)
  -m, --memory SIZE       guest RAM (default: $MEMORY; use 4G or more with KASAN)
  -c, --cpus N            vCPUs (default: $SMP)
      --ssh-port N        host port forwarded to guest 22 (default: $SSH_PORT)
      --snapshot          discard disk writes on exit
      --no-kvm            plain TCG even when /dev/kvm is usable
      --graphic           keep the QEMU window instead of -nographic
      --share DIR         share DIR with the guest at /mnt/host (9p)
      --append "..."      extra kernel command line arguments
  -o, --out DIR           artifact directory (default: $DEBUGVM_OUT_DEFAULT)
  -h, --help              this text

The serial console is on this terminal.  Ctrl-a c reaches the QEMU monitor,
Ctrl-a x quits.
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--gdb) GDB=1; WAIT=1; shift ;;
	--gdb-no-wait) GDB=1; WAIT=0; shift ;;
	--gdb-port) GDB_PORT=$2; shift 2 ;;
	-m | --memory) MEMORY=$2; shift 2 ;;
	-c | --cpus) SMP=$2; shift 2 ;;
	--ssh-port) SSH_PORT=$2; shift 2 ;;
	--snapshot) SNAPSHOT=1; shift ;;
	--no-kvm) KVM=no; shift ;;
	--graphic) GRAPHIC=1; shift ;;
	--share) SHARE=$2; shift 2 ;;
	--append) APPEND_EXTRA=$2; shift 2 ;;
	-o | --out) DEBUGVM_OUT=$2; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	--) shift; break ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

debugvm_init_paths
need_cmd "$QEMU" qemu-system-x86

[ -f "$BZIMAGE" ] || die "no kernel at $BZIMAGE; run ./build-kernel.sh first"

DEBUGVM_ROOT_DEV=/dev/vda
DEBUGVM_METHOD=debootstrap
if [ -f "$DEBUGVM_OUT/rootfs.conf" ]; then
	# shellcheck disable=SC1091
	. "$DEBUGVM_OUT/rootfs.conf"
	ROOTFS="${DEBUGVM_ROOTFS:-$ROOTFS}"
fi
[ -f "$ROOTFS" ] || die "no rootfs at $ROOTFS; run ./build-rootfs.sh first"

SHARE="${SHARE:-$DEBUGVM_OUT/share}"
mkdir -p -- "$SHARE" "$MODULES_DIR/lib/modules"

APPEND="root=$DEBUGVM_ROOT_DEV rootwait rw console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200 nokaslr no_hash_pointers log_buf_len=16M"
[ -n "$APPEND_EXTRA" ] && APPEND="$APPEND $APPEND_EXTRA"

args=(
	-machine q35
	-m "$MEMORY"
	-smp "$SMP"
	-kernel "$BZIMAGE"
	-append "$APPEND"
	-drive "file=$ROOTFS,if=virtio,format=$(image_format "$ROOTFS"),cache=writeback"
	-netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
	-device virtio-net-pci,netdev=net0
	-device virtio-rng-pci
	# Shared directories.  The guest fstab mounts these with nofail, so a stale
	# image that does not know about them still boots.
	-virtfs "local,path=$MODULES_DIR/lib/modules,mount_tag=modules,security_model=none,readonly=on"
	-virtfs "local,path=$SHARE,mount_tag=hostdir,security_model=none"
	-no-reboot
)

if [ "$DEBUGVM_METHOD" = cloud ] && [ -f "$DEBUGVM_OUT/seed.iso" ]; then
	args+=(-drive "file=$DEBUGVM_OUT/seed.iso,if=virtio,format=raw,readonly=on")
fi

if [ "$KVM" = auto ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	# KVM's hardware breakpoints behave; -cpu host keeps the guest fast.
	args+=(-enable-kvm -cpu host)
else
	[ "$KVM" = auto ] && warn "/dev/kvm not usable, falling back to TCG (slow)"
	args+=(-cpu qemu64)
fi

if [ "$GRAPHIC" = 1 ]; then
	args+=(-serial mon:stdio)
else
	args+=(-nographic)
fi

[ "$SNAPSHOT" = 1 ] && args+=(-snapshot)

if [ "$GDB" = 1 ]; then
	args+=(-gdb "tcp::$GDB_PORT")
	[ "$WAIT" = 1 ] && args+=(-S)
	info "gdb stub on tcp::$GDB_PORT$([ "$WAIT" = 1 ] && echo ', guest stopped at reset')"
	info "attach from another terminal:  $HERE/gdb.sh --port $GDB_PORT"
fi

info "booting $(kernel_release) (ssh: ssh -p $SSH_PORT root@localhost)"
exec "$QEMU" "${args[@]}" "$@"

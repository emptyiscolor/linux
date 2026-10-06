#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build a Debian root filesystem image for the tools/debugvm QEMU VM.
#
# Two methods:
#   debootstrap (default)  bootstrap a minimal Debian into a directory and turn
#                          it into a raw ext4 image.  Needs root (via sudo) and
#                          debootstrap, but produces exactly what is asked for.
#   cloud                  download the official Debian genericcloud qcow2 and
#                          attach a cloud-init seed that sets the password and
#                          the serial console.  Needs no root.
#
# Either way the result boots with our own bzImage and no initramfs: root is
# /dev/vda1 (cloud) or /dev/vda (debootstrap), ext4, virtio.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

METHOD=debootstrap
SIZE=8G
ROOT_PASSWORD=root
FORCE=0
EXTRA_PACKAGES=
BASE_PACKAGES=ca-certificates,gdb,kmod,less,systemd-sysv,udev,iproute2,ifupdown,isc-dhcp-client,openssh-server,procps,strace,trace-cmd,vim-tiny

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

Options:
  -m, --method debootstrap|cloud   how to build the image (default: $METHOD)
  -s, --size SIZE                  image size, mkfs/qemu-img syntax (default: $SIZE)
  -p, --password PW                root password in the guest (default: $ROOT_PASSWORD)
      --suite SUITE                Debian suite (default: $DEBIAN_SUITE)
      --mirror URL                 Debian mirror (default: $DEBIAN_MIRROR)
      --packages a,b,c             extra packages to install
  -o, --out DIR                    artifact directory (default: $DEBUGVM_OUT_DEFAULT)
  -f, --force                      overwrite an existing image
  -h, --help                       this text

The image is only reachable from the host over the forwarded SSH port that
run-vm.sh sets up; the password above is a convenience for a throwaway debug
guest, not a secret.
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	-m | --method) METHOD=$2; shift 2 ;;
	-s | --size) SIZE=$2; shift 2 ;;
	-p | --password) ROOT_PASSWORD=$2; shift 2 ;;
	--suite) DEBIAN_SUITE=$2; shift 2 ;;
	--mirror) DEBIAN_MIRROR=$2; shift 2 ;;
	--packages) EXTRA_PACKAGES=$2; shift 2 ;;
	-o | --out) DEBUGVM_OUT=$2; shift 2 ;;
	-f | --force) FORCE=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

case $METHOD in
debootstrap) : ;;
cloud) : ;;
*) die "unknown method: $METHOD (debootstrap or cloud)" ;;
esac

debugvm_init_paths
[ "$METHOD" = cloud ] && ROOTFS="${DEBUGVM_ROOTFS:-$DEBUGVM_OUT/rootfs.qcow2}"

if [ -e "$ROOTFS" ] && [ "$FORCE" != 1 ]; then
	die "$ROOTFS already exists (--force to rebuild)"
fi

SUDO=
if [ "$(id -u)" != 0 ]; then
	need_cmd sudo
	SUDO=sudo
fi

# Copy the staged modules for the kernel built by build-kernel.sh into the image,
# so the guest has working modules even when run-vm.sh is not sharing them.
install_modules() {
	local root=$1 release
	if [ ! -d "$MODULES_DIR/lib/modules" ]; then
		warn "no staged modules in $MODULES_DIR; run ./build-kernel.sh first"
		return 0
	fi
	release=$(ls -1 "$MODULES_DIR/lib/modules" | head -1)
	info "installing modules for $release"
	$SUDO mkdir -p -- "$root/lib/modules"
	$SUDO cp -a -- "$MODULES_DIR/lib/modules/$release" "$root/lib/modules/"
}

build_debootstrap() {
	need_cmd debootstrap
	need_cmd mkfs.ext4 e2fsprogs
	local root
	root=$(mktemp -d -- "$DEBUGVM_OUT/rootfs.XXXXXX")
	cleanup() { $SUDO rm -rf -- "$root"; }
	trap cleanup EXIT

	local packages=$BASE_PACKAGES
	[ -n "$EXTRA_PACKAGES" ] && packages="$packages,$EXTRA_PACKAGES"

	info "debootstrapping Debian $DEBIAN_SUITE into $root"
	$SUDO debootstrap --arch=amd64 --variant=minbase \
		--include="$packages" "$DEBIAN_SUITE" "$root" "$DEBIAN_MIRROR"

	info "configuring the guest"
	# Root on virtio-blk, written by the kernel command line in run-vm.sh.  The
	# 9p mounts are optional (nofail) so the image also boots without them.
	$SUDO tee "$root/etc/fstab" >/dev/null <<-EOF
		/dev/vda  /            ext4  defaults,discard  0 1
		modules   /lib/modules 9p    trans=virtio,version=9p2000.L,ro,nofail    0 0
		hostdir   /mnt/host    9p    trans=virtio,version=9p2000.L,nofail    0 0
	EOF
	$SUDO mkdir -p -- "$root/mnt/host"
	echo "$GUEST_HOSTNAME" | $SUDO tee "$root/etc/hostname" >/dev/null
	$SUDO tee "$root/etc/hosts" >/dev/null <<-EOF
		127.0.0.1	localhost
		127.0.1.1	$GUEST_HOSTNAME
	EOF
	# DHCP on the virtio NIC, whatever QEMU names it.
	$SUDO tee "$root/etc/network/interfaces" >/dev/null <<-EOF
		auto lo
		iface lo inet loopback

		allow-hotplug enp0s1 enp0s2 enp0s3 ens3 ens4
		iface enp0s1 inet dhcp
		iface enp0s2 inet dhcp
		iface enp0s3 inet dhcp
		iface ens3 inet dhcp
		iface ens4 inet dhcp
	EOF
	# Serial console: a getty on ttyS0 and root logins allowed there.
	echo ttyS0 | $SUDO tee -a "$root/etc/securetty" >/dev/null
	$SUDO chroot "$root" systemctl enable serial-getty@ttyS0.service
	# Password root login over the forwarded SSH port, for a throwaway guest.
	$SUDO mkdir -p -- "$root/etc/ssh/sshd_config.d"
	$SUDO tee "$root/etc/ssh/sshd_config.d/debugvm.conf" >/dev/null <<-EOF
		PermitRootLogin yes
		PermitEmptyPasswords no
	EOF
	printf 'root:%s\n' "$ROOT_PASSWORD" | $SUDO chroot "$root" chpasswd
	install_modules "$root"

	info "creating $ROOTFS ($SIZE)"
	rm -f -- "$ROOTFS"
	truncate -s "$SIZE" "$ROOTFS"
	# -d copies the tree in without a loop mount; as root it keeps ownership.
	$SUDO mkfs.ext4 -q -F -L debugvm -d "$root" "$ROOTFS"
	$SUDO chown "$(id -u):$(id -g)" "$ROOTFS"
	cleanup
	trap - EXIT
	DEBUGVM_ROOT_DEV=/dev/vda
}

build_cloud() {
	need_cmd qemu-img
	need_cmd curl
	local iso_tool
	for c in cloud-localds genisoimage xorrisofs mkisofs; do
		command -v "$c" >/dev/null 2>&1 && { iso_tool=$c; break; }
	done
	[ -n "${iso_tool:-}" ] ||
		die "need cloud-localds, genisoimage, xorrisofs or mkisofs to build the cloud-init seed"

	local ver=${DEBIAN_SUITE} base url cache
	case $ver in
	trixie) ver=13 ;;
	bookworm) ver=12 ;;
	bullseye) ver=11 ;;
	esac
	base="debian-$ver-genericcloud-amd64.qcow2"
	url="https://cloud.debian.org/images/cloud/$DEBIAN_SUITE/latest/$base"
	cache="$DEBUGVM_OUT/$base"

	if [ ! -f "$cache" ]; then
		info "downloading $url"
		curl -fL --retry 4 --retry-delay 2 -o "$cache.part" "$url"
		mv -- "$cache.part" "$cache"
	else
		info "using cached $cache"
	fi

	info "creating $ROOTFS ($SIZE) from $base"
	rm -f -- "$ROOTFS"
	qemu-img convert -O qcow2 "$cache" "$ROOTFS"
	qemu-img resize "$ROOTFS" "$SIZE"

	info "building the cloud-init seed"
	local seed_dir
	seed_dir=$(mktemp -d -- "$DEBUGVM_OUT/seed.XXXXXX")
	cat > "$seed_dir/user-data" <<-EOF
		#cloud-config
		hostname: $GUEST_HOSTNAME
		disable_root: false
		ssh_pwauth: true
		chpasswd:
		  expire: false
		  list: |
		    root:$ROOT_PASSWORD
		packages:
		  - gdb
		  - strace
		  - trace-cmd
		runcmd:
		  - [ systemctl, enable, --now, serial-getty@ttyS0.service ]
		  - [ sh, -c, "grep -q ^modules /etc/fstab || printf 'modules /lib/modules 9p trans=virtio,version=9p2000.L,ro,nofail 0 0\\nhostdir /mnt/host 9p trans=virtio,version=9p2000.L,nofail 0 0\\n' >> /etc/fstab" ]
		  - [ mkdir, -p, /mnt/host ]
		  - [ systemctl, daemon-reload ]
		  - [ mount, -a ]
	EOF
	printf 'instance-id: %s\nlocal-hostname: %s\n' "debugvm-$(date +%s)" "$GUEST_HOSTNAME" \
		> "$seed_dir/meta-data"
	rm -f -- "$SEED_ISO"
	case $iso_tool in
	cloud-localds)
		cloud-localds "$SEED_ISO" "$seed_dir/user-data" "$seed_dir/meta-data" ;;
	*)
		"$iso_tool" -quiet -output "$SEED_ISO" -volid cidata -joliet -rational-rock \
			"$seed_dir/user-data" "$seed_dir/meta-data" ;;
	esac
	rm -rf -- "$seed_dir"
	DEBUGVM_ROOT_DEV=/dev/vda1
}

SEED_ISO="$DEBUGVM_OUT/seed.iso"

case $METHOD in
debootstrap) build_debootstrap ;;
cloud) build_cloud ;;
esac

# run-vm.sh reads this to pick root= and whether to attach the seed.
cat > "$DEBUGVM_OUT/rootfs.conf" <<EOF
# Written by build-rootfs.sh; read by run-vm.sh.
DEBUGVM_ROOTFS=$ROOTFS
DEBUGVM_ROOT_DEV=$DEBUGVM_ROOT_DEV
DEBUGVM_METHOD=$METHOD
EOF

info "rootfs ready: $ROOTFS (root=$DEBUGVM_ROOT_DEV, login root/$ROOT_PASSWORD)"
info "next: ./run-vm.sh --gdb"

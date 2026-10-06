# debugvm: a Debian QEMU VM for kernel debugging

Four scripts that build a debuggable kernel, build a Debian root filesystem,
boot the two in QEMU with the gdb stub open, and attach gdb with `vmlinux` and
the kernel's own gdb helper scripts.

```
./build-kernel.sh          # configure + build bzImage, vmlinux, modules
./build-rootfs.sh          # debootstrap a Debian rootfs into an ext4 image
./run-vm.sh --gdb          # boot it, stopped at reset, gdb stub on :1234
./gdb.sh -b start_kernel   # from a second terminal: attach and break early
```

Everything lands in `~/.cache/kernel-debugvm` (override with `--out DIR` or
`$DEBUGVM_OUT`), so the kernel tree stays clean.

## Prerequisites

Host packages, Debian/Ubuntu names:

```
sudo apt install build-essential flex bison bc libelf-dev libssl-dev kmod \
                 qemu-system-x86 gdb debootstrap e2fsprogs
```

`build-rootfs.sh` uses `sudo` for `debootstrap` and `mkfs.ext4 -d`. For KVM
acceleration your user needs read/write on `/dev/kvm`; without it `run-vm.sh`
falls back to TCG and says so.

If you would rather not use `sudo` at all, `./build-rootfs.sh --method cloud`
downloads the official Debian genericcloud qcow2 and attaches a cloud-init seed
instead. It needs `qemu-img`, `curl`, and one of `cloud-localds`,
`genisoimage`, `xorrisofs` or `mkisofs`.

## The pieces

| File | What it does |
| --- | --- |
| `configs/debug.config` | kernel config fragment: full DWARF, `CONFIG_GDB_SCRIPTS`, frame pointer unwinder, no KASLR, lockdep, kgdb, virtio + ext4 built in |
| `configs/kasan.config` | optional generic KASAN fragment |
| `build-kernel.sh` | `x86_64_defconfig` + `kernel/configs/kvm_guest.config` + the fragments above, out-of-tree, then `bzImage` and `modules` |
| `build-rootfs.sh` | Debian rootfs image, serial console, DHCP, root password, modules installed |
| `run-vm.sh` | boots `bzImage` + the rootfs with virtio, 9p shares and a forwarded SSH port; `--gdb` adds `-s -S` |
| `gdb.sh` | attaches gdb to the stub with `vmlinux` and `scripts/gdb` loaded |
| `lib.sh` | shared paths and helpers, sourced by the scripts |

## Why these config options

* **`CONFIG_DEBUG_INFO` (toolchain-default DWARF), unreduced and unsplit** —
  gdb needs the full type and line information. Reduced or split debug info
  leaves gdb unable to print most structures.
* **`CONFIG_GDB_SCRIPTS=y`** — creates `vmlinux-gdb.py` next to `vmlinux`, which
  gdb auto-loads, giving the `lx-*` commands (`lx-dmesg`, `lx-ps`,
  `lx-symbols`, ...).
* **KASLR off** (`# CONFIG_RANDOMIZE_BASE is not set`, plus `nokaslr` on the
  command line) — a gdb that attached before boot resolves symbols against the
  link-time addresses, which KASLR would invalidate.
* **Frame pointer unwinder** instead of ORC — gdb does not understand ORC's
  custom format, so backtraces would be wrong or truncated.
* **virtio-blk and ext4 built in** — the VM boots with no initramfs at all,
  which removes a whole layer from early-boot debugging.
* **`CONFIG_KGDB` + `CONFIG_KGDB_KDB`** — an alternative to the QEMU stub for
  breaking into an already running guest over the serial line.

## Debugging session

Terminal 1:

```
./run-vm.sh --gdb
```

QEMU starts and stops before the first instruction. The serial console is on
that terminal; `Ctrl-a c` reaches the QEMU monitor, `Ctrl-a x` quits.

Terminal 2:

```
./gdb.sh                      # attach, guest still stopped
./gdb.sh -b start_kernel      # attach, hardware breakpoint, continue
```

Then, in gdb:

```
(gdb) hbreak do_sys_open      # hardware breakpoints are the reliable kind here
(gdb) continue
(gdb) lx-dmesg                # kernel log, no serial console needed
(gdb) lx-ps                   # task list
(gdb) lx-symbols              # symbols for modules the guest has loaded
```

Use `hbreak` rather than `break` for anything that runs before the kernel's
page tables are up; software breakpoints in that window can be overwritten.

`lx-symbols` needs the module `.ko` files to be the ones the guest loaded.
`run-vm.sh` shares the staged modules directory over 9p and the guest mounts it
read-only at `/lib/modules`, so after `./build-kernel.sh` the guest and the host
always agree, with no rootfs rebuild.

To debug a running guest instead of one stopped at reset, use
`./run-vm.sh --gdb-no-wait` and attach whenever you like, or break in from the
serial console with sysrq (`Ctrl-a c`, then `sendkey alt-sysrq-g`) and talk to
kgdb.

## Logging in

Serial console on the terminal running `run-vm.sh`, or:

```
ssh -p 2222 root@localhost
```

Default password `root` (`build-rootfs.sh --password` changes it). This is a
throwaway guest reachable only through the forwarded port on localhost; do not
treat it as hardened.

`run-vm.sh --share DIR` exposes a host directory at `/mnt/host` in the guest,
which is the easiest way to get a reproducer in and a crash log out. With no
`--share`, `$DEBUGVM_OUT/share` is used.

## KASAN

```
./build-kernel.sh --kasan --reconfig
./run-vm.sh --gdb -m 4G
```

Generic KASAN roughly doubles kernel memory use and slows the guest
noticeably, which is why it is a separate fragment.

## Rebuilding

```
./build-kernel.sh                  # incremental; keeps your .config
./build-kernel.sh --reconfig       # regenerate .config from the fragments
./build-kernel.sh --menuconfig     # regenerate, then edit interactively
./build-rootfs.sh --force          # rebuild the rootfs image from scratch
./run-vm.sh --snapshot             # boot without writing to the image
```

Changing the kernel needs no rootfs rebuild: modules reach the guest over the
9p share.

## Troubleshooting

* **`/dev/kvm not usable, falling back to TCG`** — add yourself to the `kvm`
  group, or accept the slowdown. Nothing else changes.
* **Guest hangs right after `Booting the kernel`** — almost always a missing
  console. Check `console=ttyS0,115200n8` is on the command line; the scripts
  pass it, `--append` does not replace it.
* **`VFS: Cannot open root device`** — the rootfs image moved or the method
  changed. `$DEBUGVM_OUT/rootfs.conf`, written by `build-rootfs.sh`, records
  the image path and `root=` device that `run-vm.sh` uses.
* **gdb prints `??` instead of symbols** — the `vmlinux` and the running
  `bzImage` are out of sync. Rebuild and reboot, or check that KASLR really is
  off in the config gdb is reading.
* **`lx-*` commands missing** — `CONFIG_GDB_SCRIPTS` is off, or gdb refused to
  auto-load from the build directory. `gdb.sh` adds the build and source trees
  to `auto-load safe-path` for you.

Further reading: `Documentation/process/debugging/gdb-kernel-debugging.rst` and
`Documentation/dev-tools/kgdb.rst`.

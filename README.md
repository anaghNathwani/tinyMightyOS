# TinyMightyOS 🔥

> A from-scratch Linux distro that goes absolutely unhinged.

```
████████╗██╗███╗   ██╗██╗   ██╗    ███╗   ███╗██╗ ██████╗ ██╗  ██╗████████╗██╗   ██╗
╚══██╔══╝██║████╗  ██║╚██╗ ██╔╝    ████╗ ████║██║██╔════╝ ██║  ██║╚══██╔══╝╚██╗ ██╔╝
   ██║   ██║██╔██╗ ██║ ╚████╔╝     ██╔████╔██║██║██║  ███╗███████║   ██║    ╚████╔╝ 
   ██║   ██║██║╚██╗██║  ╚██╔╝      ██║╚██╔╝██║██║██║   ██║██╔══██║   ██║     ╚██╔╝  
   ██║   ██║██║ ╚████║   ██║       ██║ ╚═╝ ██║██║╚██████╔╝██║  ██║   ██║      ██║   
   ╚═╝   ╚═╝╚═╝  ╚═══╝   ╚═╝       ╚═╝     ╚═╝╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝      ╚═╝   
                                                                   OS — BE UNGOVERNABLE
```

## What is this?

TinyMightyOS is a custom Linux distribution built from scratch. It's tiny, it's mighty, and it goes places other distros are afraid to go.

**Philosophy**: If it compiles, ship it. If it doesn't compile, fix the compiler.

## Architecture

```
TinyMightyOS
├── Kernel: Custom Linux 6.x with PREEMPT_RT + BPF + io_uring + everything
├── Init: tmOS-init — a hand-rolled PID 1 in C (because systemd is for cowards)
├── Shell: tmsh — our own shell, built on ash, with chaos mode
├── Package Manager: might — "might work, might not" (it always works)
├── Init System: runit-inspired services with parallel startup
├── Libc: musl (lean and mean)
├── Apple Silicon: aarch64 support for M1/M2/M3/M4 Macs plus standard Intel/AMD support
├── Install: dual-boot-friendly macOS path with EFI preservation options
└── Branding: maximum aggression
```

## Features

- **Sub-2-second boot** — init is ~400 lines of C, starts services in parallel
- **`might` package manager** — lockfile-free, dependency-resolving, based on static binaries
- **`tmsh` shell** — includes `chaos` builtin that randomizes your PS1 every command
- **Custom kernel config** — tuned for desktop + low latency, BPF enabled everywhere
- **`tmos-doctor`** — system health checker that roasts your hardware
- **`tmos-fetch`** — neofetch clone that's 3x more unhinged
- **Apple Silicon + UEFI + BIOS bootable ISO** — hybrid ISO via GRUB2, Apple EFI path, and legacy boot support
- **Immutable rootfs option** — mount root read-only, overlay tmpfs on top
- **Live ISO + installer** — `tmos-install` guided TUI installer with dual-boot-safe macOS options

## Building

### Requirements

- Linux host (any distro)
- `gcc`, `make`, `bash`, `wget`, `xorriso`, `mksquashfs`
- ~10GB disk space
- A reckless attitude

### Quick Build

```bash
# Build everything for the host architecture
./scripts/build-all.sh

# Build for Apple Silicon / aarch64
TARGET_ARCH=aarch64 ./scripts/build-all.sh

# Build just the ISO
./scripts/build-iso.sh

# Build just the rootfs
./scripts/build-rootfs.sh
```

### Apple Silicon / macOS Dual Boot

TinyMightyOS now includes Apple Silicon support with a dual-boot friendly installer.
The build system can produce aarch64 artifacts and the installer can preserve an existing EFI partition on macOS.

#### Build for Apple Silicon

```bash
TARGET_ARCH=aarch64 ./scripts/build-all.sh
```

#### Write the ISO to USB on macOS

1. Build the ISO on Linux or inside a Linux VM/container accessible from macOS.
2. Copy the ISO to USB with macOS utilities:

```bash
diskutil list
sudo diskutil unmountDisk /dev/diskN
sudo dd if=build/tinymightyos.iso of=/dev/rdiskN bs=4m status=progress
sync
```

3. Alternatively use `balenaEtcher` or `Rufus` on a supported host.

#### Booting on Apple Silicon

- Connect the USB installer.
- Power on the Mac and hold the power button until Startup Options appear.
- Select the external boot device.
- If macOS prevents external booting, enable "Allow booting from external media" in macOS Recovery security settings.

#### Installing alongside macOS

- In the installer, choose the target disk.
- When prompted, enable dual-boot preservation to keep the existing EFI partition.
- The installer will create a new root partition and preserve the macOS firmware boot environment.
- After installation, boot into Startup Options again and choose TinyMightyOS from the external or internal boot list.

#### Intel Macs and other UEFI PCs

- The same ISO works on Intel Macs and x86 UEFI PCs.
- Use `./scripts/run-qemu.sh --uefi` for x86 testing.

```bash
# Test the aarch64 image in QEMU
./scripts/run-qemu.sh --arch=aarch64 --uefi
```

### Outputs

| File | Description |
|------|-------------|
| `build/tinymightyos.iso` | Bootable hybrid ISO |
| `build/rootfs.squashfs` | Compressed root filesystem |
| `build/vmlinuz` | Kernel image |
| `build/initrd.img` | Initramfs |

## Running

```bash
# QEMU (recommended for testing)
./scripts/run-qemu.sh

# With KVM acceleration
./scripts/run-qemu.sh --kvm

# UEFI mode
./scripts/run-qemu.sh --uefi

# Apple Silicon / aarch64 QEMU
./scripts/run-qemu.sh --arch=aarch64 --uefi
```

## Package Manager: `might`

```bash
# Install a package
might install firefox

# Remove a package
might remove bloatware

# Search packages
might search "text editor"

# Update everything
might upgrade

# Show package info
might info neovim

# List installed
might list

# The insane command
might yolo   # installs a random package from the repo
```

## Shell: `tmsh`

TinyMightyOS ships `tmsh` as the default shell. It's POSIX-compatible with extras:

```bash
# Enable chaos mode (PS1 changes every command)
chaos on

# Disable it
chaos off

# Time any command with nanosecond precision
time! ls -la

# Run command in background, notify when done
bg! make -j$(nproc)

# Persistent alias across sessions (auto-saves to ~/.tmsh_aliases)
alias! ll='ls -lahF --color=auto'

# Quick calculator
calc 2^32 + 1
```

## Init System

TinyMightyOS uses `tmOS-init` as PID 1. It:

1. Mounts `/proc`, `/sys`, `/dev` 
2. Reads `/etc/tmos/services/` for service definitions
3. Starts services in dependency-resolved parallel waves
4. Reaps zombies
5. Handles shutdown/reboot signals

Service files are dead simple:

```ini
# /etc/tmos/services/networking.svc
[Service]
Name=networking
Command=/sbin/tmos-netd
After=
Restart=always
RestartDelay=1
```

## Kernel Configuration Highlights

- `CONFIG_PREEMPT_RT=y` — full real-time preemption
- `CONFIG_HZ=1000` — 1000 Hz timer
- `CONFIG_BPF_SYSCALL=y` + `CONFIG_BPF_JIT=y` — eBPF everything
- `CONFIG_IO_URING=y` — async I/O that rips
- `CONFIG_ZRAM=y` — compressed RAM swap
- `CONFIG_BTRFS_FS=y` — because CoW is based
- `CONFIG_SECURITY_LANDLOCK=y` — sandboxing built in
- `CONFIG_IKHEADERS=y` — kernel headers available at runtime
- `CONFIG_FTRACE=y` — tracing for the curious
- `CONFIG_TRANSPARENT_HUGEPAGE=y` — memory performance
- `CONFIG_MEMCG=y` — cgroup memory control

## Directory Structure

```
/
├── bin/          -> /usr/bin (symlink)
├── sbin/         -> /usr/sbin (symlink)  
├── lib/          -> /usr/lib (symlink)
├── usr/
│   ├── bin/      userspace binaries
│   ├── sbin/     system binaries
│   ├── lib/      shared libraries
│   └── share/    architecture-independent data
├── etc/
│   ├── tmos/     TinyMightyOS configuration
│   │   ├── services/   service definitions
│   │   ├── might/      package manager config
│   │   └── release     OS version info
│   ├── passwd
│   ├── group
│   └── hostname
├── boot/         kernel + bootloader
├── dev/          device files
├── proc/         kernel proc fs
├── sys/          sysfs
├── tmp/          tmpfs
├── var/
│   ├── log/      system logs
│   └── run/      runtime state
├── root/         root home
└── home/         user homes
```

## Branding

TinyMightyOS uses the color palette:

- **Primary**: `#FF4500` (OrangeRed — the color of chaos)
- **Secondary**: `#1A1A2E` (Dark navy — the void)
- **Accent**: `#E94560` (Hot pink — because why not)
- **Text**: `#EAEAEA` (Almost white)

## Version

Current: `TinyMightyOS 1.0.0 "Unhinged Ungulate"`

## License

MIT — do whatever you want. We're not your parent.

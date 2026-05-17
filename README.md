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
- No manual dependency installation required: `might install` will bootstrap host tools automatically
- ~10GB disk space
- A reckless attitude

## Multi-Distro Installation on Apple Silicon

The `might install` command provides a unified installation interface for multiple Linux ARM distributions optimized for dual-boot with macOS on Apple Silicon Macs (M1/M2/M3/M4).

### Installation Flow

1. **Clone the repository** — `git clone https://github.com/anaghNathwani/tinymightyos.git && cd tinymightyos`
2. **Run `might install`** — Auto-chmod and present distro menu
3. **Select a distro** — TinyMightyOS, Arch, Ubuntu, Debian, or Fedora
4. **Choose target disk** — Select an internal partition or volume
5. **Confirm and write** — Image is downloaded/built and written to disk
6. **Reboot and select** — Boot into Startup Options and choose your new OS

### Supported Distros

| Distro | Base | Size | Boot Speed | Use Case |
|--------|------|------|------------|----------|
| TinyMightyOS | musl + custom | ~200MB | <2s | Minimal, embedded, experimental |
| Arch Linux ARM | pacman, systemd | ~500MB | ~3-5s | Cutting-edge, rolling release |
| Ubuntu 24.04 LTS | apt, systemd | ~3-5GB | ~5-8s | Stable, LTS, beginner-friendly |
| Debian 12 | apt, systemd | ~2-4GB | ~5-8s | Conservative, stable, server-ready |
| Fedora 40 | dnf, systemd | ~3-5GB | ~5-8s | Latest packages, RPM-based |

### Installation Example

```bash
# Interactive menu
might install

# Direct install (skip menu)
might install ubuntu
```

The installer will:
- Ensure Homebrew is installed on macOS
- Download the distro image if missing
- Present a GUI to select target disk/partition
- Format and write the image
- Preserve existing EFI boot environment

### Post-Installation Boot

**The installer handles the reboot for you.** After writing the disk, a dialog will appear. Click **"Reboot Now"** — the Mac restarts automatically and lands on the startup options screen without any button-holding.

#### Apple Silicon Security Setup (one-time, required)

Apple Silicon Macs must have external booting enabled before a Linux drive appears in the boot picker. The installer triggers this automatically on first run. Once the Mac restarts:

| Step | What to do |
|------|------------|
| 1 | Click **Options** on the startup screen |
| 2 | Select your user account and enter your password |
| 3 | Menu bar: **Utilities → Startup Security Utility** |
| 4 | Click **Security Policy...** |
| 5 | Select **Reduced Security** |
| 6 | Check **"Allow booting from external or removable media"** |
| 7 | Click **OK** → Apple menu → **Restart** |

This is a one-time step. The setting persists across reboots — you will never need to do it again for this Mac.

> **Why can't the script do this automatically?** Apple's Secure Enclave Processor (SEP) cryptographically verifies that security policy changes happen from a hardware-authenticated state. No software call or NVRAM variable can satisfy this check from a running OS — it is a deliberate hardware invariant. The script gets you to the right screen automatically (`nvram auto-boot=false`); the 5-click GUI sequence is the minimum the hardware allows.

#### Booting Linux after setup

After the one-time security step, hold the **Power button** at any startup until "Loading startup options..." appears, then select your Linux drive.

### Switching Between Distros

To boot back to macOS: reboot, hold power, select Macintosh HD.
To boot to another distro: repeat the above with the different distro volume.

### Uninstalling a Distro

1. Boot macOS
2. Open Disk Utility
3. Select the Linux volume/partition
4. Click **Erase**
5. Restore space to APFS container (if needed)

## Single-Distro Building (Advanced)

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

#### macOS Internal Installer (No USB Required)

TinyMightyOS can now install directly from macOS without requiring USB media.
The installer will:

- install missing macOS dependencies via Homebrew,
- build the TinyMightyOS ISO in the repository,
- write the bootable image to an internal target disk or partition,
- preserve the existing EFI boot environment when possible.

Use the repository helper:

```bash
chmod +x ./scripts/might ./macos/macos-install.sh
./scripts/might install
```

On first run the helper also registers `might` into `/usr/local/bin` so later invocations are available globally.

The installer GUI will guide you through disk selection and perform the necessary partition and image operations.

#### Booting on Apple Silicon

The installer automatically reboots into the startup options screen when it finishes. Follow the [Apple Silicon Security Setup](#apple-silicon-security-setup-one-time-required) steps shown above. After that one-time setup, hold the **Power button** at startup to open the boot picker and select your Linux drive.

#### Installing alongside macOS (Dual Boot)

1. Backup your macOS data first. Dual booting involves partitioning the internal storage and can destroy data if the wrong disk is selected.
2. Open Disk Utility and create free space for TinyMightyOS:
   - Select your internal APFS container.
   - Choose "Partition" or "Add Volume" and leave at least 40GB free for TinyMightyOS.
   - If you want a safer path, create a new APFS volume instead of resizing the existing macOS container.
3. Use `diskutil list` in Terminal to identify the target disk and partition layout. The internal Apple Silicon disk is usually `/dev/disk0`.
4. Run the GUI installer and let it build the ISO automatically from the repository:

```bash
chmod +x ./scripts/might ./macos/macos-install.sh
./scripts/might install
```

5. In the installer, choose an internal target disk or partition that is safe to overwrite.
6. The installer will preserve the EFI boot environment and leave macOS intact when you target a secondary volume.
7. After install completes, reboot and hold the power button to open Startup Options.
8. Select TinyMightyOS from the internal boot list to start the new OS.

##### Notes for Apple Silicon dual boot

- If the Linux volume does not appear in the boot picker, the one-time security setup (Reduced Security + external boot) may not have been completed. Follow the steps in the [Apple Silicon Security Setup](#apple-silicon-security-setup-one-time-required) section above.
- To switch between macOS and Linux: hold the **Power button** at startup, then select the desired volume.
- To remove Linux later: boot into macOS Recovery, use Disk Utility to delete the Linux volume, and restore free space to the APFS container.

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
# Clone and install with a single command (auto-chmod included)
git clone https://github.com/anaghNathwani/tinymightyos.git
cd tinymightyos
might install
```

This launches an interactive menu to choose a Linux distro:

1. **TinyMightyOS** — custom lightweight distro optimized for Apple Silicon
2. **Arch Linux ARM** — rolling release, minimal base install
3. **Ubuntu 24.04 LTS ARM** — Debian-based, long-term support
4. **Debian 12 ARM** — stable, conservative release cycle
5. **Fedora 40 ARM** — RPM-based, cutting-edge packages

All distros are configured for dual-boot with macOS on Apple Silicon Macs.

To skip the menu and install directly:

```bash
might install tinymightyos    # or: arch, ubuntu, debian, fedora
```

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

# Launch the installer from the live environment
might install

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

#!/usr/bin/env bash
# build-all.sh — Master build script for TinyMightyOS
# Orchestrates: kernel build, rootfs assembly, initramfs, ISO creation

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
ORANGE='\033[38;5;202m'
RESET='\033[0m'

die()    { echo -e "${RED}[build] FATAL: $*${RESET}" >&2; exit 1; }
info()   { echo -e "${CYAN}[build]${RESET} $*"; }
ok()     { echo -e "${GREEN}[build] ✓${RESET} $*"; }
banner() {
    echo ""
    echo -e "${RED}"
    echo "  ████████╗██╗███╗   ██╗██╗   ██╗ ███╗   ███╗██╗ ██████╗ ██╗  ██╗████████╗██╗   ██╗"
    echo "     ██╔══╝██║████╗  ██║╚██╗ ██╔╝ ████╗ ████║██║██╔════╝ ██║  ██║╚══██╔══╝╚██╗ ██╔╝"
    echo "     ██║   ██║██╔██╗ ██║ ╚████╔╝  ██╔████╔██║██║██║  ███╗███████║   ██║    ╚████╔╝  "
    echo "     ██║   ██║██║╚██╗██║  ╚██╔╝   ██║╚██╔╝██║██║██║   ██║██╔══██║   ██║     ╚██╔╝   "
    echo "     ██║   ██║██║ ╚████║   ██║    ██║ ╚═╝ ██║██║╚██████╔╝██║  ██║   ██║      ██║    "
    echo "     ╚═╝   ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═╝     ╚═╝╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝      ╚═╝    "
    echo -e "${ORANGE}                              BUILD SYSTEM v1.0${RESET}"
    echo ""
}

# ── Config ────────────────────────────────────────────────────────────────────

KERNEL_VERSION="${KERNEL_VERSION:-6.9.0}"
MUSL_VERSION="${MUSL_VERSION:-1.2.5}"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"
JOBS="${JOBS:-$(nproc)}"

BUILD_DIR="${ROOT_DIR}/build"
SRC_DIR="${BUILD_DIR}/src"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
ISO_DIR="${BUILD_DIR}/iso"

LINUX_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${LINUX_TARBALL}"
MUSL_TARBALL="musl-${MUSL_VERSION}.tar.gz"
MUSL_URL="https://musl.libc.org/releases/${MUSL_TARBALL}"
BUSYBOX_TARBALL="busybox-${BUSYBOX_VERSION}.tar.bz2"
BUSYBOX_URL="https://busybox.net/downloads/${BUSYBOX_TARBALL}"

HOST_ARCH="$(uname -m)"
TARGET_ARCH="${TARGET_ARCH:-${HOST_ARCH}}"

case "${TARGET_ARCH}" in
    x86_64)
        KERNEL_ARCH="x86_64"
        GRUB_ISO_TARGET="x86_64-efi"
        ISO_LABEL="TINYMIGHTYOS"
        ;;
    aarch64|arm64)
        TARGET_ARCH="aarch64"
        KERNEL_ARCH="arm64"
        GRUB_ISO_TARGET="arm64-efi"
        ISO_LABEL="TINYMIGHTYOS-AARCH64"
        ;;
    *)
        die "Unsupported TARGET_ARCH: ${TARGET_ARCH}. Supported: x86_64, aarch64"
        ;;
 esac

CROSS_COMPILE="${TARGET_ARCH}-linux-musl-"

# ── Utilities ─────────────────────────────────────────────────────────────────

require_cmd() {
    for cmd in "$@"; do
        command -v "${cmd}" &>/dev/null || die "Required command not found: ${cmd}"
    done
}

download() {
    local url="$1" dest="$2"
    if [[ -f "${dest}" ]]; then
        info "Already downloaded: ${dest##*/}"
        return
    fi
    info "Downloading ${url##*/}..."
    wget -q --show-progress -O "${dest}" "${url}" || \
    curl -L --progress-bar -o "${dest}" "${url}" || \
    die "Failed to download ${url}"
    ok "Downloaded: ${dest##*/}"
}

extract() {
    local archive="$1" dest="$2"
    info "Extracting ${archive##*/}..."
    mkdir -p "${dest}"
    tar -xf "${archive}" -C "${dest}" --strip-components=1
    ok "Extracted to ${dest}"
}

# ── Phase 0: Check requirements ───────────────────────────────────────────────

phase_check() {
    info "Checking build requirements..."
    require_cmd gcc make bash wget tar find install strip
    if ! command -v xorriso &>/dev/null; then
        warn "xorriso not found — ISO build may fail"
    fi
    if ! command -v mksquashfs &>/dev/null; then
        warn "mksquashfs not found — ISO build may fail"
    fi

    # Check for cross compiler when needed
    if [[ "${TARGET_ARCH}" != "${HOST_ARCH}" && ! -z "${CROSS_COMPILE}" ]]; then
        if ! command -v "${CROSS_COMPILE}gcc" &>/dev/null; then
            warn "Cross compiler ${CROSS_COMPILE}gcc not found — will attempt native build if possible"
            CROSS_COMPILE=""
        else
            ok "Cross compiler: ${CROSS_COMPILE}gcc"
        fi
    else
        ok "Host and target arch match: ${HOST_ARCH}"
    fi

    mkdir -p "${BUILD_DIR}" "${SRC_DIR}" "${ROOTFS_DIR}" "${INITRAMFS_DIR}" "${ISO_DIR}"
    ok "Build directories ready"
}

# ── Phase 1: Download sources ─────────────────────────────────────────────────

phase_download() {
    info "Downloading sources..."
    mkdir -p "${SRC_DIR}/downloads"

    download "${LINUX_URL}"    "${SRC_DIR}/downloads/${LINUX_TARBALL}"
    download "${MUSL_URL}"     "${SRC_DIR}/downloads/${MUSL_TARBALL}"
    download "${BUSYBOX_URL}"  "${SRC_DIR}/downloads/${BUSYBOX_TARBALL}"

    ok "All sources downloaded"
}

# ── Phase 2: Build musl libc ──────────────────────────────────────────────────

phase_musl() {
    local src="${SRC_DIR}/musl"
    local prefix="${BUILD_DIR}/musl-cross"

    if [[ -f "${prefix}/lib/libc.so" ]]; then
        ok "musl already built, skipping"
        return
    fi

    extract "${SRC_DIR}/downloads/${MUSL_TARBALL}" "${src}"

    info "Building musl ${MUSL_VERSION}..."
    pushd "${src}" > /dev/null

    local musl_host=""
    local musl_cc="gcc"
    if [[ "${TARGET_ARCH}" == "aarch64" && "${TARGET_ARCH}" != "${HOST_ARCH}" ]]; then
        musl_host="--host=aarch64-linux-musl"
        musl_cc="${CROSS_COMPILE}gcc"
    fi

    ./configure \
        ${musl_host} \
        --prefix="${prefix}" \
        --enable-wrapper=all \
        --syslibdir="${prefix}/lib" \
        CC="${musl_cc}" \
        CFLAGS="-O2 -pipe" \
        >> "${BUILD_DIR}/musl-build.log" 2>&1
    make -j"${JOBS}" >> "${BUILD_DIR}/musl-build.log" 2>&1
    make install      >> "${BUILD_DIR}/musl-build.log" 2>&1
    popd > /dev/null

    ok "musl ${MUSL_VERSION} built"
}

# ── Phase 3: Build kernel ─────────────────────────────────────────────────────

phase_kernel() {
    local src="${SRC_DIR}/linux"

    if [[ -f "${BUILD_DIR}/vmlinuz" ]]; then
        ok "Kernel already built, skipping"
        return
    fi

    extract "${SRC_DIR}/downloads/${LINUX_TARBALL}" "${src}"

    info "Configuring kernel ${KERNEL_VERSION}..."
    pushd "${src}" > /dev/null

    local kernel_config="${ROOT_DIR}/kernel/kernel.config"
    if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
        kernel_config="${ROOT_DIR}/kernel/kernel.config.aarch64"
    fi

    if [[ -f "${kernel_config}" ]]; then
        cp "${kernel_config}" .config
    else
        warn "Kernel config not found: ${kernel_config}. Falling back to default config."
        make ARCH="${KERNEL_ARCH}" defconfig >> "${BUILD_DIR}/kernel-config.log" 2>&1
    fi

    make ARCH="${KERNEL_ARCH}" \
         CROSS_COMPILE="${CROSS_COMPILE}" \
         olddefconfig \
         >> "${BUILD_DIR}/kernel-config.log" 2>&1

    info "Building kernel (this takes a while)..."
    make ARCH="${TARGET_ARCH}" \
         CROSS_COMPILE="${CROSS_COMPILE}" \
         -j"${JOBS}" \
         >> "${BUILD_DIR}/kernel-build.log" 2>&1

    # Copy output
    if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
        cp arch/"${KERNEL_ARCH}"/boot/Image "${BUILD_DIR}/vmlinuz"
    else
        cp arch/"${KERNEL_ARCH}"/boot/bzImage "${BUILD_DIR}/vmlinuz"
    fi
    popd > /dev/null

    ok "Kernel ${KERNEL_VERSION} built: ${BUILD_DIR}/vmlinuz"
}

# ── Phase 4: Build BusyBox ────────────────────────────────────────────────────

phase_busybox() {
    local src="${SRC_DIR}/busybox"

    if [[ -f "${ROOTFS_DIR}/bin/busybox" ]]; then
        ok "BusyBox already built, skipping"
        return
    fi

    extract "${SRC_DIR}/downloads/${BUSYBOX_TARBALL}" "${src}"

    info "Building BusyBox ${BUSYBOX_VERSION} (static + musl)..."
    pushd "${src}" > /dev/null

    make defconfig >> "${BUILD_DIR}/busybox-build.log" 2>&1

    # Static build with musl
    cat >> .config << 'EOF'
CONFIG_STATIC=y
CONFIG_FEATURE_HAVE_RPC=n
EOF

    local cc="${CROSS_COMPILE}gcc"
    [[ -z "${CROSS_COMPILE}" ]] && cc="musl-gcc"
    command -v "${cc}" &>/dev/null || cc="gcc"

    make -j"${JOBS}" \
         CC="${cc}" \
         EXTRA_CFLAGS="-Os -pipe" \
         >> "${BUILD_DIR}/busybox-build.log" 2>&1

    make CONFIG_PREFIX="${ROOTFS_DIR}" install >> "${BUILD_DIR}/busybox-build.log" 2>&1
    popd > /dev/null

    ok "BusyBox ${BUSYBOX_VERSION} installed to ${ROOTFS_DIR}"
}

# ── Phase 5: Build TinyMightyOS tools ─────────────────────────────────────────

phase_tmos_tools() {
    info "Building TinyMightyOS native tools..."

    local cc="${CROSS_COMPILE}gcc"
    command -v "${cc}" &>/dev/null || cc="gcc"

    # tmos-init
    if [[ ! -f "${ROOTFS_DIR}/sbin/tmos-init" ]]; then
        info "Compiling tmos-init..."
        "${cc}" -O2 -static -Wall -Wextra \
            -o "${ROOTFS_DIR}/sbin/tmos-init" \
            "${ROOT_DIR}/rootfs/sbin/tmos-init.c" \
            >> "${BUILD_DIR}/tmos-tools.log" 2>&1 && \
            strip "${ROOTFS_DIR}/sbin/tmos-init" && \
            ok "tmos-init compiled" || \
            warn "tmos-init compile failed (will copy source as-is)"
        cp "${ROOT_DIR}/rootfs/sbin/tmos-init.c" "${ROOTFS_DIR}/sbin/" 2>/dev/null || true
    fi

    # tmsh
    if [[ ! -f "${ROOTFS_DIR}/bin/tmsh" ]]; then
        info "Compiling tmsh..."
        "${cc}" -O2 -Wall -Wextra \
            -o "${ROOTFS_DIR}/bin/tmsh" \
            "${ROOT_DIR}/rootfs/bin/tmsh.c" \
            >> "${BUILD_DIR}/tmos-tools.log" 2>&1 && \
            strip "${ROOTFS_DIR}/bin/tmsh" && \
            ok "tmsh compiled" || \
            warn "tmsh compile failed"
        cp "${ROOT_DIR}/rootfs/bin/tmsh.c" "${ROOTFS_DIR}/bin/" 2>/dev/null || true
    fi

    # install shell scripts
    for script in might tmos-fetch tmos-doctor tmos-install; do
        install -m 755 "${ROOT_DIR}/rootfs/bin/${script}" "${ROOTFS_DIR}/usr/bin/${script}"
        ok "Installed: ${script}"
    done

    ok "TinyMightyOS tools installed"
}

# ── Phase 6: Populate rootfs ──────────────────────────────────────────────────

phase_rootfs() {
    info "Populating rootfs..."

    # Directory structure
    local dirs=(
        usr/bin usr/sbin usr/lib usr/share/misc usr/include
        etc/tmos/services etc/tmos/might
        dev proc sys tmp run
        var/log var/run var/lib/might/installed var/cache/might
        root home boot
        lib lib64
    )
    for d in "${dirs[@]}"; do mkdir -p "${ROOTFS_DIR}/${d}"; done

    # Compatibility symlinks (usrmerge)
    for link in bin sbin lib lib64; do
        rm -f "${ROOTFS_DIR}/${link}"
        ln -sfT "usr/${link}" "${ROOTFS_DIR}/${link}"
    done

    # /etc files
    cp -r "${ROOT_DIR}/rootfs/etc/"* "${ROOTFS_DIR}/etc/" 2>/dev/null || true

    # /etc/tmos/release
    echo 'TinyMightyOS 1.0.0 "Unhinged Ungulate"' > "${ROOTFS_DIR}/etc/tmos/release"

    # /etc/os-release
    cat > "${ROOTFS_DIR}/etc/os-release" << 'EOF'
NAME="TinyMightyOS"
VERSION="1.0.0"
ID=tinymightyos
VERSION_CODENAME="unhinged-ungulate"
PRETTY_NAME="TinyMightyOS 1.0.0 (Unhinged Ungulate)"
HOME_URL="https://github.com/anaghnathwani/tinymightyos"
BUILD_ID=1
EOF

    # /etc/shells
    cat > "${ROOTFS_DIR}/etc/shells" << 'EOF'
/bin/sh
/bin/tmsh
/usr/bin/tmsh
/bin/bash
EOF

    # /etc/passwd
    cat > "${ROOTFS_DIR}/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/tmsh
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
user:x:1000:1000:TinyMightyOS User:/home/user:/bin/tmsh
EOF

    # /etc/group
    cat > "${ROOTFS_DIR}/etc/group" << 'EOF'
root:x:0:
daemon:x:1:
wheel:x:10:user
user:x:1000:
audio:x:29:user
video:x:44:user
input:x:100:user
EOF

    # /etc/hostname
    echo "tinymightyos" > "${ROOTFS_DIR}/etc/hostname"

    # /etc/hosts
    cat > "${ROOTFS_DIR}/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   tinymightyos
::1         localhost ip6-localhost ip6-loopback
EOF

    # /etc/resolv.conf
    cat > "${ROOTFS_DIR}/etc/resolv.conf" << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options edns0 trust-ad
EOF

    # /etc/profile
    cat > "${ROOTFS_DIR}/etc/profile" << 'EOF'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TERM="xterm-256color"
export EDITOR="vi"
export PAGER="less"
export HISTFILE="${HOME}/.tmsh_history"

[ -f /etc/tmos/tmshrc ] && . /etc/tmos/tmshrc
EOF

    # /etc/tmos/tmshrc
    cat > "${ROOTFS_DIR}/etc/tmos/tmshrc" << 'EOF'
# TinyMightyOS tmshrc — sourced for all interactive shells
alias ll='ls -lahF --color=auto'
alias la='ls -lAhF --color=auto'
alias l='ls -lhF --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias df='df -h'
alias du='du -sh'
alias ip='ip --color=auto'
alias might-u='might update && might upgrade'
alias wtf='dmesg | tail -20'

# Show fetch on first login
[ -z "${TMOS_FETCHED}" ] && export TMOS_FETCHED=1 && tmos-fetch 2>/dev/null || true
EOF

    # /etc/tmos/services — example service definitions
    cat > "${ROOTFS_DIR}/etc/tmos/services/networking.svc" << 'EOF'
[Service]
Name=networking
Command=/sbin/tmos-netd
After=
Restart=always
RestartDelay=2
EOF

    cat > "${ROOTFS_DIR}/etc/tmos/services/logging.svc" << 'EOF'
[Service]
Name=logging
Command=/sbin/tmos-logd
After=
Restart=always
RestartDelay=1
EOF

    cat > "${ROOTFS_DIR}/etc/tmos/services/crond.svc" << 'EOF'
[Service]
Name=crond
Command=/usr/sbin/crond -f -l 8
After=logging
Restart=always
RestartDelay=5
EOF

    cat > "${ROOTFS_DIR}/etc/tmos/services/getty-tty1.svc" << 'EOF'
[Service]
Name=getty-tty1
Command=/sbin/agetty --autologin root --noclear tty1 linux
After=networking
Restart=always
RestartDelay=1
EOF

    # /root/.tmshrc
    mkdir -p "${ROOTFS_DIR}/root"
    cat > "${ROOTFS_DIR}/root/.tmshrc" << 'EOF'
# Root's tmshrc
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
chaos on
EOF

    # MOTD
    cat > "${ROOTFS_DIR}/etc/motd" << 'EOF'

  ████████╗██╗███╗   ██╗██╗   ██╗    ███╗   ███╗██╗ ██████╗ ██╗  ██╗████████╗██╗   ██╗
     ██╔══╝██║████╗  ██║╚██╗ ██╔╝    ████╗ ████║██║██╔════╝ ██║  ██║╚══██╔══╝╚██╗ ██╔╝
     ██║   ██║██╔██╗ ██║ ╚████╔╝     ██╔████╔██║██║██║  ███╗███████║   ██║    ╚████╔╝
     ██║   ██║██║╚██╗██║  ╚██╔╝      ██║╚██╔╝██║██║██║   ██║██╔══██║   ██║     ╚██╔╝
     ██║   ██║██║ ╚████║   ██║       ██║ ╚═╝ ██║██║╚██████╔╝██║  ██║   ██║      ██║
     ╚═╝   ╚═╝╚═╝  ╚═══╝   ╚═╝       ╚═╝     ╚═╝╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝      ╚═╝

  Version 1.0.0 "Unhinged Ungulate"
  Type 'tmos-fetch' for system info | 'might yolo' to install something random
  Type 'chaos on' to enable chaos mode | 'tmos-doctor' to check system health

  BE UNGOVERNABLE

EOF

    ok "Rootfs populated"
}

# ── Phase 7: Build initramfs ───────────────────────────────────────────────────

phase_initramfs() {
    info "Building initramfs..."
    local dir="${INITRAMFS_DIR}"

    mkdir -p "${dir}"/{bin,sbin,lib,dev,proc,sys,mnt/root,run,tmp}

    # Copy tmos-init as init
    if [[ -f "${ROOTFS_DIR}/sbin/tmos-init" ]]; then
        cp "${ROOTFS_DIR}/sbin/tmos-init" "${dir}/init"
        chmod +x "${dir}/init"
    else
        # Fallback: simple sh init
        cat > "${dir}/init" << 'INIT_EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
exec /bin/sh
INIT_EOF
        chmod +x "${dir}/init"
    fi

    # Copy busybox
    if [[ -f "${ROOTFS_DIR}/bin/busybox" ]]; then
        cp "${ROOTFS_DIR}/bin/busybox" "${dir}/bin/"
        for cmd in sh ls mount umount grep awk sed find; do
            ln -sf busybox "${dir}/bin/${cmd}" 2>/dev/null || true
        done
    fi

    # Device nodes
    mknod -m 666 "${dir}/dev/null"    c 1 3 2>/dev/null || true
    mknod -m 666 "${dir}/dev/zero"    c 1 5 2>/dev/null || true
    mknod -m 666 "${dir}/dev/random"  c 1 8 2>/dev/null || true
    mknod -m 666 "${dir}/dev/urandom" c 1 9 2>/dev/null || true
    mknod -m 622 "${dir}/dev/console" c 5 1 2>/dev/null || true
    mknod -m 660 "${dir}/dev/tty1"    c 4 1 2>/dev/null || true

    # Pack it
    find "${dir}" | cpio -o -H newc --quiet 2>/dev/null | gzip -9 > "${BUILD_DIR}/initrd.img"
    ok "Initramfs built: ${BUILD_DIR}/initrd.img ($(du -sh "${BUILD_DIR}/initrd.img" | cut -f1))"
}

# ── Phase 8: Build SquashFS ────────────────────────────────────────────────────

phase_squashfs() {
    info "Packing rootfs into SquashFS..."

    if command -v mksquashfs &>/dev/null; then
        mksquashfs "${ROOTFS_DIR}" "${BUILD_DIR}/rootfs.squashfs" \
            -comp zstd -Xcompression-level 19 \
            -noappend -quiet \
            >> "${BUILD_DIR}/squashfs.log" 2>&1
        ok "SquashFS: ${BUILD_DIR}/rootfs.squashfs ($(du -sh "${BUILD_DIR}/rootfs.squashfs" | cut -f1))"
    else
        warn "mksquashfs not found — skipping SquashFS"
    fi
}

# ── Phase 9: Build ISO ────────────────────────────────────────────────────────

phase_iso() {
    info "Building bootable ISO..."

    local iso_root="${ISO_DIR}/iso_root"
    mkdir -p "${iso_root}"/{boot/grub,EFI/BOOT,live}

    # Copy kernel and initrd
    [[ -f "${BUILD_DIR}/vmlinuz"   ]] && cp "${BUILD_DIR}/vmlinuz"   "${iso_root}/boot/"
    [[ -f "${BUILD_DIR}/initrd.img" ]] && cp "${BUILD_DIR}/initrd.img" "${iso_root}/boot/"
    [[ -f "${BUILD_DIR}/rootfs.squashfs" ]] && cp "${BUILD_DIR}/rootfs.squashfs" "${iso_root}/live/"

    # GRUB config
    cat > "${iso_root}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

insmod all_video
insmod gfxterm

menuentry "TinyMightyOS 1.0.0 Live" --class tinymightyos {
    linux  /boot/vmlinuz root=live:CDLABEL=${ISO_LABEL} rd.live.image quiet splash
    initrd /boot/initrd.img
}

menuentry "TinyMightyOS 1.0.0 Live (debug)" --class tinymightyos {
    linux  /boot/vmlinuz root=live:CDLABEL=${ISO_LABEL} rd.live.image debug loglevel=7
    initrd /boot/initrd.img
}

menuentry "Install TinyMightyOS" --class tinymightyos {
    linux  /boot/vmlinuz root=live:CDLABEL=${ISO_LABEL} rd.live.image tmos.install=1 quiet
    initrd /boot/initrd.img
}
EOF

    # Build hybrid ISO
    if command -v xorriso >/dev/null 2>&1 && command -v grub-mkrescue >/dev/null 2>&1; then
        grub-mkrescue --target="${GRUB_ISO_TARGET}" \
            -o "${BUILD_DIR}/tinymightyos.iso" "${iso_root}" \
            --volid="${ISO_LABEL}" \
            >> "${BUILD_DIR}/iso.log" 2>&1
        ok "ISO built: ${BUILD_DIR}/tinymightyos.iso ($(du -sh "${BUILD_DIR}/tinymightyos.iso" | cut -f1))"
    elif [[ "${TARGET_ARCH}" == "x86_64" ]] && command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs \
            -volid "${ISO_LABEL}" \
            -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
            -b boot/grub/i386-pc/eltorito.img \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            -o "${BUILD_DIR}/tinymightyos.iso" \
            "${iso_root}" \
            >> "${BUILD_DIR}/iso.log" 2>&1 || \
        warn "ISO build had issues — check ${BUILD_DIR}/iso.log"
        ok "ISO: ${BUILD_DIR}/tinymightyos.iso"
    else
        warn "Unable to build ISO for ${TARGET_ARCH} without grub-mkrescue and xorriso"
        # Create a placeholder
        echo "TinyMightyOS ISO placeholder — install grub-mkrescue and xorriso to build" \
            > "${BUILD_DIR}/tinymightyos.iso.README"
    fi
}

# ── Print summary ─────────────────────────────────────────────────────────────

phase_summary() {
    echo ""
    echo -e "${ORANGE}══════════════════════════════════════════${RESET}"
    echo -e "${ORANGE}  TinyMightyOS Build Complete${RESET}"
    echo -e "${ORANGE}══════════════════════════════════════════${RESET}"
    echo ""
    for f in vmlinuz initrd.img rootfs.squashfs tinymightyos.iso; do
        local path="${BUILD_DIR}/${f}"
        if [[ -f "${path}" ]]; then
            echo -e "  ${GREEN}✓${RESET} ${f}  $(du -sh "${path}" | cut -f1)"
        else
            echo -e "  ${YELLOW}–${RESET} ${f}  (not built)"
        fi
    done
    echo ""
    echo -e "  ${CYAN}Target architecture:${RESET} ${TARGET_ARCH}"
    echo -e "  ${CYAN}Test with QEMU:${RESET}"
    if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
        echo "    ./scripts/run-qemu.sh --arch=aarch64 --uefi"
    else
        echo "    ./scripts/run-qemu.sh"
    fi
    echo ""
    echo -e "  ${RED}BE UNGOVERNABLE${RESET}"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    banner

    local build_kernel=1
    local download_only=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-kernel)    build_kernel=0 ;;
            --download-only) download_only=1 ;;
            --jobs=*)       JOBS="${1#*=}" ;;
            -j*)            JOBS="${1#-j}" ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done

    phase_check
    phase_download

    [[ ${download_only} -eq 1 ]] && { ok "Downloads complete"; exit 0; }

    phase_musl

    if (( build_kernel )); then
        phase_kernel
    else
        warn "Skipping kernel build (--no-kernel)"
        [[ -f "${BUILD_DIR}/vmlinuz" ]] || \
            cp /boot/vmlinuz* "${BUILD_DIR}/vmlinuz" 2>/dev/null || \
            warn "No vmlinuz found — ISO will be incomplete"
    fi

    phase_busybox
    phase_tmos_tools
    phase_rootfs
    phase_initramfs
    phase_squashfs
    phase_iso
    phase_summary
}

main "$@"

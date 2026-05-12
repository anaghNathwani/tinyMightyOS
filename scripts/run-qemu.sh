#!/usr/bin/env bash
# run-qemu.sh — Launch TinyMightyOS in QEMU

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
RESET='\033[0m'

die()  { echo -e "${RED}[qemu] $*${RESET}" >&2; exit 1; }
info() { echo -e "${CYAN}[qemu]${RESET} $*"; }
warn() { echo -e "${YELLOW}[qemu] WARNING: $*${RESET}" >&2; }
ok()   { echo -e "${GREEN}[qemu] ✓${RESET} $*"; }

# ── Defaults ──────────────────────────────────────────────────────────────────

RAM="${RAM:-2G}"
CPUS="${CPUS:-$(nproc)}"
DISK="${DISK:-}"
USE_KVM=0
USE_UEFI=0
SERIAL_ONLY=0
TARGET_ARCH="${TARGET_ARCH:-x86_64}"
ISO="${BUILD_DIR}/tinymightyos.iso"
VMLINUZ="${BUILD_DIR}/vmlinuz"
INITRD="${BUILD_DIR}/initrd.img"

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kvm)         USE_KVM=1 ;;
        --uefi)        USE_UEFI=1 ;;
        --serial)      SERIAL_ONLY=1 ;;
        --ram=*)       RAM="${1#*=}" ;;
        --cpus=*)      CPUS="${1#*=}" ;;
        --disk=*)      DISK="${1#*=}" ;;
        --iso=*)       ISO="${1#*=}" ;;
        --kernel=*)    VMLINUZ="${1#*=}" ;;
        --initrd=*)    INITRD="${1#*=}" ;;
        --arch=*)      TARGET_ARCH="${1#*=}" ;;
        -h|--help)
            echo "Usage: $0 [--kvm] [--uefi] [--serial] [--ram=2G] [--cpus=N] [--disk=image.qcow2] [--arch=x86_64|aarch64]"
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

# ── Check qemu ────────────────────────────────────────────────────────────────
if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
    QEMU="qemu-system-aarch64"
    command -v "${QEMU}" &>/dev/null || die "${QEMU} not found. Install qemu-system-aarch64"
else
    QEMU="qemu-system-x86_64"
    command -v "${QEMU}" &>/dev/null || die "${QEMU} not found. Install qemu-system-x86_64"
fi

info "TinyMightyOS QEMU launcher"
info "RAM: ${RAM} | CPUs: ${CPUS} | ARCH: ${TARGET_ARCH"
info "RAM: ${RAM} | CPUs: ${CPUS}"

# ── Build QEMU args ───────────────────────────────────────────────────────────
)

if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
    QEMU_ARGS+=( -cpu cortex-a72 )
else
    QEMU_ARGS+=( -cpu host )
fi

(( USE_KVM )) && QEMU_ARGS+=(-enable-kvm) && info "KVM acceleration enabled"

# Machine
if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
    QEMU_ARGS+=(-machine virt)
else
    QEMU_ARGS+=(-machine q35)
fi

(( USE_KVM )) && QEMU_ARGS+=(-enable-kvm) && info "KVM acceleration enabled"

# Machine
QEMU_ARGS+=(-machine q35)

# Display
if (( SERIAL_ONLY )); then
    QEMU_ARGS+=(-nographic -serial mon:stdio)
    info "Serial-only mode"
elseif [[ "${TARGET_ARCH}" == "aarch64" ]]; then
        for p in /usr/share/AAVMF/AAVMF_CODE.fd \
                  /usr/share/aavmf/AAVMF_CODE.fd \
                  /usr/share/edk2/aarch64/AAVMF_CODE.fd; do
            [[ -f "${p}" ]] && ovmf="${p}" && break
        done
    else
        for p in /usr/share/OVMF/OVMF_CODE.fd \
                  /usr/share/ovmf/OVMF.fd \
                  /usr/share/edk2/x64/OVMF_CODE.fd; do
            [[ -f "${p}" ]] && ovmf="${p}" && break
        done
    fi

    if [[ -n "${ovmf}" ]]; then
        QEMU_ARGS+=(-bios "${ovmf}")
        info "UEFI: ${ovmf}"
    else
        warn "UEFI firmware

# UEFI
if (( USE_UEFI )); then
    local ovmf=""
    for p in /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/ovmf/OVMF.fd \
              /usr/share/edk2/x64/OVMF_CODE.fd; do
        [[ -f "${p}" ]] && ovmf="${p}" && break
    done
    if [[ -n "${ovmf}" ]]; then
        QEMU_ARGS+=(-bios "${ovmf}")
        info "UEFI: ${ovmf}"
    else
        warn "OVMF not found — falling back to BIOS"
    fi
fi

# Storage
if [[ -n "${DISK}" ]]; then
    if [[ ! -f "${DISK}" ]]; then
        info "Creating disk image: ${DISK} (20G)"
        qemu-img create -f qcow2 "${DISK}" 20G
    fi
    QEMU_ARGS+=(
        -drive file="${DISK}",format=qcow2,if=virtio,discard=unmap,aio=native,cache.direct=on
    )
    ok "Disk: ${DISK}"
fi

# Boot from ISO if present, else direct kernel boot
if [[ -f "${ISO}" ]]; then
    QEMU_ARGS+=(-cdrom "${ISO}" -boot d)
    ok "Booting from ISO: ${ISO}"
elif [[ -f "${VMLINUZ}" && -f "${INITRD}" ]]; then
    QEMU_ARGS+=(
        -kernel "${VMLINUZ}"
        -initrd "${INITRD}"
        -append "console=ttyS0,115200 console=tty0 rw loglevel=3 quiet"
    )
    ok "Direct kernel boot: ${VMLINUZ}"
else
    die "No ISO or kernel found. Run: ./scripts/build-all.sh first"
fi

# VirtIO RNG (more entropy)
QEMU_ARGS+=(-device virtio-rng-pci)

# Memory balloon
QEMU_ARGS+=(-device virtio-balloon)

# QEMU monitor via telnet
QEMU_ARGS+=(-monitor telnet:127.0.0.1:4444,server,nowait)

echo ""
echo -e "${CYAN}  QEMU command:${RESET}"
echo "  ${QEMU} ${QEMU_ARGS[*]}"
echo ""
echo -e "${GREEN}  Port forwards:${RESET}"
echo "    SSH:  localhost:2222 -> guest:22"
echo "    HTTP: localhost:8080 -> guest:80"
echo ""
echo -e "${CYAN}  QEMU monitor:${RESET} telnet 127.0.0.1 4444"
echo ""
echo -e "${RED}  BE UNGOVERNABLE${RESET}"
echo ""

exec "${QEMU}" "${QEMU_ARGS[@]}"

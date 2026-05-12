#!/usr/bin/env bash
# host-bootstrap.sh — Install required host build tools automatically.
# Required tools: gcc, make, bash, wget, xorriso, mksquashfs

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRED=(gcc make bash wget xorriso mksquashfs)
missing=()

for cmd in "${REQUIRED[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        missing+=("${cmd}")
    fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "[bootstrap] All required host tools are already installed."
    exit 0
fi

echo "[bootstrap] Missing host tools: ${missing[*]}"

run_with_sudo() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo "$@"
        else
            echo "[bootstrap] need root privileges to install packages, but sudo is unavailable." >&2
            exit 1
        fi
    else
        "$@"
    fi
}

install_packages() {
    local manager="$1" packages=("${@:2}")
    echo "[bootstrap] Installing ${packages[*]} via ${manager}."
    case "${manager}" in
        apt-get)
            run_with_sudo apt-get update
            run_with_sudo apt-get install -y "${packages[@]}"
            ;;
        dnf)
            run_with_sudo dnf install -y "${packages[@]}"
            ;;
        yum)
            run_with_sudo yum install -y "${packages[@]}"
            ;;
        pacman)
            run_with_sudo pacman -Sy --noconfirm "${packages[@]}"
            ;;
        zypper)
            run_with_sudo zypper --non-interactive install "${packages[@]}"
            ;;
        apk)
            run_with_sudo apk add --no-cache "${packages[@]}"
            ;;
        brew)
            brew install "${packages[@]}"
            ;;
        *)
            echo "[bootstrap] Unsupported package manager: ${manager}" >&2
            exit 1
            ;;
    esac
}

if command -v apt-get >/dev/null 2>&1; then
    install_packages apt-get gcc make bash wget xorriso squashfs-tools
elif command -v dnf >/dev/null 2>&1; then
    install_packages dnf gcc make bash wget xorriso squashfs-tools
elif command -v yum >/dev/null 2>&1; then
    install_packages yum gcc make bash wget xorriso squashfs-tools
elif command -v pacman >/dev/null 2>&1; then
    install_packages pacman base-devel bash wget xorriso squashfs-tools
elif command -v zypper >/dev/null 2>&1; then
    install_packages zypper gcc make bash wget xorriso squashfs
elif command -v apk >/dev/null 2>&1; then
    install_packages apk build-base bash wget xorriso squashfs-tools
elif command -v brew >/dev/null 2>&1; then
    install_packages brew bash gcc make wget xorriso squashfs
else
    echo "[bootstrap] No supported package manager found. Install the missing tools manually: ${missing[*]}" >&2
    exit 1
fi

# Re-check after attempted installation
failed=()
for cmd in "${REQUIRED[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        failed+=("${cmd}")
    fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
    echo "[bootstrap] Installation finished, but some required tools are still missing: ${failed[*]}" >&2
    exit 1
fi

echo "[bootstrap] Host build tools are now installed."

#!/usr/bin/env bash
# distros/arch/build.sh — Arch Linux ARM installer for macOS dual-boot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISTRO_DIR="$SCRIPT_DIR"
IMAGE_PATH="${REPO_DIR}/build/arch-arm64.tar.zst"
LOG="/tmp/tinymightyos-arch-install.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"
}

die() {
  echo "[arch-install] FATAL: $*" >&2
  log "FATAL: $*"
  exit 1
}

info() {
  echo "[arch-install] $*"
  log "$*"
}

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then
    return
  fi
  info "Homebrew not found. Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || die "Homebrew installation failed"
  if [[ -f /opt/homebrew/bin/brew ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
  elif [[ -f /usr/local/bin/brew ]]; then
    export PATH="/usr/local/bin:$PATH"
  fi
  command -v brew >/dev/null 2>&1 || die "Homebrew did not install correctly"
}

install_brew_deps() {
  ensure_brew
  local packages=(wget curl zstd squashfs)
  info "Installing Homebrew packages: ${packages[*]}"
  brew update >/dev/null 2>&1 || true
  brew install "${packages[@]}" || die "Failed to install Homebrew packages"
  info "Homebrew dependencies installed"
}

download_arch_arm64() {
  if [[ -f "${IMAGE_PATH}" ]]; then
    info "Found existing Arch ARM64 image at ${IMAGE_PATH}"
    return
  fi

  mkdir -p "${REPO_DIR}/build"
  info "Downloading Arch Linux ARM64 image..."
  local url="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.zst"
  wget -q --show-progress -O "${IMAGE_PATH}" "${url}" || die "Failed to download Arch Linux ARM64"
  [[ -f "${IMAGE_PATH}" ]] || die "Image file missing after download"
  info "Downloaded Arch Linux ARM64 image"
}

get_disk_choices() {
  diskutil list | awk '/^\/dev\/disk[0-9]+/ {print $1} /^[[:space:]]+[0-9]+:/ {print $NF}' | sort -u
}

build_disk_list() {
  local disks
  mapfile -t disks < <(get_disk_choices)
  local items=()
  for disk in "${disks[@]}"; do
    disk_info=$(diskutil info "$disk" 2>/dev/null || echo "")
    local size
    size=$(printf '%s\n' "$disk_info" | awk -F: '/Disk Size:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    local internal
    internal=$(printf '%s\n' "$disk_info" | awk -F: '/Internal:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    items+=("${disk} — ${size} — ${internal}")
  done
  printf '%s\n' "${items[@]}"
}

choose_target_disk() {
  local disk_lines
  disk_lines=$(build_disk_list)
  if [[ -z "${disk_lines}" ]]; then
    die "No disks found for installation"
  fi

  local selected
  selected=$(osascript <<APPLESCRIPT
set diskLines to paragraphs of "${disk_lines}"
set chosenDisk to choose from list diskLines with prompt "Select the internal target disk for Arch Linux. This will erase the selected partition." default items {item 1 of diskLines}
if chosenDisk is false then
    return ""
end if
return item 1 of chosenDisk
APPLESCRIPT
  )

  if [[ -z "${selected}" ]]; then
    die "Installation cancelled"
  fi
  awk '{print $1}' <<< "${selected}"
}

format_and_install() {
  local target=$1
  info "Preparing to format and install Arch Linux to ${target}"

  osascript <<APPLESCRIPT
set confirmText to "Arch Linux will be installed to ${target}. This will erase all data on this partition. Continue?"
set answer to display dialog confirmText buttons {"Cancel", "Continue"} default button "Cancel" with icon caution
if button returned of answer is not "Continue" then
    error "User cancelled"
end if
APPLESCRIPT

  if [[ $? -ne 0 ]]; then
    die "Installation cancelled by user"
  fi

  info "Formatting ${target} as ext4..."
  sudo diskutil unmountDisk force "${target}" >/dev/null 2>&1 || true
  sudo mkfs.ext4 "${target}" -F || die "Failed to format ${target}"

  info "Mounting ${target}..."
  local mount_point="/Volumes/arch-install-$$"
  mkdir -p "$mount_point"
  sudo mount -t ext4 "${target}" "$mount_point" || die "Failed to mount ${target}"

  info "Extracting Arch Linux ARM64 to ${target}..."
  sudo tar -xf "${IMAGE_PATH}" -C "$mount_point" || die "Failed to extract Arch Linux"

  info "Unmounting..."
  sudo umount "$mount_point"
  rmdir "$mount_point"

  osascript <<APPLESCRIPT
set successText to "Arch Linux has been installed to ${target}.\n\nRestart the Mac and hold the power button to open Startup Options. Select the Arch Linux volume to complete setup."
display dialog successText buttons {"OK"} default button "OK"
APPLESCRIPT

  info "Arch Linux installation complete"
}

main() {
  info "Starting Arch Linux ARM64 installer"
  install_brew_deps
  download_arch_arm64

  local target
  target=$(choose_target_disk)
  [[ -n "${target}" ]] || die "No target selected"

  format_and_install "${target}"
}

main "$@"

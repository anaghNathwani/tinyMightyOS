#!/usr/bin/env bash
# distros/fedora/build.sh — Fedora 40 ARM installer for macOS dual-boot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGE_PATH="${REPO_DIR}/build/fedora-arm64.img.xz"
LOG="/tmp/tinymightyos-fedora-install.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"
}

die() {
  echo "[fedora-install] FATAL: $*" >&2
  log "FATAL: $*"
  exit 1
}

info() {
  echo "[fedora-install] $*"
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
  local packages=(wget curl xz)
  info "Installing Homebrew packages: ${packages[*]}"
  brew update >/dev/null 2>&1 || true
  brew install "${packages[@]}" || die "Failed to install Homebrew packages"
  info "Homebrew dependencies installed"
}

download_fedora_arm64() {
  if [[ -f "${IMAGE_PATH}" ]]; then
    info "Found existing Fedora ARM64 image at ${IMAGE_PATH}"
    return
  fi

  mkdir -p "${REPO_DIR}/build"
  info "Downloading Fedora 40 ARM64 image..."
  local url="https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/aarch64/images/Fedora-Cloud-Base-40-latest.aarch64.raw.xz"
  wget -q --show-progress -O "${IMAGE_PATH}" "${url}" || die "Failed to download Fedora ARM64"
  [[ -f "${IMAGE_PATH}" ]] || die "Image file missing after download"
  info "Downloaded Fedora ARM64 image"
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
set chosenDisk to choose from list diskLines with prompt "Select the internal target disk for Fedora. This will erase the selected partition." default items {item 1 of diskLines}
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

write_image() {
  local target=$1
  local raw=$(echo "$target" | sed 's/disk/rdisk/')

  osascript <<APPLESCRIPT
set confirmText to "Fedora will be written to ${target}. This will erase all data on this partition. Continue?"
set answer to display dialog confirmText buttons {"Cancel", "Continue"} default button "Cancel" with icon caution
if button returned of answer is not "Continue" then
    error "User cancelled"
end if
APPLESCRIPT

  if [[ $? -ne 0 ]]; then
    die "Installation cancelled by user"
  fi

  info "Preparing ${target}..."
  sudo diskutil unmountDisk force "${target}" >/dev/null 2>&1 || true

  info "Writing Fedora ARM64 image to ${target}..."
  local shell_cmd="xz -d -c '${IMAGE_PATH}' | dd of='${raw}' bs=4m conv=sync status=progress; sync"
  osascript <<APPLESCRIPT
  do shell script "${shell_cmd}" with administrator privileges
APPLESCRIPT

  if [[ $? -ne 0 ]]; then
    die "Failed to write image to ${target}"
  fi

  osascript <<APPLESCRIPT
set successText to "Fedora has been written to ${target}.\n\nRestart the Mac and hold the power button to open Startup Options. Select the Fedora volume to complete setup."
display dialog successText buttons {"OK"} default button "OK"
APPLESCRIPT

  info "Fedora installation complete"
}

main() {
  info "Starting Fedora 40 ARM64 installer"
  install_brew_deps
  download_fedora_arm64

  local target
  target=$(choose_target_disk)
  [[ -n "${target}" ]] || die "No target selected"

  write_image "${target}"
}

main "$@"

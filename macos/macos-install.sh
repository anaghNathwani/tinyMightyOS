#!/usr/bin/env bash
# macos-install.sh — TinyMightyOS macOS GUI installer
# Installs TinyMightyOS from the repository, without requiring USB media.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This helper only runs on macOS." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ISO_PATH="${REPO_DIR}/build/tinymightyos.iso"
LOG="/tmp/tinymightyos-macos-install.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"
}

die() {
  echo "[tmos-install] FATAL: $*" >&2
  log "FATAL: $*"
  exit 1
}

info() {
  echo "[tmos-install] $*"
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
  local packages=(gcc make bash wget xorriso squashfs)
  info "Installing missing Homebrew packages: ${packages[*]}"
  brew update >/dev/null 2>&1 || true
  brew install "${packages[@]}" || die "Failed to install Homebrew packages"
  info "Homebrew dependencies installed"
}

build_iso() {
  if [[ -f "${ISO_PATH}" ]]; then
    info "Found existing ISO at ${ISO_PATH}"
    return
  fi

  info "Building TinyMightyOS ISO from repository..."
  pushd "${REPO_DIR}" >/dev/null
  ./scripts/host-bootstrap.sh || die "Host dependency bootstrap failed"
  TARGET_ARCH=aarch64 ./scripts/build-all.sh || die "ISO build failed"
  popd >/dev/null

  [[ -f "${ISO_PATH}" ]] || die "ISO file still missing after build"
  info "ISO built successfully"
}

get_disk_choices() {
  diskutil list | awk '/^\/dev\/disk[0-9]+/ {print $1} /^[[:space:]]+[0-9]+:/ {print $NF}' | sort -u
}

build_disk_list() {
  local disks
  mapfile -t disks < <(get_disk_choices)
  local items=()
  for disk in "${disks[@]}"; do
    disk_info=$(diskutil info "$disk")
    local size
    size=$(printf '%s\n' "$disk_info" | awk -F: '/Disk Size:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    local internal
    internal=$(printf '%s\n' "$disk_info" | awk -F: '/Internal:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    local protocol
    protocol=$(printf '%s\n' "$disk_info" | awk -F: '/Protocol:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    items+=("${disk} — ${size} — ${protocol} — ${internal}")
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
set chosenDisk to choose from list diskLines with prompt "Select the internal target disk for TinyMightyOS. Choose a partition or disk that is safe to overwrite." default items {item 1 of diskLines}
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

confirm_target() {
  local target=$1
  osascript <<APPLESCRIPT
set confirmText to "TinyMightyOS will be installed to ${target}. Existing data may be overwritten. Continue?"
set answer to display dialog confirmText buttons {"Cancel", "Continue"} default button "Cancel" with icon caution
if button returned of answer is "Continue" then
    return "yes"
else
    return ""
end if
APPLESCRIPT
}

write_iso_to_target() {
  local target=$1
  local raw
  raw=$(echo "$target" | sed 's|/dev/disk|/dev/rdisk|')
  info "Unmounting ${target}"
  diskutil unmountDisk force "$target" >/dev/null 2>&1 || true
  info "Writing ISO to ${target} with administrator privileges"

  local shell_cmd="diskutil unmountDisk force '${target}' >/dev/null 2>&1; dd if='${ISO_PATH}' of='${raw}' bs=4m conv=sync status=progress; sync"
  osascript <<APPLESCRIPT
  do shell script "${shell_cmd}" with administrator privileges
APPLESCRIPT
  if [[ $? -ne 0 ]]; then
    die "Failed to write ISO to ${target}"
  fi

  bless_efi_partition "${target}"
}

bless_efi_partition() {
  local target=$1
  info "Refreshing partition table on ${target}..."
  sleep 2
  diskutil list "$target" >/dev/null 2>&1 || true

  # Find the EFI partition slice on the target disk
  local efi_part
  efi_part=$(diskutil list "$target" 2>/dev/null | awk '/\bEFI\b/ {print $NF; exit}')

  if [[ -z "${efi_part}" ]]; then
    info "No EFI partition detected on ${target} — skipping bless (volume may not appear in boot picker)"
    return
  fi

  # Prepend /dev/ if diskutil printed just the slice name (e.g. disk2s1)
  [[ "${efi_part}" == /dev/* ]] || efi_part="/dev/${efi_part}"

  info "Blessing EFI partition ${efi_part} so macOS boot manager recognises it..."
  local mnt="/Volumes/TMOS_EFI_$$"

  # Run mount + bless + unmount with admin rights so Startup Options shows the entry
  local bless_cmd
  bless_cmd="$(cat <<SH
mkdir -p '${mnt}' \
  && diskutil mount -mountPoint '${mnt}' '${efi_part}' \
  && ( bless --mount '${mnt}' --setBoot --file '${mnt}/EFI/BOOT/BOOTX64.EFI' 2>/dev/null \
       || bless --mount '${mnt}' --setBoot 2>/dev/null ) \
  ; diskutil unmount force '${efi_part}' 2>/dev/null \
  ; rmdir '${mnt}' 2>/dev/null \
  ; true
SH
)"

  osascript <<APPLESCRIPT
  do shell script "${bless_cmd}" with administrator privileges
APPLESCRIPT

  info "EFI partition blessed — TinyMightyOS should now appear in Startup Options / boot picker"
}

main() {
  info "Starting macOS TinyMightyOS installer"
  install_brew_deps
  build_iso

  local target
  target=$(choose_target_disk)
  [[ -n "${target}" ]] || die "No target selected"

  local confirmed
  confirmed=$(confirm_target "${target}")
  if [[ -z "${confirmed}" ]]; then
    die "Installation cancelled by user"
  fi

  write_iso_to_target "${target}"

  osascript <<APPLESCRIPT
set successText to "TinyMightyOS has been written to ${target}.\n\nRestart the Mac and hold the power button to open Startup Options. Select the TinyMightyOS volume to continue installation."
display dialog successText buttons {"OK"} default button "OK"
APPLESCRIPT
}

main "$@"

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
  local packages=(gcc make bash wget xorriso squashfs grub)
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

list_target_disks() {
  # Returns lines of: /dev/diskN<TAB>SIZE<TAB>NAME
  diskutil list -plist external physical 2>/dev/null | \
    python3 - <<'PYEOF'
import plistlib, sys, subprocess, os

raw = sys.stdin.buffer.read()
try:
    pl = plistlib.loads(raw)
except Exception:
    sys.exit(0)

for node in pl.get("WholeDisks", []):
    info_raw = subprocess.run(
        ["diskutil", "info", "-plist", node],
        capture_output=True
    ).stdout
    try:
        info = plistlib.loads(info_raw)
    except Exception:
        continue
    dev  = info.get("DeviceNode", node)
    size = info.get("TotalSize", 0)
    name = info.get("MediaName") or info.get("IORegistryEntryName") or "Unknown"
    gb   = size / 1_000_000_000
    print(f"{dev}\t{gb:.1f} GB\t{name}")
PYEOF
}

choose_target_disk() {
  local disk_lines
  disk_lines=$(list_target_disks)

  if [[ -z "$disk_lines" ]]; then
    die "No external/physical disks found. Plug in the target drive and try again."
  fi

  # Build parallel arrays: display labels and device nodes
  local labels=() devs=()
  while IFS=$'\t' read -r dev size name; do
    devs+=("$dev")
    labels+=("$dev  —  $size  —  $name")
  done <<< "$disk_lines"

  # Pass label list to AppleScript as a comma-separated string
  local as_list
  as_list=$(printf '"%s",' "${labels[@]}")
  as_list="${as_list%,}"  # strip trailing comma

  local chosen_label
  chosen_label=$(osascript <<APPLESCRIPT
set diskList to {${as_list}}
set chosen to choose from list diskList with prompt "Choose the disk to install TinyMightyOS onto.

WARNING: The selected disk will be completely wiped." with title "TinyMightyOS Installer" OK button name "Select" cancel button name "Cancel"
if chosen is false then
  return ""
end if
return item 1 of chosen
APPLESCRIPT
  )

  if [[ -z "$chosen_label" ]]; then
    die "Installation cancelled"
  fi

  # Match chosen label back to device node
  local i
  for i in "${!labels[@]}"; do
    if [[ "${labels[$i]}" == "$chosen_label" ]]; then
      echo "${devs[$i]}"
      return
    fi
  done

  die "Could not match selection to a disk device"
}

confirm_target() {
  local target=$1
  osascript - "$target" <<'APPLESCRIPT' 2>/dev/null
on run argv
  set tgt to item 1 of argv
  set confirmText to "⚠️  FINAL WARNING" & return & return & "You are about to ERASE all data on:" & return & return & tgt & return & return & "This cannot be undone. Are you absolutely sure?"
  try
    set answer to display dialog confirmText buttons {"Cancel", "Erase and Install"} default button "Cancel" with icon stop
    if button returned of answer is "Erase and Install" then
      return "yes"
    end if
  on error
    return ""
  end try
  return ""
end run
APPLESCRIPT
}

write_iso_to_target() {
  local target=$1
  local raw
  raw=$(echo "$target" | sed 's|/dev/disk|/dev/rdisk|')
  info "Unmounting ${target}"
  diskutil unmountDisk force "$target" >/dev/null 2>&1 || true
  info "Writing ISO to ${target} with administrator privileges"

  osascript - "$ISO_PATH" "$target" <<'APPLESCRIPT'
on run argv
  set isoPath to item 1 of argv
  set targetDisk to item 2 of argv
  set shell_cmd to "dd if=" & quoted form of isoPath & " of=" & quoted form of targetDisk & " bs=4m status=progress && sync"
  do shell script shell_cmd with administrator privileges
end run
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
  [[ -n "${target}" ]] || die "No disk selected"

  local confirmed
  confirmed=$(confirm_target "${target}")
  if [[ -z "${confirmed}" ]]; then
    die "Installation cancelled by user"
  fi

  write_iso_to_target "${target}"

  osascript - "$target" <<'APPLESCRIPT'
on run argv
  set tgt to item 1 of argv
  set successText to "TinyMightyOS has been written to:" & return & return & tgt & return & return & "You can now remove the drive and boot from it."
  display dialog successText buttons {"OK"} default button "OK"
end run
APPLESCRIPT
}

main "$@"

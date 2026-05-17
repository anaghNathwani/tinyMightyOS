#!/usr/bin/env bash
# distros/arch/build.sh — Arch Linux ARM installer for Apple Silicon Macs
#
# Disk layout written to the target:
#   Partition 1: EFI System Partition (FAT32, 512 MiB) — systemd-boot + kernel + initrd
#   Partition 2: Linux root filesystem (ext4)           — Arch Linux ARM userland
#
# macOS cannot write ext4 natively.  We use mke2fs -d (e2fsprogs ≥ 1.43) to
# create and populate the ext4 partition directly from a staging directory,
# with no FUSE driver or mount required.
#
# Security policy:
#   Apple Silicon's SEP signs the LocalPolicy.  Downgrading security (needed to
#   allow booting from external media) can only be performed from 1TR — the
#   hardware-verified "One True Recovery" entered by holding the physical power
#   button, or from a paired software-launched recoveryOS.  The SEP detects
#   this state; no NVRAM variable or software call can fake the signal.
#
#   This installer handles the security step by:
#     1. Detecting whether external-boot is already enabled (bputil -d).
#     2. If not: setting nvram auto-boot=false so that the VERY NEXT reboot
#        lands on the startup-options screen (identical to holding the power
#        button) — no manual gestures required.
#     3. Presenting step-by-step instructions for the 5 Startup Security
#        Utility clicks needed once in recoveryOS.
#   After that one-time setup, the Arch drive appears in the boot picker
#   automatically on every subsequent boot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGE_PATH="${REPO_DIR}/build/arch-arm64.tar.gz"
ARCH_STAGING="${REPO_DIR}/build/arch-rootfs-staging"
LOG="/tmp/tinymightyos-arch-install.log"

export PATH="/opt/homebrew/sbin:/usr/local/sbin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"; }
die()  { echo "[arch-install] FATAL: $*" >&2; log "FATAL: $*"; exit 1; }
info() { echo "[arch-install] $*"; log "$*"; }

cleanup() {
  [[ -d "${ARCH_STAGING}" ]] && sudo rm -rf "${ARCH_STAGING}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Homebrew + dependencies ──────────────────────────────────────────────────

ensure_brew() {
  command -v brew >/dev/null 2>&1 && return
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Homebrew installation failed"
  for p in /opt/homebrew/bin /usr/local/bin; do
    [[ -f "${p}/brew" ]] && export PATH="${p}:${PATH}" && break
  done
  command -v brew >/dev/null 2>&1 || die "Homebrew install failed"
}

find_mke2fs() {
  local candidates=(
    "$(brew --prefix e2fsprogs 2>/dev/null)/sbin/mke2fs"
    "$(brew --prefix 2>/dev/null)/sbin/mke2fs"
    "/opt/homebrew/sbin/mke2fs"
    "/usr/local/sbin/mke2fs"
  )
  local c
  for c in "${candidates[@]}"; do [[ -x "${c}" ]] && echo "${c}" && return 0; done
  command -v mke2fs 2>/dev/null && return 0
  return 1
}

install_brew_deps() {
  ensure_brew
  local need=()
  command -v sgdisk >/dev/null 2>&1 || need+=(gptfdisk)
  command -v wget   >/dev/null 2>&1 || need+=(wget)
  find_mke2fs >/dev/null 2>&1       || need+=(e2fsprogs)

  if (( ${#need[@]} > 0 )); then
    info "Installing: ${need[*]}"
    brew update -q 2>/dev/null || true
    brew install "${need[@]}" || die "brew install failed: ${need[*]}"
    export PATH="/opt/homebrew/sbin:/usr/local/sbin:${PATH}"
  fi
}

# ── Security-state detection ─────────────────────────────────────────────────
#
# bputil -d can be called from normal macOS (read-only; no auth needed).
# The "Allowed boot media" field in its output tells us whether external boot
# is already enabled.  Value (1) = internal only; (3) = internal + removable.

check_external_boot_enabled() {
  local policy
  # bputil -d requires root on some macOS versions, try both
  policy=$(sudo bputil -d 2>/dev/null || bputil -d 2>/dev/null || true)
  [[ -z "${policy}" ]] && return 1   # can't tell — assume not enabled

  # "internal and removable" or "(3)" indicates external boot is permitted
  echo "${policy}" | grep -qiE \
    "internal and removable|Permissive Security|(Allowed boot media.*[^0-9]3[^0-9])" \
  && return 0 || return 1
}

# ── Download ─────────────────────────────────────────────────────────────────

download_arch_arm64() {
  if [[ -f "${IMAGE_PATH}" ]]; then
    info "Found cached Arch ARM64 tarball at ${IMAGE_PATH}"
    return
  fi
  mkdir -p "${REPO_DIR}/build"
  info "Downloading Arch Linux ARM64 (~500 MB)..."
  local url="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
  wget -q --show-progress -O "${IMAGE_PATH}" "${url}" \
    || die "Download failed — check your internet connection"
  [[ -f "${IMAGE_PATH}" ]] || die "Tarball missing after download"
  info "Download complete"
}

# ── Disk selection ────────────────────────────────────────────────────────────

get_disk_choices() {
  diskutil list physical | awk '/^\/dev\/disk[0-9]+/ {print $1}' | sort -u
}

build_disk_labels() {
  local labels=() devs=()
  while IFS= read -r disk; do
    local dinfo size location
    dinfo=$(diskutil info "$disk" 2>/dev/null || true)
    size=$(printf '%s\n' "$dinfo" \
      | awk -F: '/Disk Size:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' \
      | awk '{print $1,$2}')
    location=$(printf '%s\n' "$dinfo" \
      | awk -F: '/Device Location:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')
    labels+=("${disk}  (${size:-unknown size}, ${location:-unknown location})")
    devs+=("$disk")
  done < <(get_disk_choices)
  local i
  for i in "${!labels[@]}"; do printf '%s\t%s\n' "${labels[$i]}" "${devs[$i]}"; done
}

choose_target_disk() {
  local label_dev_lines
  label_dev_lines=$(build_disk_labels)
  local labels=() devs=()
  while IFS=$'\t' read -r label dev; do
    labels+=("$label"); devs+=("$dev")
  done <<< "$label_dev_lines"

  local custom_opt="Enter custom path..."
  local as_list
  as_list=$(printf '"%s",' "${labels[@]}" "$custom_opt")
  as_list="${as_list%,}"

  local chosen_label
  chosen_label=$(osascript <<APPLESCRIPT
set diskList to {${as_list}}
set chosenDisk to choose from list diskList with prompt "Select the target disk for Arch Linux ARM.

WARNING: The entire selected disk will be erased and repartitioned." with title "TinyMightyOS — Arch Linux Installer" OK button name "Select" cancel button name "Cancel"
if chosenDisk is false then
  return ""
end if
return item 1 of chosenDisk
APPLESCRIPT
  )
  [[ -n "${chosen_label}" ]] || die "Installation cancelled"

  if [[ "${chosen_label}" == "${custom_opt}" ]]; then
    local custom_path
    custom_path=$(osascript <<'APPLESCRIPT'
set dlg to display dialog "Enter the target disk path (e.g. /dev/disk2):" default answer "" with title "TinyMightyOS — Arch Linux Installer" buttons {"Cancel", "OK"} default button "OK"
if button returned of dlg is "Cancel" then return ""
return text returned of dlg
APPLESCRIPT
    )
    [[ -n "${custom_path}" ]] || die "Installation cancelled"
    echo "${custom_path}"
    return
  fi

  local i
  for i in "${!labels[@]}"; do
    [[ "${labels[$i]}" == "${chosen_label}" ]] && echo "${devs[$i]}" && return
  done
  die "Could not map selection to a device node"
}

# ── Partitioning ──────────────────────────────────────────────────────────────

wait_for_part_nodes() {
  local disk=$1
  local deadline=$(( $(date +%s) + 20 ))
  until [[ -e "${disk}s1" && -e "${disk}s2" ]]; do
    (( $(date +%s) < deadline )) \
      || die "Timed out waiting for ${disk}s1 / ${disk}s2.  Try replugging the drive."
    sleep 1
  done
}

partition_disk() {
  local disk=$1
  info "Unmounting ${disk}..."
  diskutil unmountDisk force "${disk}" >/dev/null 2>&1 || true

  info "Writing GPT to ${disk}..."
  sudo sgdisk --zap-all "${disk}" \
    || die "sgdisk failed — ensure Terminal has Full Disk Access in System Settings → Privacy & Security."

  sudo sgdisk \
    --new=1:0:+512M \
    --typecode=1:EF00 \
    --change-name=1:"EFI System" \
    "${disk}" || die "Could not create EFI partition"

  sudo sgdisk \
    --new=2:0:0 \
    --typecode=2:8300 \
    --change-name=2:"Linux Root" \
    "${disk}" || die "Could not create Linux root partition"

  info "Partition table:"
  sudo sgdisk --print "${disk}" 2>/dev/null \
    | grep -E '^[[:space:]]+[0-9]' \
    | while IFS= read -r l; do info "  ${l}"; done || true

  sleep 2
  diskutil unmountDisk force "${disk}" >/dev/null 2>&1 || true
  wait_for_part_nodes "${disk}"
  info "Partitions ready"
}

get_partition_guid() {
  local disk=$1 part_num=$2
  sudo sgdisk --info="${part_num}" "${disk}" 2>/dev/null \
    | awk '/Partition unique GUID:/ { print tolower($4) }'
}

# ── Rootfs extraction ─────────────────────────────────────────────────────────

extract_rootfs() {
  info "Extracting Arch Linux ARM rootfs to staging area..."
  [[ -d "${ARCH_STAGING}" ]] && sudo rm -rf "${ARCH_STAGING}"
  mkdir -p "${ARCH_STAGING}"

  # macOS bsdtar cannot create Linux device nodes; exclude virtual-filesystem
  # dirs — the kernel repopulates them at boot (devtmpfs / procfs / sysfs).
  # --numeric-owner preserves numeric UID/GID for mke2fs -d.
  sudo tar -xzf "${IMAGE_PATH}" \
    -C "${ARCH_STAGING}" \
    --exclude=./dev \
    --exclude=./proc \
    --exclude=./sys \
    --exclude=./run \
    --numeric-owner \
    2>/dev/null \
  || sudo tar -xzf "${IMAGE_PATH}" \
    -C "${ARCH_STAGING}" \
    --exclude=./dev \
    --exclude=./proc \
    --exclude=./sys \
    --exclude=./run \
    2>/dev/null \
  || die "Failed to extract ${IMAGE_PATH}"

  sudo mkdir -p \
    "${ARCH_STAGING}/dev" \
    "${ARCH_STAGING}/proc" \
    "${ARCH_STAGING}/sys" \
    "${ARCH_STAGING}/run" \
    "${ARCH_STAGING}/boot/efi"

  info "Rootfs extracted ($(du -sh "${ARCH_STAGING}" 2>/dev/null | cut -f1))"
}

# ── Bootloader ────────────────────────────────────────────────────────────────

mount_efi_partition() {
  local efi_part=$1
  local mp
  mp=$(diskutil info "${efi_part}" \
    | awk -F: '/Mount Point:/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')

  if [[ -z "${mp}" || "${mp}" == "(null)" || ! -d "${mp}" ]]; then
    diskutil mount "${efi_part}" >/dev/null 2>&1 \
      || sudo mount -t msdos "${efi_part}" /Volumes/ARCH_EFI \
      || die "Cannot mount EFI partition ${efi_part}"
    mp=$(diskutil info "${efi_part}" \
      | awk -F: '/Mount Point:/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
  fi

  [[ -n "${mp}" && -d "${mp}" ]] || die "EFI partition mounted but mount point unreadable"
  echo "${mp}"
}

setup_bootloader() {
  local disk=$1 root_partuuid=$2
  local efi_part="${disk}s1"

  local efi_mount
  efi_mount=$(mount_efi_partition "${efi_part}")
  info "EFI partition at: ${efi_mount}"

  local sdboot
  sdboot=$(find "${ARCH_STAGING}" -path "*/systemd/boot/efi/systemd-bootaa64.efi" \
    2>/dev/null | head -1 || true)
  [[ -n "${sdboot}" ]] \
    || die "systemd-bootaa64.efi not found — Arch ARM tarball may be incomplete or truncated"
  info "Bootloader binary: ${sdboot}"

  local kernel
  kernel=$(find "${ARCH_STAGING}/boot" -maxdepth 1 \
    \( -name "Image" -o -name "Image.gz" \
       -o -name "vmlinuz-linux-aarch64" -o -name "vmlinuz-*" \) \
    2>/dev/null | head -1 || true)
  [[ -n "${kernel}" ]] || die "No kernel image found in staging/boot/"
  info "Kernel: $(basename "${kernel}")"

  local initrd
  initrd=$(find "${ARCH_STAGING}/boot" -maxdepth 1 \
    -name "initramfs-*.img" -not -name "*fallback*" \
    2>/dev/null | head -1 || true)
  [[ -n "${initrd}" ]] \
    || initrd=$(find "${ARCH_STAGING}/boot" -maxdepth 1 \
      -name "initramfs-*.img" 2>/dev/null | head -1 || true)
  [[ -n "${initrd}" ]] \
    && info "Initramfs: $(basename "${initrd}")" \
    || info "WARNING: No initramfs found — system may not boot"

  sudo mkdir -p "${efi_mount}/EFI/BOOT"
  sudo mkdir -p "${efi_mount}/loader/entries"
  sudo mkdir -p "${efi_mount}/arch"

  # Apple Silicon firmware scans EFI/BOOT/BOOTAA64.EFI as the fallback loader
  sudo cp "${sdboot}" "${efi_mount}/EFI/BOOT/BOOTAA64.EFI"
  sudo cp "${kernel}" "${efi_mount}/arch/Image"
  [[ -n "${initrd}" ]] && sudo cp "${initrd}" "${efi_mount}/arch/initramfs.img"

  sudo tee "${efi_mount}/loader/loader.conf" > /dev/null << 'LOADEREOF'
default arch
timeout 5
console-mode max
editor no
LOADEREOF

  {
    printf "title   Arch Linux ARM\n"
    printf "linux   /arch/Image\n"
    [[ -f "${efi_mount}/arch/initramfs.img" ]] && printf "initrd  /arch/initramfs.img\n"
    printf "options root=PARTUUID=%s rw console=tty0 console=ttyAMA0,115200 loglevel=7\n" \
      "${root_partuuid}"
  } | sudo tee "${efi_mount}/loader/entries/arch.conf" > /dev/null

  # ── Write a recovery helper script to the EFI partition.
  # This file is readable from recoveryOS Terminal so the user can copy-paste
  # the exact bputil invocation without transcribing it from memory.
  sudo tee "${efi_mount}/arch-recovery-setup.sh" > /dev/null << 'RECOVERY_HELPER'
#!/bin/bash
# TinyMightyOS — Apple Silicon security setup helper
# Run this from recoveryOS Terminal:
#   bash /Volumes/EFI\ System/arch-recovery-setup.sh
#
# What this does: sets Reduced Security and enables external-media booting,
# which are required for the Arch Linux drive to appear in the boot picker.

set -e
echo ""
echo "=== TinyMightyOS Security Setup ==="
echo ""
echo "Restoring normal auto-boot behavior..."
/usr/sbin/nvram auto-boot=true 2>/dev/null || true

echo ""
echo "Setting Reduced Security — you will be prompted for your macOS credentials."
echo ""
# -g = Reduced Security (allows global Apple signatures; needed for external boot)
# Boot requirement: software-launched recoveryOS OR 1TR — both satisfy this
bputil -g
echo ""
echo "Done. Now enable external booting in Startup Security Utility:"
echo "  Utilities menu → Startup Security Utility"
echo "  → Security Policy..."
echo "  → Check 'Allow booting from external or removable media'"
echo "  → OK"
echo ""
echo "Then: Apple menu → Restart"
echo "Hold the Power button when restarting to open the boot picker."
RECOVERY_HELPER

  diskutil unmount "${efi_part}" >/dev/null 2>&1 || true
  info "Bootloader and recovery helper installed"
}

# ── Format + write ────────────────────────────────────────────────────────────

format_and_install() {
  local disk=$1
  local efi_part="${disk}s1"
  local root_part="${disk}s2"
  local raw_root
  raw_root=$(echo "${root_part}" | sed 's|/dev/disk|/dev/rdisk|')

  info "Reading partition GUIDs..."
  local efi_guid root_guid
  efi_guid=$(get_partition_guid "${disk}" 1)
  root_guid=$(get_partition_guid "${disk}" 2)
  [[ -n "${root_guid}" ]] || die "Failed to read root partition GUID"
  info "Root PARTUUID: ${root_guid}"

  extract_rootfs

  info "Writing /etc/fstab..."
  sudo tee "${ARCH_STAGING}/etc/fstab" > /dev/null << FSTABEOF
# Generated by TinyMightyOS Arch installer
PARTUUID=${root_guid}  /         ext4  defaults,noatime  0 1
PARTUUID=${efi_guid}   /boot/efi vfat  umask=0077        0 2
FSTABEOF

  info "Formatting EFI partition as FAT32..."
  diskutil unmountDisk force "${disk}" >/dev/null 2>&1 || true
  sudo newfs_msdos -F 32 -v "EFI" "${efi_part}" \
    || die "newfs_msdos failed on ${efi_part}"

  local mke2fs_bin
  mke2fs_bin=$(find_mke2fs) || die "mke2fs not found — run: brew install e2fsprogs"
  info "Creating ext4 root filesystem — this takes 10–20 minutes on USB drives..."
  sudo "${mke2fs_bin}" \
    -t ext4 \
    -L "arch_root" \
    -E "lazy_itable_init=1,lazy_journal_init=1" \
    -d "${ARCH_STAGING}" \
    "${raw_root}" \
    || die "mke2fs failed — check ${LOG} for details"
  info "Root filesystem written"

  setup_bootloader "${disk}" "${root_guid}"
}

# ── Security setup — automatic reboot path ────────────────────────────────────
#
# Setting nvram auto-boot=false causes the Mac to land on the "Loading startup
# options" screen on the very next reboot — the same screen reached by holding
# the physical power button.  No manual gestures required.
# From that screen the user clicks Options → recoveryOS → 5 clicks in the
# Startup Security Utility GUI.  That's the minimum the SEP allows from outside
# a running OS.

trigger_startup_options_reboot() {
  local disk=$1

  # Confirm the user is ready to reboot
  local choice
  choice=$(osascript << 'APPLESCRIPT'
set msg to "Installation complete!" & return & return & \
  "Your Mac needs one security change before Arch Linux appears in the boot picker." & return & return & \
  "Click 'Reboot Now' — your Mac will restart and show the startup options screen automatically." & return & return & \
  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return & \
  "WHAT TO DO AFTER REBOOT (screenshot this)" & return & \
  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return & return & \
  "1.  Click 'Options' on the startup screen" & return & \
  "2.  Select your user account and enter your password" & return & \
  "3.  In the menu bar: Utilities → Startup Security Utility" & return & \
  "4.  Click 'Security Policy...'" & return & \
  "5.  Select 'Reduced Security'" & return & \
  "6.  Check 'Allow booting from external or removable media'" & return & \
  "7.  Click OK → Apple menu → Restart" & return & return & \
  "After step 7, hold the Power button to open the boot picker." & return & \
  "Your Arch Linux drive will be listed."
set result to display dialog msg buttons {"Cancel", "Reboot Now"} default button "Reboot Now" with title "Almost Done — One Security Step Required" with icon note
return button returned of result
APPLESCRIPT
  )

  [[ "${choice}" == "Reboot Now" ]] || {
    info "Reboot deferred — run this script again to trigger it, or follow the manual steps."
    show_manual_instructions "${disk}"
    return
  }

  info "Setting startup-options mode for next boot..."
  # auto-boot=false makes iBoot show the startup options picker instead of
  # auto-booting.  This is persistent until the Mac boots once normally, or
  # until someone sets nvram auto-boot=true.
  sudo nvram auto-boot=false \
    || info "WARNING: Could not set auto-boot NVRAM — you may need to hold the Power button manually."

  info "Rebooting into startup options..."
  sleep 1
  sudo reboot
  # The process is replaced; nothing below here runs.
}

show_manual_instructions() {
  local disk=$1
  osascript - "${disk}" << 'APPLESCRIPT'
on run argv
  set tgt to item 1 of argv
  set msg to "To finish setup manually:" & return & return & \
    "1.  Shut down your Mac" & return & \
    "2.  Hold the Power button until 'Loading startup options...' appears" & return & \
    "3.  Click Options" & return & \
    "4.  Authenticate with your user account" & return & \
    "5.  Utilities menu → Startup Security Utility" & return & \
    "6.  Security Policy... → Reduced Security" & return & \
    "7.  Check 'Allow booting from external or removable media'" & return & \
    "8.  OK → Apple menu → Restart" & return & return & \
    "Hold Power at startup to see the boot picker — select your Arch drive." & return & return & \
    "A helper script is also on the EFI partition at:" & return & \
    "  /Volumes/EFI System/arch-recovery-setup.sh" & return & \
    "(Run it from recoveryOS Terminal to set Reduced Security automatically.)"
  display dialog msg buttons {"OK"} default button "OK" with title "Manual Setup Instructions"
end run
APPLESCRIPT
}

# ── Already-configured path ───────────────────────────────────────────────────

show_all_done() {
  local disk=$1
  osascript - "${disk}" << 'APPLESCRIPT'
on run argv
  set tgt to item 1 of argv
  set msg to "Arch Linux ARM installed to " & tgt & "." & return & return & \
    "External booting is already enabled on this Mac." & return & return & \
    "Restart your Mac and hold the Power button." & return & \
    "Select your Arch Linux drive from the boot picker."
  display dialog msg buttons {"OK"} default button "OK" with title "Installation Complete"
end run
APPLESCRIPT
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  info "TinyMightyOS — Arch Linux ARM installer for Apple Silicon"
  install_brew_deps
  download_arch_arm64

  # Check security state before doing anything else, so we know whether
  # the post-install reboot path is needed.
  local external_boot_ok=0
  if check_external_boot_enabled; then
    info "External boot already enabled — no recovery reboot needed after install"
    external_boot_ok=1
  else
    info "External boot not yet enabled — will trigger startup-options reboot after install"
  fi

  local target
  target=$(choose_target_disk)
  [[ -n "${target}" ]] || die "No target selected"

  local confirmed
  confirmed=$(osascript - "${target}" << 'APPLESCRIPT'
on run argv
  set tgt to item 1 of argv
  set msg to "WARNING" & return & return & \
    "ALL data on " & tgt & " will be permanently erased and the disk" & return & \
    "will be repartitioned for Arch Linux ARM." & return & return & \
    "Installation takes 10-20 minutes. Continue?"
  try
    set ans to display dialog msg buttons {"Cancel", "Erase & Install"} default button "Cancel" with icon stop
    if button returned of ans is "Erase & Install" then return "yes"
  on error
    return ""
  end try
  return ""
end run
APPLESCRIPT
  )
  [[ "${confirmed}" == "yes" ]] || die "Installation cancelled by user"

  partition_disk "${target}"
  format_and_install "${target}"

  if (( external_boot_ok )); then
    show_all_done "${target}"
  else
    trigger_startup_options_reboot "${target}"
  fi

  info "Done. See ${LOG} for the full install log."
}

main "$@"

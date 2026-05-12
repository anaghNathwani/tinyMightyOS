#!/usr/bin/env bash
# distro-orchestrator.sh — Multi-distro installer orchestrator for macOS M-series Macs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DISTROS=(
  "tinymightyos:TinyMightyOS (custom lightweight Linux)"
  "arch:Arch Linux ARM (rolling release)"
  "ubuntu:Ubuntu 24.04 LTS ARM (Debian-based)"
  "debian:Debian 12 ARM (stable)"
  "fedora:Fedora 40 ARM (RPM-based)"
)

show_distro_menu() {
  echo ""
  echo "╔════════════════════════════════════════════════════╗"
  echo "║     TinyMightyOS Multi-Distro Installer for macOS   ║"
  echo "╚════════════════════════════════════════════════════╝"
  echo ""
  echo "Select a Linux distribution to install:"
  echo ""

  for i in "${!DISTROS[@]}"; do
    IFS=':' read -r code name <<< "${DISTROS[$i]}"
    echo "  $((i+1)). ${name}"
  done

  echo ""
}

select_distro_interactive() {
  show_distro_menu

  local choice
  read -p "Enter your choice (1-${#DISTROS[@]}): " choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#DISTROS[@]} )); then
    echo "Invalid choice. Exiting." >&2
    exit 1
  fi

  local selected_index=$((choice - 1))
  local distro_spec="${DISTROS[$selected_index]}"
  IFS=':' read -r distro_code _ <<< "$distro_spec"
  echo "$distro_code"
}

validate_distro() {
  local distro="$1"
  for spec in "${DISTROS[@]}"; do
    IFS=':' read -r code _ <<< "$spec"
    if [[ "$code" == "$distro" ]]; then
      return 0
    fi
  done
  echo "ERROR: Unknown distro '$distro'. Supported: tinymightyos, arch, ubuntu, debian, fedora" >&2
  exit 1
}

launch_distro_installer() {
  local distro="$1"
  local distro_dir="${REPO_DIR}/distros/${distro}"

  if [[ ! -d "$distro_dir" ]]; then
    echo "ERROR: Distro directory not found at ${distro_dir}" >&2
    exit 1
  fi

  if [[ ! -f "${distro_dir}/build.sh" ]]; then
    echo "ERROR: Installer script not found at ${distro_dir}/build.sh" >&2
    exit 1
  fi

  chmod +x "${distro_dir}/build.sh"
  exec "${distro_dir}/build.sh"
}

main() {
  local distro="${1:-}"

  if [[ -z "$distro" ]]; then
    distro=$(select_distro_interactive)
  else
    validate_distro "$distro"
  fi

  echo ""
  echo "Starting ${distro} installer..."
  echo ""

  launch_distro_installer "$distro"
}

main "$@"

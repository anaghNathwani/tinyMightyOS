#!/usr/bin/env bash
# build-iso.sh — Build just the ISO from an existing rootfs + kernel
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/build-all.sh" --no-kernel --no-download "$@"

#!/usr/bin/env bash
# build-rootfs.sh — Build just the rootfs (no kernel compilation)
# Useful for iterating on userspace without waiting for a kernel build.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."

exec "${SCRIPT_DIR}/build-all.sh" --no-kernel "$@"

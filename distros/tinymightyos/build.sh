#!/usr/bin/env bash
# distros/tinymightyos/build.sh — TinyMightyOS ARM installer for macOS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

exec "${REPO_DIR}/macos/macos-install.sh"

#!/bin/bash
# Install only the network initializer, without rebuilding or flashing rootfs.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run as root to install the network initializer." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/overlay/usr/local/bin/dlcvcam-init.sh"
bash -n "$SOURCE"
install -m 0755 "$SOURCE" /usr/local/bin/dlcvcam-init.sh
echo "Network initializer installed. Existing connections are unchanged; verify on the next reboot."

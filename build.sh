#!/usr/bin/env bash
# Build .c4z driver packages for Frigate Control4 drivers.
# A .c4z is just a ZIP file with the driver contents at the root.
#
# Usage: ./build.sh [camera|nvr|all]
# Output: control4/dist/*.c4z

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"

build_driver() {
    local name="$1"
    local src="$SCRIPT_DIR/${name}-driver"
    local out="$DIST_DIR/frigate-${name}.c4z"

    echo "Building frigate-${name}.c4z..."
    rm -f "$out"
    mkdir -p "$DIST_DIR"

    (cd "$src" && zip -r "$out" driver.xml driver.lua www/ -x '*.DS_Store' '.*')

    # Include icons/ only if the directory has files
    if [ -d "$src/icons" ] && [ "$(ls -A "$src/icons" 2>/dev/null)" ]; then
        (cd "$src" && zip -r "$out" icons/ -x '*.DS_Store' '.*')
    fi

    echo "  -> $out ($(du -h "$out" | cut -f1))"
}

case "${1:-all}" in
    camera)  build_driver camera ;;
    nvr)     build_driver nvr ;;
    all)     build_driver camera; build_driver nvr ;;
    *)       echo "Usage: $0 [camera|nvr|all]"; exit 1 ;;
esac

echo "Done."

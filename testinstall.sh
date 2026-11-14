#!/usr/bin/env bash

# Backward-compatible name retained for existing users of the old installer.
# Keep one installer implementation so install.sh and testinstall.sh cannot
# diverge as the desktop evolves.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/install.sh" "$@"

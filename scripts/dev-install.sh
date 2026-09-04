#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ID="dev.zed.keep-notes"
TARGET="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"

mkdir -p "$(dirname "$TARGET")"
rm -rf "$TARGET"
cp -a "$ROOT" "$TARGET"

omarchy plugin validate "$TARGET"
omarchy-shell shell rescanPlugins
omarchy plugin enable "$PLUGIN_ID"

echo "Installed local development copy at $TARGET"

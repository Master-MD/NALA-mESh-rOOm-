#!/usr/bin/env bash
set -Eeuo pipefail

echo "🔎 Suche nach ComfyUI Models..."

# 1) Standard macOS App Support Pfad
APP_SUPPORT="$HOME/Library/Application Support/ComfyUI/models"
if [ -d "$APP_SUPPORT" ]; then
    echo "✅ Gefunden: $APP_SUPPORT"
    ls -lh "$APP_SUPPORT"
    echo
fi

# 2) Falls ZIP/Standalone-Version irgendwo liegt
find "$HOME" -type d -name models 2>/dev/null | grep -i "comfy" | while read -r dir; do
    echo "✅ Gefunden: $dir"
    ls -lh "$dir"
    echo
done

# 3) Hinweis, falls nichts gefunden wurde
echo "👉 Falls nichts angezeigt wird, starte die ComfyUI App einmal,
dann legt sie den models-Ordner automatisch an."
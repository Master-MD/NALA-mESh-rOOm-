#!/bin/zsh
set -euo pipefail

say_do() { echo "› $*"; eval "$@"; }

echo "=== ComfyUI Desktop Doctor ==="

# 0) Wo liegt was?
APP_SUP="$HOME/Library/Application Support"
DESK_DIR="$APP_SUP/ComfyUI Desktop"
ALT_TODESK="$APP_SUP/ToDesktop"
LOG_DIR_CAND=(
  "$DESK_DIR/logs"
  "$HOME/Library/Logs/ComfyUI Desktop"
  "$ALT_TODESK/logs"
)
CONF="$DESK_DIR/config.json"

echo "-- Pfade:"
echo "   Desktop dir: $DESK_DIR"
echo "   Alt ToDesktop: $ALT_TODESK"

# 1) Port 8188 freimachen (nur falls belegt)
echo "-- Port 8188 prüfen/killen (falls belegt)"
if lsof -nP -iTCP:8188 -sTCP:LISTEN >/dev/null 2>&1; then
  PIDS=$(lsof -nP -iTCP:8188 -sTCP:LISTEN | awk 'NR>1{print $2}' | sort -u)
  [[ -n "${PIDS:-}" ]] && say_do "kill -9 $PIDS" || true
else
  echo "   8188 war frei."
fi

# 2) Logs anzeigen (wenn existieren)
echo "-- Logs (falls vorhanden):"
FOUND_LOG="0"
for d in "${LOG_DIR_CAND[@]}"; do
  if [[ -d "$d" ]]; then
    FOUND_LOG="1"
    echo "   -> $d"
    tail -n 120 "$d"/latest.log 2>/dev/null || true
  fi
done
[[ "$FOUND_LOG" == "0" ]] && echo "   (keine Desktop-Logs gefunden – ok)"

# 3) Eingebaute Python-Umgebung löschen (wird neu angelegt)
if [[ -d "$DESK_DIR/python_env" ]]; then
  echo "-- Desktop-Python-Env löschen (wird neu erstellt)…"
  rm -rf "$DESK_DIR/python_env"
else
  echo "-- Keine Desktop-Python-Env gefunden – überspringe."
fi

# 4) Custom-Nodes temporär deaktivieren (mögliche Crash-Ursache)
if [[ -d "$DESK_DIR/ComfyUI/custom_nodes" ]]; then
  echo "-- Custom-Nodes temporär deaktivieren…"
  mv "$DESK_DIR/ComfyUI/custom_nodes" "$DESK_DIR/ComfyUI/custom_nodes.disabled" 2>/dev/null || true
fi

# 5) Ausstehende/kaputte Auto-Update-Caches bereinigen (ToDesktop Runtime)
if [[ -d "$ALT_TODESK/runtime/downloader" ]]; then
  echo "-- ToDesktop-Update-Cache aufräumen…"
  rm -rf "$ALT_TODESK/runtime/downloader"/* || true
fi
if [[ -d "$ALT_TODESK/runtime/cache/updates" ]]; then
  rm -rf "$ALT_TODESK/runtime/cache/updates"/* || true
fi

# 6) Optional: Desktop auf Remote-Backend 127.0.0.1:8188 stellen
# (Nur, wenn du deinen Comfy-Server separat startest, z.B. mit meshroom-pro 8188)
if [[ -f "$CONF" ]]; then
  echo "-- config.json patchen (useRemote=true, URL=127.0.0.1:8188)"
  TMP="$CONF.tmp"
  # jq ist nicht garantiert vorhanden, daher sed-Fallback
  if command -v jq >/dev/null 2>&1; then
    jq '.server.useRemote=true | .server.remoteUrl="http://127.0.0.1:8188"' "$CONF" > "$TMP" && mv "$TMP" "$CONF"
  else
    # Minimal sed: fügt/ersetzt Schlüssel (funktioniert auch wenn sie noch fehlen)
    if ! grep -q '"server"' "$CONF" 2>/dev/null; then
      # nacktes JSON anlegen, falls defekt/leer
      echo '{"server":{}}' > "$CONF"
    fi
    sed -i '' 's/"useRemote":[^,}]*/"useRemote": true/g; s|"remoteUrl":[^,}]*|"remoteUrl": "http://127.0.0.1:8188"|g' "$CONF" || true
    # Falls keys fehlen:
    if ! grep -q '"useRemote"' "$CONF"; then
      sed -i '' 's|"server": *{|"server":{"useRemote": true,|g' "$CONF" || true
    fi
    if ! grep -q '"remoteUrl"' "$CONF"; then
      sed -i '' 's|"server": *{|"server":{"remoteUrl": "http://127.0.0.1:8188",|g' "$CONF" || true
    fi
  fi
else
  echo "-- Keine config.json gefunden (wird von Desktop erstellt, sobald er das erste Mal startet)."
fi

echo
echo "=== Fertig. Nächste Schritte ==="
echo "1) Starte jetzt testweise NUR den Backend-Server:"
echo "   meshroom-pro 8188"
echo "   (oder: ~/ComfyMeshroom/tools/start_comfy_server.sh 8188)"
echo "2) Danach ComfyUI Desktop öffnen. Wenn 'Use remote' aktiv ist,"
echo "   verbindet sich die App auf http://127.0.0.1:8188."
echo "3) Falls die App weiterhin crasht: Logs erneut prüfen (siehe oben)."
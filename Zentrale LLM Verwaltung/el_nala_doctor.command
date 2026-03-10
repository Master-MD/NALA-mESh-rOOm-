#!/bin/zsh
set -euo pipefail

PORT="${1:-8188}"
DESKTOP_DIR="$HOME/Library/Application Support/ComfyUI Desktop"
VENV_PY="$HOME/ComfyMeshroom/venv/bin/python"
MAIN_PY="$HOME/ComfyMeshroom/ComfyUI/main.py"
LOG="/tmp/comfy_backend.log"

echo "=== El-Nala Comfy Doctor ==="
echo "-- Ziel: lokaler Backend http://127.0.0.1:${PORT} + Desktop Remote-Mode"

# 1) Nur user-schreibbare Skripte patchen (kein /usr/local/bin!)
for f in "$HOME/ComfyMeshroom/tools/start_comfy_server.sh"; do
  [[ -f "$f" && -w "$f" ]] && perl -i -pe 's/\s*--enable-cors-all\s*//g' "$f" && echo "  * Gepatcht: ${f##*/}" || true
done

# 2) Port räumen
pids=$(lsof -nP -iTCP:${PORT} -sTCP:LISTEN -t || true)
if [[ -n "${pids:-}" ]]; then
  echo "  * Kille Port ${PORT}: $pids"
  kill -9 $pids || true
else
  echo "  * Port ${PORT} war frei."
fi

# 3) Desktop -> Remote
mkdir -p "$DESKTOP_DIR"
CONFIG="$DESKTOP_DIR/config.json"
cat > "$CONFIG" <<JSON
{"server":{"useRemote":true,"remoteUrl":"http://127.0.0.1:${PORT}"}}
JSON
echo "  * Desktop config.json geschrieben"

# 4) Backend starten (bevorzugt Venv)
echo "  * Starte Backend (127.0.0.1:${PORT}) …"
: > "$LOG"
export PYTORCH_ENABLE_MPS_FALLBACK=1
export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0

if [[ -x "$VENV_PY" && -f "$MAIN_PY" ]]; then
  nohup "$VENV_PY" "$MAIN_PY" --listen 127.0.0.1 --port "$PORT" >>"$LOG" 2>&1 &
  SPID=$!
elif command -v meshroom-pro >/dev/null 2>&1; then
  nohup meshroom-pro "$PORT" >>"$LOG" 2>&1 &
  SPID=$!
else
  echo "[ERR] Kein Startpfad gefunden. Prüfe $MAIN_PY bzw. meshroom-pro."
  exit 1
fi

# 5) Bis zu 45s auf Listener warten
ok=0
for i in {1..45}; do
  if lsof -nP -iTCP:${PORT} -sTCP:LISTEN >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done

if [[ "$ok" -eq 1 ]]; then
  echo "  * OK: Backend lauscht → http://127.0.0.1:${PORT}"
  open "http://127.0.0.1:${PORT}" 2>/dev/null || true
else
  echo "[ERR] Backend-Start unbestätigt. Log folgt:"
  tail -n 80 "$LOG" || true
fi

# 6) Desktop öffnen (falls vorhanden)
open -a "ComfyUI Desktop" 2>/dev/null || echo "  * Desktop-App nicht gefunden (ok)."

echo "=== Fertig. ==="
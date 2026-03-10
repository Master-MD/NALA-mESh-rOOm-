#!/bin/zsh
set -euo pipefail
PORT="${1:-8188}"
export PYTORCH_ENABLE_MPS_FALLBACK=1
export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0
VENV_PY="$HOME/ComfyMeshroom/venv/bin/python"
MAIN_PY="$HOME/ComfyMeshroom/ComfyUI/main.py"

# evtl. altes --enable-cors-all entfernen
for f in "/usr/local/bin/meshroom-pro" "$HOME/ComfyMeshroom/tools/start_comfy_server.sh"; do
  [[ -f "$f" ]] && perl -i -pe 's/\s*--enable-cors-all\s*//g' "$f" || true
done

if [[ -x "$VENV_PY" && -f "$MAIN_PY" ]]; then
  exec "$VENV_PY" "$MAIN_PY" --listen 127.0.0.1 --port "$PORT"
elif command -v meshroom-pro >/dev/null 2>&1; then
  exec meshroom-pro "$PORT"
else
  echo "[ERR] Starte fehl: Venv oder meshroom-pro nicht gefunden."
  exit 1
fi
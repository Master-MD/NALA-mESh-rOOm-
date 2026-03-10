#!/bin/zsh
set -euo pipefail
BASE="$HOME/ComfyMeshroom"
VENV="$BASE/venv"
REPO="$BASE/ComfyUI"
PORT="${1:-8188}"
export PYTORCH_ENABLE_MPS_FALLBACK=1
export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0
test -x "$VENV/bin/python" || { echo "[ERR] Venv fehlt: $VENV"; exit 2; }
test -d "$REPO/.git"       || { echo "[ERR] ComfyUI Repo fehlt: $REPO"; exit 2; }
source "$VENV/bin/activate"
git -C "$REPO" pull --ff-only
pip install -r "$REPO/requirements.txt" --upgrade
mkdir -p "$REPO/custom_nodes"
[ -d "$REPO/custom_nodes/ComfyUI-Manager" ] || git clone https://github.com/ltdrdata/ComfyUI-Manager "$REPO/custom_nodes/ComfyUI-Manager"
[ -d "$REPO/custom_nodes/ComfyUI_essentials" ] || git clone https://github.com/cubiq/ComfyUI_essentials "$REPO/custom_nodes/ComfyUI_essentials"
lsof -nP -iTCP:$PORT -sTCP:LISTEN | awk 'NR>1{print $2}' | xargs -r kill -9
nohup "$VENV/bin/python" "$REPO/main.py" --listen 127.0.0.1 --port "$PORT" >/tmp/comfy_backend.log 2>&1 &
sleep 2
pgrep -f "ComfyUI/main.py" >/dev/null && echo "[OK] Läuft. Log: /tmp/comfy_backend.log" || { echo "[ERR] Start fehlgeschlagen"; tail -n 100 /tmp/comfy_backend.log || true; exit 1; }

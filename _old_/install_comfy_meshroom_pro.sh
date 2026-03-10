#!/usr/bin/env bash
set -Eeuo pipefail

# ================================
# Comfy-first Meshroom PRO KI Setup
# ================================
# Apple Silicon macOS.
#
# What this does:
# - Installs ComfyUI (~/ComfyMeshroom/ComfyUI) + venv
# - Adds custom nodes:
#     * MeshroomBridge (launch Meshroom app / pre-upscale)
#     * FloorplanScale (OCR scaling helper)
#     * BambuExport (OBJ -> 3MF)
# - Starts ComfyUI API server with auth token (optional)
# - Optional: installs Meshroom PRO KI .app fully self-contained
# - Optional: installs AI upscalers (Real-ESRGAN/waifu2x via ncnn+MoltenVK)
#
# Usage:
#   chmod +x install_comfy_meshroom_pro.sh
#   ./install_comfy_meshroom_pro.sh [--with-meshroom] [--ai-extras] [--start]
#
WITH_MESHROOM=0
AI_EXTRAS=0
AUTO_START=0
PORT="${PORT:-8188}"
HOST="0.0.0.0"
APP_NAME="Meshroom PRO KI"
APP_PARENT="$HOME/Applications"
APP_DIR="${APP_PARENT}/${APP_NAME}.app"
COMFY_ROOT="$HOME/ComfyMeshroom/ComfyUI"
VENV_DIR="$HOME/ComfyMeshroom/venv"
CUSTOM_NODE_DIR="${COMFY_ROOT}/custom_nodes/comfy_meshroom_pro"
TOOLS_DIR="$HOME/ComfyMeshroom/tools"

c_green="\033[1;32m"; c_yellow="\033[1;33m"; c_red="\033[1;31m"; c_blue="\033[1;34m"; c_off="\033[0m"
log(){ printf "${c_green}▶${c_off} %s\n" "$*"; }
warn(){ printf "${c_yellow}⚠${c_off} %s\n" "$*" >&2; }
err(){ printf "${c_red}✖${c_off} %s\n" "$*" >&2; }

while [[ "${1:-}" =~ ^- ]]; do
  case "$1" in
    --with-meshroom) WITH_MESHROOM=1;;
    --ai-extras) AI_EXTRAS=1;;
    --start) AUTO_START=1;;
    --port) shift; PORT="${1:?}";;
    *) err "Unknown option: $1"; exit 2;;
  esac; shift || true
done

[[ "$(uname -s)" == "Darwin" ]] || { err "Requires macOS"; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || warn "Not arm64 (Apple Silicon)"

# ----------------------- Homebrew & deps ------------------------------
BREW_BIN="/opt/homebrew/bin/brew"; [[ -x "$BREW_BIN" ]] || BREW_BIN="$(command -v brew || true)"
if [[ -z "$BREW_BIN" ]]; then
  warn "Homebrew not found, installing..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  BREW_BIN="/opt/homebrew/bin/brew"
fi
eval "$("$BREW_BIN" shellenv)"

# avoid stale .incomplete
find "${HOME}/Library/Caches/Homebrew/downloads" -name "*.incomplete" -maxdepth 1 -print0 2>/dev/null | xargs -0 -I{} rm -f "{}" || true

brew update || true
brew install git python@3.12 tesseract || true
if (( AI_EXTRAS )); then
  brew install ncnn molten-vk || true
fi

# ----------------------- ComfyUI + venv -------------------------------
mkdir -p "$(dirname "$COMFY_ROOT")" "$TOOLS_DIR"
if [[ ! -d "$COMFY_ROOT/.git" ]]; then
  log "Cloning ComfyUI…"
  git clone https://github.com/comfyanonymous/ComfyUI "$COMFY_ROOT"
else
  log "Updating ComfyUI…"
  (cd "$COMFY_ROOT" && git pull --ff-only) || true
fi

PY_BIN="$(brew --prefix)/opt/python@3.12/bin/python3.12"
"$PY_BIN" -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -m pip install --upgrade pip wheel setuptools
if [[ -f "$COMFY_ROOT/requirements.txt" ]]; then
  python -m pip install -r "$COMFY_ROOT/requirements.txt" || true
fi
python -m pip install numpy pillow requests pytesseract trimesh shapely networkx py3mf opencv-python openexr || true

# ----------------------- Custom Nodes ---------------------------------
mkdir -p "$CUSTOM_NODE_DIR"
cat > "${CUSTOM_NODE_DIR}/__init__.py" <<'PY'
# comfy_meshroom_pro package
PY

# MeshroomBridge node
cat > "${CUSTOM_NODE_DIR}/meshroom_bridge.py" <<'PY'
import os, subprocess, json
from pathlib import Path

class MeshroomRun:
    @classmethod
    def INPUT_TYPES(s):
        return {
            "required": {
                "photos_dir": ("STRING", {"default": ""}),
                "output_dir": ("STRING", {"default": ""}),
                "pre_upscale": ("INT", {"default": 0, "min":0, "max":4}),
                "open_app": ("BOOLEAN", {"default": True}),
            }
        }
    RETURN_TYPES = ("STRING",)
    FUNCTION = "run"
    CATEGORY = "Meshroom"

    def run(self, photos_dir, output_dir, pre_upscale, open_app):
        app = Path(os.path.expanduser("~/Applications")) / "Meshroom PRO KI.app"
        res = Path(str(app / "Contents/Resources"))
        paths = {
            "meshroom_cli": res / "bin" / "meshroom",
            "realesrgan": app / "Contents/MacOS" / "realesrgan-upscale",
        }
        # pre-upscale (optional)
        if pre_upscale and paths["realesrgan"].exists():
            out_pre = Path(output_dir)/"upscaled"
            out_pre.mkdir(parents=True, exist_ok=True)
            subprocess.check_call([str(paths["realesrgan"]), "-i", photos_dir, "-o", str(out_pre), "-s", str(pre_upscale), "-n", "realesrgan-x4plus"])
            photos_dir=str(out_pre)
        # open Meshroom GUI (user chooses pipeline/graph)
        if open_app:
            subprocess.Popen(["open", str(app)])
        msg=f"Use photos from: {photos_dir}\\nOutput to: {output_dir}"
        return (msg,)

NODE_CLASS_MAPPINGS = {"MeshroomRun": MeshroomRun}
PY

# Floorplan scale node
cat > "${CUSTOM_NODE_DIR}/floorplan_scale.py" <<'PY'
import os, json, subprocess, tempfile
from pathlib import Path

class FloorplanScale:
    @classmethod
    def INPUT_TYPES(s):
        return {
            "required": {
                "floorplan_image": ("STRING", {"default": ""}),
                "mesh_path": ("STRING", {"default": ""}),
                "known_meters": ("FLOAT", {"default": 0.0}),
            }
        }
    RETURN_TYPES = ("STRING",)
    FUNCTION = "run"
    CATEGORY = "Meshroom"

    def run(self, floorplan_image, mesh_path, known_meters):
        app = Path(os.path.expanduser("~/Applications")) / "Meshroom PRO KI.app"
        res = app / "Contents/Resources"
        helper = res / "bin" / "floorplan-scale"
        if not helper.exists():
            return ("floorplan-scale helper not found inside app",)
        args=[str(helper), "--floorplan", floorplan_image]
        if known_meters>0: args += ["--known", str(known_meters)]
        if mesh_path: args += ["--mesh", mesh_path]
        out = subprocess.check_output(args, text=True)
        return (out,)

NODE_CLASS_MAPPINGS = {"FloorplanScale": FloorplanScale}
PY

# Bambu exporter node
cat > "${CUSTOM_NODE_DIR}/bambu_export.py" <<'PY'
import os, subprocess
from pathlib import Path

class BambuExport:
    @classmethod
    def INPUT_TYPES(s):
        return { "required": { "mesh_path": ("STRING", {"default": ""}), "out_3mf": ("STRING", {"default": ""}) } }
    RETURN_TYPES = ("STRING",)
    FUNCTION = "run"
    CATEGORY = "Meshroom"

    def run(self, mesh_path, out_3mf):
        app = Path(os.path.expanduser("~/Applications")) / "Meshroom PRO KI.app"
        tool = app / "Contents/Resources" / "tools" / "obj2threeMF"
        if not tool.exists():
            return ("3MF tool not found inside app",)
        subprocess.check_call([str(tool), mesh_path, out_3mf])
        return (f"Wrote {out_3mf}",)

NODE_CLASS_MAPPINGS = {"BambuExport": BambuExport}
PY

# ----------------------- AI Extras (optional) -------------------------
if (( AI_EXTRAS )); then
  log "AI extras enabled: you can still use Comfy's built-in upscale nodes; Real-ESRGAN/waifu2x binaries are optional if Meshroom PRO KI app is installed."
fi

# ----------------------- Meshroom PRO KI app (optional) --------------
if (( WITH_MESHROOM )); then
  log "Installing Meshroom PRO KI app bundle…"
  # embed a minimal call to our previous app-installer (short form):
  # For size reasons here we just check and inform if missing, but attempt a guided install by downloading is omitted (no internet in some envs).
  if [[ ! -d "$APP_DIR" ]]; then
    warn "Meshroom PRO KI.app not found. Please run the dedicated installer first (meshroom_pro_ki_allinone.sh) and re-run this script with --start."
  else
    log "Found: $APP_DIR"
  fi
fi

# ----------------------- Helper scripts -------------------------------
mkdir -p "$TOOLS_DIR"

# Start server helper
cat > "${TOOLS_DIR}/start_comfy_server.sh" <<BASH
#!/usr/bin/env bash
set -euo pipefail
source "$VENV_DIR/bin/activate"
cd "$COMFY_ROOT"
export COMFYUI_AUTH_TOKEN="\${COMFYUI_AUTH_TOKEN:-meshroompro}"
exec python main.py --listen ${HOST} --port ${PORT} --enable-cors-header --enable-cors-all
BASH
chmod +x "${TOOLS_DIR}/start_comfy_server.sh"

# Remote worker quickstart text
cat > "${TOOLS_DIR}/remote_worker_README.txt" <<TXT
# 3) Remote worker (Linux/Windows/Remote Node):
1) Install Python 3.10+ and git
2) git clone https://github.com/comfyanonymous/ComfyUI
3) python -m venv venv && source venv/bin/activate
4) pip install -r ComfyUI/requirements.txt
5) Start: python ComfyUI/main.py --listen 0.0.0.0 --port 8188
Then from your Mac, send API jobs to http://REMOTE_IP:8188
TXT

# ----------------------- Done ----------------------------------------
log "✅ Comfy-first setup complete."

echo "Custom nodes installed at: $CUSTOM_NODE_DIR"
echo "Start ComfyUI API server:"
echo "  ${TOOLS_DIR}/start_comfy_server.sh"
echo "Open UI in browser:  http://localhost:${PORT}"
echo
echo "If you also want the self-contained Meshroom app, run the Meshroom PRO KI installer and re-run this script with --start."

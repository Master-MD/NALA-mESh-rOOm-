#!/usr/bin/env bash
# Meshroom PRO KI — Comfy-first All-in-One Installer/Updater
# macOS (Apple Silicon) focused. Safe on existing Comfy installs.
#
# Features
# - Auto-detect ComfyUI installs (ComfyUI.app and git folder)
# - Menu to choose target install OR --auto for non-interactive
# - Installs/updates custom nodes (comfy_meshroom_pro)
# - Optional AI extras (ncnn, molten-vk); does NOT clobber your models
# - Creates helper tools (server starter, diagnostics)
# - Cleans stale/old symlinks & folders (safe)
# - Leaves other Comfy tools intact
#
set -Eeuo pipefail

c_ok="\033[1;32m"; c_warn="\033[1;33m"; c_err="\033[1;31m"; c_act="\033[1;36m"; c_off="\033[0m"
ok(){ printf "${c_ok}✔${c_off} %s\n" "$*"; }
warn(){ printf "${c_warn}⚠${c_off} %s\n" "$*" >&2; }
err(){ printf "${c_err}✖${c_off} %s\n" "$*" >&2; }
act(){ printf "${c_act}▶${c_off} %s\n" "$*"; }

# ----------------- Options -----------------
WITH_AI_EXTRAS=0
AUTO=0
PORT="${PORT:-8188}"
HOST="${HOST:-0.0.0.0}"

while [[ "${1:-}" =~ ^- ]]; do
  case "$1" in
    --ai-extras) WITH_AI_EXTRAS=1 ;;
    --auto) AUTO=1 ;;
    --port) shift; PORT="${1:?}";;
    --host) shift; HOST="${1:?}";;
    --help|-h) echo "Usage: $0 [--ai-extras] [--auto] [--port 8188] [--host 0.0.0.0]"; exit 0;;
    *) err "Unknown option: $1"; exit 2;;
  esac; shift || true
done

# ----------------- Sanity -----------------
[[ "$(uname -s)" == "Darwin" ]] || { err "Requires macOS"; exit 1; }

# ----------------- Paths ------------------
BASE="$HOME/ComfyMeshroom"
COMFY_FALLBACK="$BASE/ComfyUI"
VENV="$BASE/venv"
TOOLS="$BASE/tools"
NODE_SRC="$COMFY_FALLBACK/custom_nodes/comfy_meshroom_pro"   # We'll clone to fallback if needed

mkdir -p "$BASE" "$TOOLS"

# ----------------- Brew & deps ------------
ensure_brew(){
  local BREW="/opt/homebrew/bin/brew"; [[ -x "$BREW" ]] || BREW="$(command -v brew || true)"
  if [[ -z "$BREW" ]]; then
    act "Installing Homebrew…"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    BREW="/opt/homebrew/bin/brew"
  fi
  eval "$("$BREW" shellenv)"
  echo "$BREW"
}

BREW_BIN="$(ensure_brew)"
act "Updating Homebrew…"
"$BREW_BIN" update || true
act "Installing base deps…"
"$BREW_BIN" install git python@3.12 tesseract || true
if (( WITH_AI_EXTRAS )); then
  "$BREW_BIN" install ncnn molten-vk || true
  ok "AI extras available (ncnn, MoltenVK)."
fi

# ----------------- Detect Comfy installs --
detect_comfy(){
  local list=()
  local c
  local candidates=(
    "$COMFY_HOME"
    "/Applications/ComfyUI.app/Contents/Resources/ComfyUI"
    "$HOME/Applications/ComfyUI.app/Contents/Resources/ComfyUI"
    "/Applications/ComfyUI"
    "$HOME/ComfyUI"
    "$COMFY_FALLBACK"
  )
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -d "$c" && -d "$c/custom_nodes" ]] || continue
    list+=("$c")
  done
  printf "%s\n" "${list[@]}"
}

choose_target(){
  local found=(); mapfile -t found < <(detect_comfy || true)
  if (( ${#found[@]} == 0 )); then
    if (( AUTO )); then
      echo ""
      return 0
    fi
    warn "Keine bestehende ComfyUI-Installation gefunden."
    echo "1) Neue lokale ComfyUI unter $COMFY_FALLBACK anlegen"
    echo "2) Abbrechen"
    read -rp "Auswahl [1/2]: " ans
    if [[ "$ans" == "1" ]]; then echo ""; return 0; else exit 0; fi
  fi

  if (( AUTO )); then
    echo "${found[0]}"
    return 0
  fi

  echo "Gefundene ComfyUI-Installationen:"
  local i=1
  for p in "${found[@]}"; do echo "  $i) $p"; ((i++)); done
  echo "  n) Neue lokale ComfyUI unter $COMFY_FALLBACK anlegen"
  read -rp "Bitte wählen: " pick
  if [[ "$pick" == "n" ]]; then
    echo ""
  else
    local idx=$((pick-1))
    echo "${found[$idx]:-}"
  fi
}

TARGET="$(choose_target)"
if [[ -z "$TARGET" ]]; then
  # fresh install to fallback
  if [[ ! -d "$COMFY_FALLBACK/.git" ]]; then
    act "Cloning ComfyUI → $COMFY_FALLBACK"
    git clone https://github.com/comfyanonymous/ComfyUI "$COMFY_FALLBACK"
  else
    (cd "$COMFY_FALLBACK" && git pull --ff-only) || true
  fi
  TARGET="$COMFY_FALLBACK"
fi
ok "Ziel-Comfy: $TARGET"

# ----------------- Python venv & reqs -----
PY="$(brew --prefix)/opt/python@3.12/bin/python3.12"
if [[ ! -d "$VENV" ]]; then
  act "Creating venv…"
  "$PY" -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel setuptools
if [[ -f "$TARGET/requirements.txt" ]]; then
  act "Installing Comfy requirements…"
  python -m pip install -r "$TARGET/requirements.txt" || true
fi
python -m pip install numpy pillow requests pytesseract trimesh shapely networkx opencv-python || true

# ----------------- Clean old leftovers ----
cleanup_leftovers(){
  act "Cleaning leftovers…"
  # Remove duplicate or broken links of our node in various common places
  local paths=(
    "$TARGET/custom_nodes/comfy_meshroom_pro"
    "$HOME/ComfyUI/custom_nodes/comfy_meshroom_pro"
  )
  for d in "${paths[@]}"; do
    [[ -e "$d" ]] || continue
    if [[ -L "$d" && ! -e "$(readlink "$d")" ]]; then
      rm -f "$d"; ok "Removed broken link: $d"
    elif [[ -d "$d" && ! -L "$d" && -f "$d/.meshroom_pro_marker" ]]; then
      rm -rf "$d"; ok "Removed old copy: $d"
    fi
  done
}
cleanup_leftovers

# ----------------- Install our nodes ------
install_nodes(){
  local src="$BASE/src_nodes"
  mkdir -p "$src"
  # write minimal node package
  mkdir -p "$src/comfy_meshroom_pro"
  cat > "$src/comfy_meshroom_pro/__init__.py" <<'PY'
# comfy_meshroom_pro package marker
PY
  cat > "$src/comfy_meshroom_pro/.meshroom_pro_marker" <<MARK
marker
MARK
  cat > "$src/comfy_meshroom_pro/meshroom_bridge.py" <<'PY'
import os, subprocess
from pathlib import Path
class MeshroomRun:
    @classmethod
    def INPUT_TYPES(s):
        return {"required": {
            "photos_dir": ("STRING", {"default": ""}),
            "output_dir": ("STRING", {"default": ""}),
            "pre_upscale": ("INT", {"default": 0, "min":0, "max":4}),
            "open_app": ("BOOLEAN", {"default": True}),
            "headless_mode": ("BOOLEAN", {"default": False}),
        }}
    RETURN_TYPES = ("STRING",)
    FUNCTION = "run"
    CATEGORY = "Meshroom"
    def run(self, photos_dir, output_dir, pre_upscale, open_app, headless_mode):
        app = Path(os.path.expanduser("~/Applications")) / "Meshroom PRO KI.app"
        res = app / "Contents/Resources"
        realesr = app / "Contents/MacOS" / "realesrgan-upscale"
        if pre_upscale and realesr.exists():
            out_pre = Path(output_dir)/"upscaled"; out_pre.mkdir(parents=True, exist_ok=True)
            subprocess.check_call([str(realesr), "-i", photos_dir, "-o", str(out_pre), "-s", str(pre_upscale), "-n", "realesrgan-x4plus"])
            photos_dir=str(out_pre)
        
        if headless_mode and app.exists():
            batch = app / "Contents/MacOS/meshroom_batch"
            if batch.exists():
                subprocess.Popen([str(batch), "--input", photos_dir, "--output", output_dir])
                return (f"Background Headless Mode started.\\nPhotos: {photos_dir}\\nOutput: {output_dir}",)
            else:
                return ("Error: meshroom_batch not found for headless mode",)
        elif open_app and app.exists():
            subprocess.Popen(["open", str(app)])
        return (f"Use photos from: {photos_dir}\\nOutput to: {output_dir}",)
NODE_CLASS_MAPPINGS={"MeshroomRun":MeshroomRun}
PY
  cat > "$src/comfy_meshroom_pro/floorplan_scale.py" <<'PY'
import os, subprocess
from pathlib import Path
class FloorplanScale:
    @classmethod
    def INPUT_TYPES(s):
        return {"required":{
            "floorplan_image": ("STRING", {"default": ""}),
            "mesh_path": ("STRING", {"default": ""}),
            "known_meters": ("FLOAT", {"default": 0.0}),
        }}
    RETURN_TYPES=("STRING",); FUNCTION="run"; CATEGORY="Meshroom"
    def run(self, floorplan_image, mesh_path, known_meters):
        app = Path(os.path.expanduser("~/Applications")) / "Meshroom PRO KI.app"
        helper = app / "Contents/Resources/bin/floorplan-scale"
        if not helper.exists():
            return ("floorplan-scale helper not found inside app",)
        args=[str(helper), "--floorplan", floorplan_image]
        if known_meters>0: args += ["--known", str(known_meters)]
        if mesh_path: args += ["--mesh", mesh_path]
        out = subprocess.check_output(args, text=True)
        return (out,)
NODE_CLASS_MAPPINGS={"FloorplanScale":FloorplanScale}
PY
  cat > "$src/comfy_meshroom_pro/bambu_export.py" <<'PY'
import os, subprocess
from pathlib import Path
class BambuExport:
    @classmethod
    def INPUT_TYPES(s):
        return {"required":{"mesh_path":("STRING",{"default":""}),"out_3mf":("STRING",{"default":""})}}
    RETURN_TYPES=("STRING",); FUNCTION="run"; CATEGORY="Meshroom"
    def run(self, mesh_path, out_3mf):
        app = Path(os.path.expanduser("~/Applications")) / "Meshroom PRO KI.app"
        tool = app / "Contents/Resources/tools/obj2threeMF"
        if not tool.exists():
            return ("3MF tool not found inside app",)
        subprocess.check_call([str(tool), mesh_path, out_3mf])
        return (f"Wrote {out_3mf}",)
NODE_CLASS_MAPPINGS={"BambuExport":BambuExport}
PY

  # deploy (symlink)
  local dest="$TARGET/custom_nodes/comfy_meshroom_pro"
  mkdir -p "$TARGET/custom_nodes"
  [[ -e "$dest" ]] && rm -rf "$dest"
  ln -s "$src/comfy_meshroom_pro" "$dest"
  ok "Custom nodes installiert: $dest"
}
install_nodes

# ----------------- Helper tools -----------
cat > "$TOOLS/start_comfy_server.sh" <<BASH
#!/usr/bin/env bash
set -euo pipefail
source "$VENV/bin/activate"
cd "$TARGET"
export COMFYUI_AUTH_TOKEN="\${COMFYUI_AUTH_TOKEN:-meshroompro}"
exec python main.py --listen "$HOST" --port "$PORT" --enable-cors-header --enable-cors-all
BASH
chmod +x "$TOOLS/start_comfy_server.sh"

cat > "$TOOLS/diagnose.sh" <<BASH
#!/usr/bin/env bash
echo "Python: \$(python -V)"; echo "Comfy: $TARGET"
echo "Nodes:"; ls -l "$TARGET/custom_nodes" | sed 's/^/  /'
BASH
chmod +x "$TOOLS/diagnose.sh"

# ----------------- Finish -----------------
ok "Installation/Update abgeschlossen."
echo "Start:"
echo "  $TOOLS/start_comfy_server.sh"
echo "Comfy UI: http://localhost:$PORT"

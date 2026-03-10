#!/usr/bin/env bash
# Meshroom (AliceVision) all-in-one installer for Apple Silicon (M1–M4)
# Adds: experimental OpenCL path (MeshroomCL), VulkanSift helper, .app launcher,
# and optional 3MF exporter helper for Bambu Studio.
#
# DISCLAIMER (please read):
# - AliceVision/Meshroom GPU acceleration is written for CUDA. There is currently
#   no supported way to "translate" CUDA kernels to Apple Metal. ZLUDA/ROCm etc.
#   do not target Apple Silicon. This installer therefore builds CPU/OpenMP
#   versions + optional *experimental* OpenCL pieces where community projects
#   exist. Expect CPU to be the stable path on macOS.
#
# USAGE:
#   chmod +x install_meshroom_pro_mac.sh
#   ./install_meshroom_pro_mac.sh [--ai-extras] [--experimental-opencl] [--prefix DIR]
#
set -Eeuo pipefail

# ----------------------------- Config ---------------------------------
PREFIX_DEFAULT="${HOME}/meshroom-local"
ALICEVISION_TAG="${ALICEVISION_TAG:-v3.3.0}"
MESHROOM_TAG="${MESHROOM_TAG:-v2025.1.0}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

AI_EXTRAS=0
EXPERIMENTAL_OPENCL=0
APP_SYMLINK=1   # symlink .app into ~/Applications by default

# Colors
c_green="\033[1;32m"; c_yellow="\033[1;33m"; c_red="\033[1;31m"; c_blue="\033[1;34m"; c_off="\033[0m"

usage(){
  cat <<EOF
${c_blue}Meshroom (AliceVision) Installer for Apple Silicon (M1–M4)${c_off}

Options:
  --prefix DIR             Install location (default: ${PREFIX_DEFAULT})
  --ai-extras              Install Real-ESRGAN & waifu2x (ncnn + MoltenVK)
  --experimental-opencl    Build MeshroomCL (OpenCL) + VulkanSift helper (best-effort)
  --no-app-symlink         Do not symlink the .app into ~/Applications
  --python VERSION         Use Homebrew python@VERSION (default: ${PYTHON_VERSION})
  --jobs N                 Parallel build jobs (default: ${JOBS})
  -h|--help                Show this help
EOF
}

log(){ printf "${c_green}▶${c_off} %s\n" "$*"; }
warn(){ printf "${c_yellow}⚠${c_off} %s\n" "$*" >&2; }
err(){ printf "${c_red}✖${c_off} %s\n" "$*" >&2; }

PREFIX="${PREFIX_DEFAULT}"

while [[ "${1:-}" =~ ^- ]]; do
  case "$1" in
    --prefix) shift; PREFIX="${1:?missing DIR}";;
    --ai-extras) AI_EXTRAS=1;;
    --experimental-opencl) EXPERIMENTAL_OPENCL=1;;
    --no-app-symlink) APP_SYMLINK=0;;
    --python) shift; PYTHON_VERSION="${1:?missing VERSION}";;
    --jobs) shift; JOBS="${1:?missing N}";;
    -h|--help) usage; exit 0;;
    *) err "Unknown option: $1"; usage; exit 2;;
  esac
  shift || true
done

# Paths
BREW_BIN="/opt/homebrew/bin/brew"
[[ -x "$BREW_BIN" ]] || BREW_BIN="$(command -v brew || true)"
INSTALL_ROOT="${PREFIX}"
SRC_DIR="${INSTALL_ROOT}/src"
BUILD_DIR="${INSTALL_ROOT}/build"
AV_SRC="${SRC_DIR}/AliceVision"
AV_BUILD="${BUILD_DIR}/alicevision"
AV_INSTALL="${INSTALL_ROOT}/alicevision-install"
MR_SRC="${SRC_DIR}/Meshroom"
VENV_DIR="${INSTALL_ROOT}/venv"
BIN_DIR="${INSTALL_ROOT}/bin"
LAUNCHER="${BIN_DIR}/meshroom"
LOG_DIR="${INSTALL_ROOT}/logs"
APP_DIR="${INSTALL_ROOT}/Meshroom.app"
mkdir -p "$SRC_DIR" "$BUILD_DIR" "$AV_INSTALL" "$BIN_DIR" "$LOG_DIR"

[[ "$(uname -s)" == "Darwin" ]] || { err "macOS required"; exit 1; }
ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" ]] || warn "Running on non-Apple Silicon (${ARCH}). Script targets Apple Silicon."

if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode Command Line Tools not found. Installing... (GUI prompt may appear)"
  xcode-select --install || true
  err "Please rerun this script after CLT installation finishes."; exit 1
fi

# ----------------------- Homebrew & packages --------------------------
if [[ -z "$BREW_BIN" ]]; then
  warn "Homebrew not found, installing..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  BREW_BIN="/opt/homebrew/bin/brew"
fi
eval "$("$BREW_BIN" shellenv)"

log "Updating Homebrew…"
brew update || true

PKGS_BUILD=(cmake ninja git pkg-config wget)
PKGS_LIBS=(llvm libomp boost eigen ceres-solver suitesparse geogram openimageio openexr alembic assimp zlib opencv qt@6)
PKGS_PY=("python@${PYTHON_VERSION}")
PKGS_MISC=(libarchive)
if (( AI_EXTRAS )); then
  PKGS_AI=(ncnn molten-vk vulkan-tools vulkan-validationlayers)
else
  PKGS_AI=()
fi
if (( EXPERIMENTAL_OPENCL )); then
  PKGS_OCL=(opencl-clhpp) # headers; Apple ships OpenCL runtime (deprecated)
else
  PKGS_OCL=()
fi

brew install "${PKGS_BUILD[@]}" || true
brew install "${PKGS_LIBS[@]}" || true
brew install "${PKGS_PY[@]}" || true
brew install "${PKGS_MISC[@]}" || true
[[ "${#PKGS_AI[@]}" -gt 0 ]] && brew install "${PKGS_AI[@]}" || true
[[ "${#PKGS_OCL[@]}" -gt 0 ]] && brew install "${PKGS_OCL[@]}" || true

PY_BIN="$(brew --prefix)/opt/python@${PYTHON_VERSION}/bin/python${PYTHON_VERSION%.*}"
LLVM_PREFIX="$(brew --prefix llvm)"
LIBOMP_PREFIX="$(brew --prefix libomp)"
QT_PREFIX="$(brew --prefix qt@6)"

# ----------------------- AliceVision CPU build ------------------------
if [[ ! -d "$AV_SRC/.git" ]]; then
  log "Cloning AliceVision ${ALICEVISION_TAG}…"
  git clone --recursive https://github.com/alicevision/AliceVision.git "$AV_SRC"
  (cd "$AV_SRC" && git checkout "${ALICEVISION_TAG}")
else
  log "Updating AliceVision source…"
  (cd "$AV_SRC" && git fetch --all --tags && git checkout "${ALICEVISION_TAG}" && git submodule update --init --recursive)
fi

mkdir -p "$AV_BUILD"
log "Configuring AliceVision (Release, OpenMP, no CUDA)…"
cmake -S "$AV_SRC" -B "$AV_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$AV_INSTALL" \
  -DCMAKE_C_COMPILER="${LLVM_PREFIX}/bin/clang" \
  -DCMAKE_CXX_COMPILER="${LLVM_PREFIX}/bin/clang++" \
  -DOpenMP_C_FLAGS="-fopenmp" \
  -DOpenMP_CXX_FLAGS="-fopenmp" \
  -DOpenMP_CXX_LIB_NAMES=omp \
  -DOpenMP_C_LIB_NAMES=omp \
  -DOpenMP_omp_LIBRARY="${LIBOMP_PREFIX}/lib/libomp.dylib" \
  -DALICEVISION_USE_CUDA=OFF \
  -DALICEVISION_USE_OPENMP=ON \
  -DALICEVISION_USE_OPENCV=ON \
  -DOpenCV_DIR="$(brew --prefix)/opt/opencv/share/opencv4" \
  -DQt6_DIR="${QT_PREFIX}/lib/cmake/Qt6" \
  | tee "${LOG_DIR}/alicevision-cmake.log"

log "Building AliceVision with ${JOBS} jobs…"
cmake --build "$AV_BUILD" -j "${JOBS}" | tee "${LOG_DIR}/alicevision-build.log"

log "Installing AliceVision → ${AV_INSTALL}"
cmake --install "$AV_BUILD" | tee "${LOG_DIR}/alicevision-install.log"

# ----------------------- Meshroom (PySide6) ---------------------------
if [[ ! -d "$MR_SRC/.git" ]]; then
  log "Cloning Meshroom ${MESHROOM_TAG}…"
  git clone https://github.com/alicevision/Meshroom.git "$MR_SRC"
  (cd "$MR_SRC" && git checkout "${MESHROOM_TAG}")
else
  log "Updating Meshroom source…"
  (cd "$MR_SRC" && git fetch --all --tags && git checkout "${MESHROOM_TAG}")
fi

# Python venv
"${PY_BIN}" -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip wheel setuptools

# requirements
REQ_FILE="${MR_SRC}/requirements.txt"
if [[ -f "$REQ_FILE" ]]; then
  pip install -r "$REQ_FILE"
else
  pip install PySide6 numpy pillow opencv-python openexr
fi

# Minimal helper: 3MF exporter (uses py3mf if available, falls back to STL copy)
pip install --upgrade py3mf || true

# ----------------------- AI Upscalers (optional) ----------------------
if (( AI_EXTRAS )); then
  EXTRAS_DIR="${INSTALL_ROOT}/ai-extras"
  mkdir -p "$EXTRAS_DIR/bin" "$EXTRAS_DIR/models"
  # Real-ESRGAN
  set +e
  API_JSON="$(curl -fsSL https://api.github.com/repos/xinntao/Real-ESRGAN-ncnn-vulkan/releases/latest || true)"
  MAC_ASSET_URL="$(printf "%s" "$API_JSON" | python3 - <<'PY'
import sys, json
j=json.load(sys.stdin)
for a in j.get("assets", []):
    n=a.get("name","").lower()
    if "mac" in n or "osx" in n or "darwin" in n:
        print(a.get("browser_download_url",""))
        break
PY
)"
  set -e
  if [[ -n "${MAC_ASSET_URL:-}" ]]; then
    TMP_ZIP="${EXTRAS_DIR}/realesrgan-mac.zip"
    curl -L "$MAC_ASSET_URL" -o "$TMP_ZIP"
    ditto -x -k "$TMP_ZIP" "$EXTRAS_DIR"; rm -f "$TMP_ZIP"
    BIN_PATH="$(/usr/bin/find "$EXTRAS_DIR" -type f -name 'realesrgan-ncnn-vulkan*' -perm +111 -print -quit || true)"
    [[ -n "$BIN_PATH" ]] && cp "$BIN_PATH" "$EXTRAS_DIR/bin/realesrgan-ncnn-vulkan" || true
  else
    warn "No prebuilt Real-ESRGAN macOS asset; building locally."
    pushd "$EXTRAS_DIR" >/dev/null
      git clone https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan.git || true
      cmake -S Real-ESRGAN-ncnn-vulkan -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
      cmake --build build -j "${JOBS}"
      cp build/realesrgan-ncnn-vulkan "$EXTRAS_DIR/bin/" || true
    popd >/dev/null
  fi
  # waifu2x
  API_JSON="$(curl -fsSL https://api.github.com/repos/nihui/waifu2x-ncnn-vulkan/releases/latest || true)"
  MAC_ASSET_URL="$(printf "%s" "$API_JSON" | python3 - <<'PY'
import sys, json
j=json.load(sys.stdin)
for a in j.get("assets", []):
    n=a.get("name","").lower()
    if "mac" in n or "osx" in n or "darwin" in n:
        print(a.get("browser_download_url",""))
        break
PY
)"
  if [[ -n "${MAC_ASSET_URL:-}" ]]; then
    TMP_ZIP="${EXTRAS_DIR}/waifu2x-mac.zip"
    curl -L "$MAC_ASSET_URL" -o "$TMP_ZIP"
    ditto -x -k "$TMP_ZIP" "$EXTRAS_DIR"; rm -f "$TMP_ZIP"
    BIN_PATH="$(/usr/bin/find "$EXTRAS_DIR" -type f -name 'waifu2x-ncnn-vulkan*' -perm +111 -print -quit || true)"
    [[ -n "$BIN_PATH" ]] && cp "$BIN_PATH" "$EXTRAS_DIR/bin/waifu2x-ncnn-vulkan" || true
  else
    warn "No prebuilt waifu2x macOS asset; building locally."
    pushd "$EXTRAS_DIR" >/dev/null
      git clone https://github.com/nihui/waifu2x-ncnn-vulkan.git || true
      cmake -S waifu2x-ncnn-vulkan -B build-w2x -G Ninja -DCMAKE_BUILD_TYPE=Release
      cmake --build build-w2x -j "${JOBS}"
      cp build-w2x/waifu2x-ncnn-vulkan "$EXTRAS_DIR/bin/" || true
    popd >/dev/null
  fi
  # wrappers
  mkdir -p "${BIN_DIR}"
  cat > "${BIN_DIR}/realesrgan-upscale" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${THIS_DIR}/../ai-extras/bin/realesrgan-ncnn-vulkan"
[[ -x "$BIN" ]] || { echo "realesrgan not found"; exit 1; }
exec "$BIN" "$@"
BASH
  chmod +x "${BIN_DIR}/realesrgan-upscale"
  cat > "${BIN_DIR}/waifu2x-upscale" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${THIS_DIR}/../ai-extras/bin/waifu2x-ncnn-vulkan"
[[ -x "$BIN" ]] || { echo "waifu2x not found"; exit 1; }
exec "$BIN" "$@"
BASH
  chmod +x "${BIN_DIR}/waifu2x-upscale"
fi

# ------------------- Experimental OpenCL / VulkanSift -----------------
VKSIFT_DIR="${INSTALL_ROOT}/vksift"
if (( EXPERIMENTAL_OPENCL )); then
  warn "Experimental path: building VulkanSift (Vulkan SIFT) helper."
  mkdir -p "$VKSIFT_DIR"
  pushd "$VKSIFT_DIR" >/dev/null
    git clone https://github.com/maelaubert/VulkanSift.git || true
    cmake -S VulkanSift -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j "${JOBS}" || warn "VulkanSift build failed (ok to ignore)."
  popd >/dev/null

  warn "Experimental path: MeshroomCL (OpenCL) – best effort build."
  MRCL_DIR="${SRC_DIR}/MeshroomCL"
  if [[ ! -d "$MRCL_DIR/.git" ]]; then
    git clone https://github.com/openphotogrammetry/meshroomcl "$MRCL_DIR" || true
  else
    (cd "$MRCL_DIR" && git pull --ff-only || true)
  fi
  # Install python deps if any
  [[ -d "$MRCL_DIR" ]] && { pip install -r "$MRCL_DIR/requirements.txt" 2>/dev/null || true; }
fi

# ----------------------- Launchers & helpers --------------------------
# Main Meshroom launcher
cat > "${LAUNCHER}" <<BASH
#!/usr/bin/env bash
set -euo pipefail
export PATH="${AV_INSTALL}/bin:\$PATH"
export DYLD_LIBRARY_PATH="${AV_INSTALL}/lib:\$DYLD_LIBRARY_PATH"
export ALICEVISION_INSTALL="${AV_INSTALL}"
export QT_PLUGIN_PATH="${QT_PREFIX}/plugins:\${QT_PLUGIN_PATH:-}"
export QML2_IMPORT_PATH="${QT_PREFIX}/qml:\${QML2_IMPORT_PATH:-}"
source "${VENV_DIR}/bin/activate"
cd "${MR_SRC}"
exec python -u start.py
BASH
chmod +x "${LAUNCHER}"

# 3MF export helper (OBJ/STL → 3MF)
cat > "${BIN_DIR}/obj2threeMF" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
# Usage: obj2threeMF input.obj output.3mf
IN="${1:-}"; OUT="${2:-}"
[[ -f "$IN" && -n "$OUT" ]] || { echo "Usage: obj2threeMF in.obj out.3mf"; exit 2; }
PY=$(cat <<'PY'
import sys, os
try:
    import py3mf
except Exception as e:
    print("py3mf not available:", e)
    sys.exit(3)
in_obj, out_3mf = sys.argv[1], sys.argv[2]
model = py3mf.Model()
# naive: single object, triangle soup
import trimesh
mesh = trimesh.load(in_obj, force='mesh')
if not isinstance(mesh, trimesh.Trimesh):
    if hasattr(mesh, 'geometry') and len(mesh.geometry):
        # take first geometry
        mesh = list(mesh.geometry.values())[0]
    else:
        raise SystemExit("Could not load mesh")
res = model.resources.add_mesh_object(mesh.vertices.view(float).reshape((-1,3)).tolist(),
                                      mesh.faces.view(int).reshape((-1,3)).tolist())
build_item = py3mf.BuildItem(res)
model.build_items.append(build_item)
model.save(out_3mf)
print("Wrote", out_3mf)
PY
)
python - <<PY "$IN" "$OUT"
try:
    import sys, subprocess
    import importlib.util as iu
    def has(mod):
        return iu.find_spec(mod) is not None
    # ensure deps
    import sys
    pkgs = []
    # trimesh stack for simple importers
    for p in ("trimesh","numpy","networkx","pyglet","shapely"):
        if not has(p): pkgs.append(p)
    if pkgs:
        subprocess.check_call([sys.executable,"-m","pip","install","--quiet"]+pkgs)
    code = r\"\"\"%s\"\"\"
    exec(code)
except SystemExit as e:
    raise
except Exception as e:
    print("Falling back: simply copy .stl to .3mf ZIP container not implemented due to missing lib3mf.")
    sys.exit(4)
PY
BASH
chmod +x "${BIN_DIR}/obj2threeMF"

# ----------------------- Create .app bundle ---------------------------
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Meshroom</string>
  <key>CFBundleName</key><string>Meshroom</string>
  <key>CFBundleIdentifier</key><string>org.nala.meshroom</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>meshroom-launcher</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "${APP_DIR}/Contents/MacOS/meshroom-launcher" <<BASH
#!/usr/bin/env bash
set -euo pipefail
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
# call the shell launcher so env is correct
"\${DIR}/bin/meshroom"
BASH
chmod +x "${APP_DIR}/Contents/MacOS/meshroom-launcher"

# optional symlink into ~/Applications
if (( APP_SYMLINK )); then
  mkdir -p "${HOME}/Applications"
  ln -snf "${APP_DIR}" "${HOME}/Applications/Meshroom.app"
fi

# ----------------------- Summary -------------------------------------
cat <<EOF

${c_green}✓ Installation complete.${c_off}

Launch options:
  - GUI:   ${APP_DIR}
           (also symlinked to ~/Applications/Meshroom.app)
  - CLI:   ${LAUNCHER}

Experimental flags used:
  AI extras: ${AI_EXTRAS}
  OpenCL/MeshroomCL: ${EXPERIMENTAL_OPENCL}

3MF helper:
  Use: ${BIN_DIR}/obj2threeMF input.obj output.3mf
  (Bambu Studio reads standard 3MF models; project metadata is not included.)

EOF

#!/usr/bin/env bash
set -Eeuo pipefail

# ----------------------------- Config ---------------------------------
APP_NAME="${APP_NAME:-Meshroom}"
APP_PARENT="${APP_PARENT:-$HOME/Applications}"
APP_DIR="${APP_PARENT}/${APP_NAME}.app"

ALICEVISION_TAG="${ALICEVISION_TAG:-v3.3.0}"
MESHROOM_TAG="${MESHROOM_TAG:-v2025.1.0}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

AI_EXTRAS=0
EXPERIMENTAL_OPENCL=0

# Colors
c_green="\033[1;32m"; c_yellow="\033[1;33m"; c_red="\033[1;31m"; c_blue="\033[1;34m"; c_off="\033[0m"
log(){ printf "${c_green}▶${c_off} %s\n" "$*"; }
warn(){ printf "${c_yellow}⚠${c_off} %s\n" "$*" >&2; }
err(){ printf "${c_red}✖${c_off} %s\n" "$*" >&2; }

usage(){
cat <<EOF
${c_blue}Meshroom All-in-One (.app bundle) Installer – Apple Silicon${c_off}

Everything (AliceVision, Python venv, Meshroom, optional AI upscalers) is stored
INSIDE the app bundle: ${APP_DIR}

Options:
  --ai-extras              Include Real-ESRGAN & waifu2x (ncnn + MoltenVK)
  --experimental-opencl    Try MeshroomCL + VulkanSift (best-effort)
  --app-name NAME          Set app name (default: ${APP_NAME})
  --app-parent DIR         Parent folder for .app (default: ${APP_PARENT})
  --python VERSION         Homebrew python@VERSION (default: ${PYTHON_VERSION})
  --jobs N                 Parallel build jobs (default: ${JOBS})
  -h|--help                Show help

Examples:
  ./meshroom_allinone_app.sh
  ./meshroom_allinone_app.sh --ai-extras
EOF
}

while [[ "${1:-}" =~ ^- ]]; do
  case "$1" in
    --ai-extras) AI_EXTRAS=1;;
    --experimental-opencl) EXPERIMENTAL_OPENCL=1;;
    --app-name) shift; APP_NAME="${1:?}"; APP_DIR="${APP_PARENT}/${APP_NAME}.app";;
    --app-parent) shift; APP_PARENT="${1:?}"; APP_DIR="${APP_PARENT}/${APP_NAME}.app";;
    --python) shift; PYTHON_VERSION="${1:?}";;
    --jobs) shift; JOBS="${1:?}";;
    -h|--help) usage; exit 0;;
    *) err "Unknown option: $1"; usage; exit 2;;
  esac; shift || true
done

[[ "$(uname -s)" == "Darwin" ]] || { err "Requires macOS"; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || warn "Not running on arm64 (Apple Silicon) — continuing anyway."

# ----------------------- Homebrew & deps ------------------------------
BREW_BIN="/opt/homebrew/bin/brew"; [[ -x "$BREW_BIN" ]] || BREW_BIN="$(command -v brew || true)"
if [[ -z "$BREW_BIN" ]]; then
  warn "Homebrew not found, installing..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  BREW_BIN="/opt/homebrew/bin/brew"
fi
eval "$("$BREW_BIN" shellenv)"

# clean stale partial downloads
find "${HOME}/Library/Caches/Homebrew/downloads" -name "*.incomplete" -maxdepth 1 -print0 2>/dev/null | xargs -0 -I{} rm -f "{}" || true

log "Updating Homebrew…"
brew update || true

PKGS_BUILD=(cmake ninja git pkg-config wget)
PKGS_LIBS=(llvm libomp boost eigen ceres-solver suitesparse geogram openimageio openexr alembic assimp zlib opencv qt@6 nanoflann)
PKGS_PY=("python@${PYTHON_VERSION}")
PKGS_MISC=(libarchive)
brew install "${PKGS_BUILD[@]}" || true
brew install "${PKGS_LIBS[@]}" || true
brew install "${PKGS_PY[@]}" || true
brew install "${PKGS_MISC[@]}" || true
if (( AI_EXTRAS )); then
  brew install ncnn molten-vk vulkan-tools vulkan-validationlayers || true
fi
if (( EXPERIMENTAL_OPENCL )); then
  brew install opencl-clhpp || true
fi

# ----------------------- Paths inside .app ----------------------------
RES="${APP_DIR}/Contents/Resources"
MACOS="${APP_DIR}/Contents/MacOS"
AV_INSTALL="${RES}/alicevision"
MR_SRC="${RES}/Meshroom"
VENV_DIR="${RES}/venv"
EXTRAS_DIR="${RES}/ai-extras"
LOG_DIR="${RES}/logs"
mkdir -p "${RES}" "${MACOS}" "${AV_INSTALL}" "${LOG_DIR}" "${APP_PARENT}"

# brew prefixes
LLVM_PREFIX="$(brew --prefix llvm)"
LIBOMP_PREFIX="$(brew --prefix libomp)"
QT_PREFIX="$(brew --prefix qt@6)"
BOOST_PREFIX="$(brew --prefix boost)"
NANO_PREFIX="$(brew --prefix nanoflann)"
PY_BIN="$(brew --prefix)/opt/python@${PYTHON_VERSION}/bin/python${PYTHON_VERSION%.*}"

# ----------------------- venv + legacy cmake --------------------------
log "Creating Python venv (inside .app) and installing legacy CMake…"
"${PY_BIN}" -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
python -m pip install --upgrade pip wheel setuptools
python -m pip install "cmake<3.29"  # ensures FindBoost exists
CMAKE_LEGACY="$(command -v cmake)"
log "Using legacy cmake at: ${CMAKE_LEGACY}"

# ----------------------- Temp build workspace -------------------------
WORKDIR="$(mktemp -d /tmp/meshroom-build-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
AV_SRC="${WORKDIR}/AliceVision"
AV_BUILD="${WORKDIR}/av-build"

# ----------------------- Fetch sources --------------------------------
if [[ ! -d "$AV_SRC/.git" ]]; then
  log "Cloning AliceVision ${ALICEVISION_TAG}…"
  git clone --recursive https://github.com/alicevision/AliceVision.git "$AV_SRC"
  (cd "$AV_SRC" && git checkout "${ALICEVISION_TAG}")
fi

if [[ ! -d "$MR_SRC/.git" ]]; then
  log "Cloning Meshroom ${MESHROOM_TAG} into app bundle…"
  git clone https://github.com/alicevision/Meshroom.git "$MR_SRC"
  (cd "$MR_SRC" && git checkout "${MESHROOM_TAG}")
fi

# ----------------------- Configure & build AliceVision ----------------
log "Configuring AliceVision (install prefix INSIDE .app)…"
mkdir -p "$AV_BUILD"
"${CMAKE_LEGACY}" -S "$AV_SRC" -B "$AV_BUILD" -G Ninja \
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
  -DCMAKE_PREFIX_PATH="${BOOST_PREFIX};${NANO_PREFIX}" \
  | tee "${LOG_DIR}/alicevision-cmake.log"

log "Building AliceVision…"
"${CMAKE_LEGACY}" --build "$AV_BUILD" -j "${JOBS}" | tee "${LOG_DIR}/alicevision-build.log"
log "Installing AliceVision into app bundle…"
"${CMAKE_LEGACY}" --install "$AV_BUILD" | tee "${LOG_DIR}/alicevision-install.log"

# ----------------------- Meshroom Python deps -------------------------
REQ_FILE="${MR_SRC}/requirements.txt"
if [[ -f "$REQ_FILE" ]]; then
  python -m pip install -r "$REQ_FILE"
else
  python -m pip install PySide6 numpy pillow opencv-python openexr
fi
python -m pip install py3mf || true

# ----------------------- AI Upscalers (optional) ----------------------
if (( AI_EXTRAS )); then
  mkdir -p "${EXTRAS_DIR}/bin" "${EXTRAS_DIR}/models"
  # Real-ESRGAN (try prebuilt)
  set +e
  API_JSON="$(curl -fsSL https://api.github.com/repos/xinntao/Real-ESRGAN-ncnn-vulkan/releases/latest || true)"
  MAC_ASSET_URL="$(printf "%s" "$API_JSON" | python - <<'PY'
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
    TMP_ZIP="${WORKDIR}/realesrgan-mac.zip"
    curl -L "$MAC_ASSET_URL" -o "$TMP_ZIP"
    ditto -x -k "$TMP_ZIP" "${EXTRAS_DIR}"; rm -f "$TMP_ZIP"
    BIN_PATH="$(/usr/bin/find "${EXTRAS_DIR}" -type f -name 'realesrgan-ncnn-vulkan*' -perm +111 -print -quit || true)"
    [[ -n "$BIN_PATH" ]] && cp "$BIN_PATH" "${EXTRAS_DIR}/bin/realesrgan-ncnn-vulkan" || true
  fi
  # Waifu2x (try prebuilt)
  API_JSON="$(curl -fsSL https://api.github.com/repos/nihui/waifu2x-ncnn-vulkan/releases/latest || true)"
  MAC_ASSET_URL="$(printf "%s" "$API_JSON" | python - <<'PY'
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
    TMP_ZIP="${WORKDIR}/waifu2x-mac.zip"
    curl -L "$MAC_ASSET_URL" -o "$TMP_ZIP"
    ditto -x -k "$TMP_ZIP" "${EXTRAS_DIR}"; rm -f "$TMP_ZIP"
    BIN_PATH="$(/usr/bin/find "${EXTRAS_DIR}" -type f -name 'waifu2x-ncnn-vulkan*' -perm +111 -print -quit || true)"
    [[ -n "$BIN_PATH" ]] && cp "$BIN_PATH" "${EXTRAS_DIR}/bin/waifu2x-ncnn-vulkan" || true
  fi

  # wrappers in MacOS for PATH
  cat > "${MACOS}/realesrgan-upscale" <<'BASH'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$DIR/Resources/ai-extras/bin/realesrgan-ncnn-vulkan" "$@"
BASH
  chmod +x "${MACOS}/realesrgan-upscale"

  cat > "${MACOS}/waifu2x-upscale" <<'BASH'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$DIR/Resources/ai-extras/bin/waifu2x-ncnn-vulkan" "$@"
BASH
  chmod +x "${MACOS}/waifu2x-upscale"
fi

# ----------------------- .app metadata & launcher ---------------------
mkdir -p "${APP_DIR}/Contents/Resources" "${MACOS}"
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>org.nala.${APP_NAME// /}</string>
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

cat > "${MACOS}/meshroom-launcher" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
# Resolve bundle paths
APP="$(cd "$(dirname "$0")/.." && pwd)"
RES="$APP/Resources"
export PATH="$RES/alicevision/bin:$PATH"
export DYLD_LIBRARY_PATH="$RES/alicevision/lib:${DYLD_LIBRARY_PATH:-}"
export ALICEVISION_INSTALL="$RES/alicevision"
# Qt plugins
QT_PREFIX="$(/opt/homebrew/bin/brew --prefix qt@6 2>/dev/null || brew --prefix qt@6)"
export QT_PLUGIN_PATH="$QT_PREFIX/plugins:${QT_PLUGIN_PATH:-}"
export QML2_IMPORT_PATH="$QT_PREFIX/qml:${QML2_IMPORT_PATH:-}"
# Python venv
source "$RES/venv/bin/activate"
cd "$RES/Meshroom"
exec python -u start.py
BASH
chmod +x "${MACOS}/meshroom-launcher"

# convenience CLI shim
mkdir -p "${RES}/bin"
cat > "${RES}/bin/meshroom" <<'BASH'
#!/usr/bin/env bash
APP="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$APP/Contents/MacOS/meshroom-launcher" "$@"
BASH
chmod +x "${RES}/bin/meshroom"

# final message
log "✅ All-in-one install finished."
echo
echo "App Bundle: ${APP_DIR}"
echo "Start (GUI): open \"${APP_DIR}\""
echo "Start (CLI): \"${APP_DIR}/Contents/Resources/bin/meshroom\""

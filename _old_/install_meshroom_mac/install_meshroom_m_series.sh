#!/usr/bin/env bash
# Meshroom (AliceVision) all-in-one installer for Apple Silicon (M1–M4) macOS
# - Builds AliceVision (CPU, OpenMP) and Meshroom (Qt6/PySide6) from source
# - Optionally installs AI upscalers (Real-ESRGAN/waifu2x via ncnn+MoltenVK)
# - Creates a Python venv and a launcher script
#
# USAGE:
#   chmod +x install_meshroom_m_series.sh
#   ./install_meshroom_m_series.sh            # default install
#   ./install_meshroom_m_series.sh --ai-extras  # add AI upscalers (ncnn Vulkan)
#   ./install_meshroom_m_series.sh --prefix ~/NALA-meshroom  # custom install dir
#
# Notes:
# - Apple Silicon has no CUDA. Meshroom will run CPU-only (dense steps slower).
# - AI extras use Vulkan via MoltenVK (maps to Apple Metal). 
# - You need Xcode Command Line Tools installed (xcode-select --install).

set -Eeuo pipefail

# ----------------------------- Config ---------------------------------
PREFIX_DEFAULT="${HOME}/meshroom-local"
ALICEVISION_TAG="${ALICEVISION_TAG:-v3.3.0}"   # matches Meshroom 2025.1.0 base
MESHROOM_TAG="${MESHROOM_TAG:-v2025.1.0}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# Feature flags
AI_EXTRAS=0

# Colors
c_green="\033[1;32m"; c_yellow="\033[1;33m"; c_red="\033[1;31m"; c_blue="\033[1;34m"; c_off="\033[0m"

# -------------------------- Args & Helpers ----------------------------
usage(){
  cat <<EOF
${c_blue}Meshroom (AliceVision) Installer for Apple Silicon (M1–M4)${c_off}

Options:
  --prefix DIR          Install location (default: ${PREFIX_DEFAULT})
  --ai-extras           Install Real-ESRGAN & waifu2x (ncnn + MoltenVK)
  --no-ai-extras        Skip AI extras (default)
  --python VERSION      Use Homebrew python@VERSION (default: ${PYTHON_VERSION})
  --jobs N              Parallel build jobs (default: ${JOBS})
  -h|--help             Show this help

Examples:
  ./install_meshroom_m_series.sh
  ./install_meshroom_m_series.sh --ai-extras --prefix ~/NALA-meshroom
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
    --no-ai-extras) AI_EXTRAS=0;;
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
mkdir -p "$SRC_DIR" "$BUILD_DIR" "$AV_INSTALL" "$BIN_DIR" "$LOG_DIR"

# ----------------------- Sanity checks --------------------------------
[[ "$(uname -s)" == "Darwin" ]] || { err "macOS required"; exit 1; }
ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" ]] || warn "Running on non-Apple Silicon (${ARCH}). Script targets Apple Silicon."
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode Command Line Tools not found. Installing... (a GUI prompt may appear)"
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

# Core toolchain + deps
PKGS_BUILD=(cmake ninja git pkg-config wget)
PKGS_LIBS=(llvm libomp boost eigen ceres-solver suitesparse geogram openimageio openexr alembic assimp zlib opencv qt@6)
PKGS_PY=("python@${PYTHON_VERSION}")
if (( AI_EXTRAS )); then
  PKGS_AI=(ncnn molten-vk vulkan-tools vulkan-validationlayers)
else
  PKGS_AI=()
fi

log "Installing build tools…"
brew install "${PKGS_BUILD[@]}" || true
log "Installing libraries…"
brew install "${PKGS_LIBS[@]}" || true
log "Installing Python ${PYTHON_VERSION}…"
brew install "${PKGS_PY[@]}" || true
if (( AI_EXTRAS )); then
  log "Installing AI extras prerequisites…"
  brew install "${PKGS_AI[@]}" || true
fi

# Resolve paths
PY_BIN="$(brew --prefix)/opt/python@${PYTHON_VERSION}/bin/python${PYTHON_VERSION%.*}"
PIP_BIN="$(brew --prefix)/opt/python@${PYTHON_VERSION}/bin/pip${PYTHON_VERSION%.*}"
LLVM_PREFIX="$(brew --prefix llvm)"
LIBOMP_PREFIX="$(brew --prefix libomp)"
QT_PREFIX="$(brew --prefix qt@6)"

# ----------------------- AliceVision (build) --------------------------
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

# ----------------------- Meshroom (Python + Qt) -----------------------
if [[ ! -d "$MR_SRC/.git" ]]; then
  log "Cloning Meshroom ${MESHROOM_TAG}…"
  git clone https://github.com/alicevision/Meshroom.git "$MR_SRC"
  (cd "$MR_SRC" && git checkout "${MESHROOM_TAG}")
else
  log "Updating Meshroom source…"
  (cd "$MR_SRC" && git fetch --all --tags && git checkout "${MESHROOM_TAG}")
fi

# Python venv
log "Creating Python venv…"
"${PY_BIN}" -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

log "Upgrading pip & wheel…"
pip install --upgrade pip wheel setuptools

# Requirements (PySide6 per Meshroom 2025 release)
log "Installing Meshroom Python requirements…"
# Prefer repo requirements if present, otherwise ensure PySide6 & common deps
REQ_FILE="${MR_SRC}/requirements.txt"
if [[ -f "$REQ_FILE" ]]; then
  pip install -r "$REQ_FILE"
else
  pip install PySide6 numpy pillow opencv-python openexr
fi

# ----------------------- AI Extras (optional) -------------------------
if (( AI_EXTRAS )); then
  EXTRAS_DIR="${INSTALL_ROOT}/ai-extras"
  mkdir -p "$EXTRAS_DIR/bin" "$EXTRAS_DIR/models"
  log "Fetching Real-ESRGAN-ncnn-vulkan prebuilt (if available)…"
  # Try to download macOS archive from the latest release via GitHub API
  set +e
  API_JSON="$(curl -fsSL https://api.github.com/repos/xinntao/Real-ESRGAN-ncnn-vulkan/releases/latest || true)"
  MAC_ASSET_URL="$(printf "%s" "$API_JSON" | python3 - <<'PY'
import sys, json, re
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
    log "Downloading: $MAC_ASSET_URL"
    TMP_ZIP="${EXTRAS_DIR}/realesrgan-mac.zip"
    curl -L "$MAC_ASSET_URL" -o "$TMP_ZIP"
    ditto -x -k "$TMP_ZIP" "$EXTRAS_DIR"
    rm -f "$TMP_ZIP"
    # try to locate binary
    REALESRGAN_BIN="$(/usr/bin/find "$EXTRAS_DIR" -type f -name 'realesrgan-ncnn-vulkan*' -perm +111 -print -quit || true)"
    [[ -n "$REALESRGAN_BIN" ]] && cp "$REALESRGAN_BIN" "$EXTRAS_DIR/bin/realesrgan-ncnn-vulkan" || true
  else
    warn "No prebuilt macOS asset found; attempting local build of Real-ESRGAN-ncnn-vulkan…"
    pushd "$EXTRAS_DIR" >/dev/null
      git clone https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan.git
      cmake -S Real-ESRGAN-ncnn-vulkan -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
      cmake --build build -j "${JOBS}"
      cp build/realesrgan-ncnn-vulkan "$EXTRAS_DIR/bin/" || true
    popd >/dev/null
  fi

  # waifu2x-ncnn-vulkan (alternative upscaler)
  log "Fetching waifu2x-ncnn-vulkan prebuilt (if available)…"
  API_JSON="$(curl -fsSL https://api.github.com/repos/nihui/waifu2x-ncnn-vulkan/releases/latest || true)"
  MAC_ASSET_URL="$(printf "%s" "$API_JSON" | python3 - <<'PY'
import sys, json, re
j=json.load(sys.stdin)
for a in j.get("assets", []):
    n=a.get("name","").lower()
    if "mac" in n or "osx" in n or "darwin" in n:
        print(a.get("browser_download_url",""))
        break
PY
)"
  if [[ -n "${MAC_ASSET_URL:-}" ]]; then
    log "Downloading: $MAC_ASSET_URL"
    TMP_ZIP="${EXTRAS_DIR}/waifu2x-mac.zip"
    curl -L "$MAC_ASSET_URL" -o "$TMP_ZIP"
    ditto -x -k "$TMP_ZIP" "$EXTRAS_DIR"
    rm -f "$TMP_ZIP"
    W2X_BIN="$(/usr/bin/find "$EXTRAS_DIR" -type f -name 'waifu2x-ncnn-vulkan*' -perm +111 -print -quit || true)"
    [[ -n "$W2X_BIN" ]] && cp "$W2X_BIN" "$EXTRAS_DIR/bin/waifu2x-ncnn-vulkan" || true
  else
    warn "No prebuilt macOS asset found; attempting local build of waifu2x-ncnn-vulkan…"
    pushd "$EXTRAS_DIR" >/dev/null
      git clone https://github.com/nihui/waifu2x-ncnn-vulkan.git
      cmake -S waifu2x-ncnn-vulkan -B build-w2x -G Ninja -DCMAKE_BUILD_TYPE=Release
      cmake --build build-w2x -j "${JOBS}"
      cp build-w2x/waifu2x-ncnn-vulkan "$EXTRAS_DIR/bin/" || true
    popd >/dev/null
  fi

  # convenience wrappers
  cat > "${BIN_DIR}/realesrgan-upscale" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${THIS_DIR}/../ai-extras/bin/realesrgan-ncnn-vulkan"
if [[ ! -x "$BIN" ]]; then echo "realesrgan binary not found. Reinstall with --ai-extras"; exit 1; fi
exec "$BIN" "$@"
BASH
  chmod +x "${BIN_DIR}/realesrgan-upscale"

  cat > "${BIN_DIR}/waifu2x-upscale" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${THIS_DIR}/../ai-extras/bin/waifu2x-ncnn-vulkan"
if [[ ! -x "$BIN" ]]; then echo "waifu2x binary not found. Reinstall with --ai-extras"; exit 1; fi
exec "$BIN" "$@"
BASH
  chmod +x "${BIN_DIR}/waifu2x-upscale"
fi

# ----------------------- Launcher script ------------------------------
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

# ----------------------- Summary -------------------------------------
cat <<EOF

${c_green}✓ Installation complete.${c_off}

Binaries / scripts:
  - Meshroom launcher: ${LAUNCHER}
  - AliceVision bin:   ${AV_INSTALL}/bin
  - Python venv:       ${VENV_DIR}

Run Meshroom:
  ${LAUNCHER}

Tips:
  - Put ${BIN_DIR} on your PATH:
      echo 'export PATH="${BIN_DIR}:\$PATH"' >> ~/.zshrc

EOF

#!/usr/bin/env bash
set -Eeuo pipefail

# ----------------------------- Config ---------------------------------
PREFIX_DEFAULT="${HOME}/meshroom-local"
ALICEVISION_TAG="${ALICEVISION_TAG:-v3.3.0}"
MESHROOM_TAG="${MESHROOM_TAG:-v2025.1.0}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
AI_EXTRAS=0
EXPERIMENTAL_OPENCL=0
APP_SYMLINK=1

c_green="\033[1;32m"; c_yellow="\033[1;33m"; c_red="\033[1;31m"; c_blue="\033[1;34m"; c_off="\033[0m"
log(){ printf "${c_green}▶${c_off} %s\n" "$*"; }
warn(){ printf "${c_yellow}⚠${c_off} %s\n" "$*" >&2; }
err(){ printf "${c_red}✖${c_off} %s\n" "$*" >&2; }

usage(){
cat <<EOF
Meshroom (AliceVision) Installer – macOS Apple Silicon (M1–M4)
Patched: Boost/CMake 4.1 fix + nanoflann

Options:
  --prefix DIR             Install location (default: ${PREFIX_DEFAULT})
  --ai-extras              Install Real-ESRGAN & waifu2x (ncnn + MoltenVK)
  --experimental-opencl    Build MeshroomCL + VulkanSift (best-effort)
  --no-app-symlink         Do not symlink the .app into ~/Applications
  --python VERSION         Homebrew python (default: ${PYTHON_VERSION})
  --jobs N                 Parallel build jobs (default: ${JOBS})
EOF
}

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
    *) err "Unknown option $1"; usage; exit 2;;
  esac; shift || true
done

[[ "$(uname -s)" == "Darwin" ]] || { err "macOS required"; exit 1; }
ARCH="$(uname -m)"; [[ "$ARCH" == "arm64" ]] || warn "Not running arm64 (Apple Silicon)."

BREW_BIN="/opt/homebrew/bin/brew"; [[ -x "$BREW_BIN" ]] || BREW_BIN="$(command -v brew || true)"
if [[ -z "$BREW_BIN" ]]; then
  warn "Homebrew not found, installing..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  BREW_BIN="/opt/homebrew/bin/brew"
fi
eval "$("$BREW_BIN" shellenv)"

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

# Handle brew lock files cleanly for previous partial downloads
find "${HOME}/Library/Caches/Homebrew/downloads" -name "*.incomplete" -maxdepth 1 -print0 2>/dev/null | xargs -0 -I{} rm -f "{}" || true

log "Updating Homebrew…"
brew update || true

# Core deps + NEW: nanoflann (explicit) + boost (already installed as per logs)
PKGS_BUILD=(cmake ninja git pkg-config wget)
PKGS_LIBS=(llvm libomp boost eigen ceres-solver suitesparse geogram openimageio openexr alembic assimp zlib opencv qt@6 nanoflann)
PKGS_PY=("python@${PYTHON_VERSION}")
PKGS_MISC=(libarchive)
brew install "${PKGS_BUILD[@]}" || true
brew install "${PKGS_LIBS[@]}" || true
brew install "${PKGS_PY[@]}" || true
brew install "${PKGS_MISC[@]}" || true

# Resolve prefixes
LLVM_PREFIX="$(brew --prefix llvm)"
LIBOMP_PREFIX="$(brew --prefix libomp)"
QT_PREFIX="$(brew --prefix qt@6)"
BOOST_PREFIX="$(brew --prefix boost)"
NANO_PREFIX="$(brew --prefix nanoflann)"
PY_BIN="$(brew --prefix)/opt/python@${PYTHON_VERSION}/bin/python${PYTHON_VERSION%.*}"

# ---- Create venv and install LEGACY CMake inside to restore FindBoost ----
log "Creating Python venv + legacy CMake for AliceVision configure…"
"${PY_BIN}" -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
python -m pip install --upgrade pip wheel setuptools
# Use CMake 3.27 (FindBoost still present); keep system cmake for other parts
python -m pip install "cmake<3.29"  # brings a 'cmake' binary into venv

CMAKE_LEGACY="$(command -v cmake)"
log "Legacy CMake resolved to: ${CMAKE_LEGACY}"

# ---- Clone / update AliceVision ----
if [[ ! -d "$AV_SRC/.git" ]]; then
  log "Cloning AliceVision ${ALICEVISION_TAG}…"
  git clone --recursive https://github.com/alicevision/AliceVision.git "$AV_SRC"
  (cd "$AV_SRC" && git checkout "${ALICEVISION_TAG}")
else
  log "Updating AliceVision source…"
  (cd "$AV_SRC" && git fetch --all --tags && git checkout "${ALICEVISION_TAG}" && git submodule update --init --recursive)
fi

mkdir -p "$AV_BUILD"
log "Configuring AliceVision with legacy CMake (Boost + nanoflann wired)…"
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
log "Installing AliceVision → ${AV_INSTALL}"
"${CMAKE_LEGACY}" --install "$AV_BUILD" | tee "${LOG_DIR}/alicevision-install.log"

# ---- Meshroom (PySide6) ----
if [[ ! -d "$MR_SRC/.git" ]]; then
  log "Cloning Meshroom ${MESHROOM_TAG}…"
  git clone https://github.com/alicevision/Meshroom.git "$MR_SRC"
  (cd "$MR_SRC" && git checkout "${MESHROOM_TAG}")
else
  log "Updating Meshroom source…"
  (cd "$MR_SRC" && git fetch --all --tags && git checkout "${MESHROOM_TAG}")
fi

REQ_FILE="${MR_SRC}/requirements.txt"
if [[ -f "$REQ_FILE" ]]; then
  python -m pip install -r "$REQ_FILE"
else
  python -m pip install PySide6 numpy pillow opencv-python openexr
fi
python -m pip install py3mf || true

# ---- Launcher ----
mkdir -p "${BIN_DIR}"
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

# ---- .app bundle ----
APP_DIR="${INSTALL_ROOT}/Meshroom.app"
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
"\${DIR}/bin/meshroom"
BASH
chmod +x "${APP_DIR}/Contents/MacOS/meshroom-launcher"
mkdir -p "${HOME}/Applications"; ln -snf "${APP_DIR}" "${HOME}/Applications/Meshroom.app"

# ---- Summary ----
cat <<EOF

${c_green}✓ Patched install complete.${c_off}

Start:
  open "${APP_DIR}"   # GUI
  ${LAUNCHER}         # CLI

If the AliceVision configure still complains about Boost/nanoflann:
  - Ensure: brew install boost nanoflann
  - Re-run installer; it forces CMAKE_PREFIX_PATH to those prefixes.
EOF

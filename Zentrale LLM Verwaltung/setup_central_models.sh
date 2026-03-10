#!/bin/bash
# setup_central_models.sh  —  Unified Model Manager (macOS Bash 3.2)

set -euo pipefail

# ===========================
# Einstellungen
# ===========================
CENTRAL="${HOME}/AI_Models"
MANIFEST="${CENTRAL}/.manifest.jsonl"
LOG="${CENTRAL}/.last_run.log"

# Bekannte App-Pfade (erweiterbar)
APP_DIRS_DEFAULT="
${HOME}/Library/Application Support/JAN/models
${HOME}/Library/Application Support/JAN/Models
${HOME}/Library/Application Support/Jan/data/llamacpp/models
${HOME}/ComfyMeshroom/ComfyUI/models
${HOME}/ComfyMeshroom/ComfyUI/models/checkpoints
${HOME}/ComfyMeshroom/ComfyUI/models/loras
${HOME}/ComfyMeshroom/ComfyUI/models/vae
${HOME}/ComfyMeshroom/ComfyUI/models/unet
${HOME}/LLMStudio/models
"

# Dateiendungen, die wir als „Modelle“ betrachten
MODEL_EXTS="gguf ggml safetensors ckpt pt pth bin onnx mpt tflite"

# Laufzeit-Flags
VERBOSE=0
FULLSCAN=0

# Zähler für Zusammenfassung
FOUND=0; MOVED=0; DEDUPED=0; SYMLINKED=0; SKIPPED_INUSE=0; SKIPPED_OTHER=0

# ===========================
# Hilfs-Funktionen
# ===========================
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  local msg="$1"
  mkdir -p "$(dirname "$LOG")"
  printf '[%s] %s\n' "$(timestamp)" "$msg" | tee -a "$LOG" >/dev/null
  [ $VERBOSE -eq 1 ] && printf '%s\n' "$msg"
}

ensure_dirs() {
  mkdir -p "$CENTRAL"
  : > "$MANIFEST"
  touch "$LOG"
}

# einfache Klassifikation für Unterordner im Zentral-Repo
classify_model() {
  # mappt Endung/Name auf Unterkategorie
  p="$1"
  case "${p##*.}" in
    gguf|ggml) echo "llm";;
    safetensors|ckpt|pt|pth) echo "diffusion";;
    onnx|tflite|mpt) echo "onnx";;
    bin) # könnte alles Mögliche sein – heuristisch filtern
      case "$(echo "$p" | tr '[:upper:]' '[:lower:]')" in
        *unet*|*vae*|*control*|*sdxl*|*flux*) echo "diffusion";;
        *llama*|*qwen*|*mistral*|*deepseek*|*qwen2*|*qwen3*) echo "llm";;
        *) echo "misc";;
      esac
      ;;
    *) echo "misc";;
  esac
}

sha256_of() {
  # macOS: shasum -a 256
  shasum -a 256 "$1" | awk '{print $1}'
}

is_in_use() {
  # grob mit lsof prüfen, ob Datei in Benutzung ist
  local p="$1"
  # lsof kann laut Rechte fehlschlagen -> nicht kritisch
  if command -v lsof >/dev/null 2>&1; then
    lsof "$p" >/dev/null 2>&1 && return 0 || return 1
  fi
  return 1
}

same_device() {
  # prüfe ob Quelle und Ziel auf gleichem Volume liegen (für mv vs. cp)
  local a="$1" b="$2"
  local da db
  da=$(df -P "$a" | tail -1 | awk '{print $1}')
  db=$(df -P "$b" | tail -1 | awk '{print $1}')
  [ "$da" = "$db" ]
}

safe_mklink() {
  local src="$1" # zentrale Datei
  local back_dst="$2" # alter Fundort (jetzt Link-Ziel)
  local back_dir
  back_dir="$(dirname "$back_dst")"
  mkdir -p "$back_dir"
  # symlink ersetzen (atomar)
  rm -f "$back_dst"
  ln -s "$src" "$back_dst"
  SYMLINKED=$((SYMLINKED+1))
}

write_manifest_line() {
  local src="$1"; local dst="$2"; local hash="$3"; local note="${4:-}"
  printf '{"time":"%s","src":"%s","dst":"%s","sha256":"%s","note":"%s"}\n' \
    "$(timestamp)" "$src" "$dst" "$hash" "$note" >> "$MANIFEST"
}

summarize() {
  echo
  echo "──────────────── Zusammenfassung ────────────────"
  printf "%-24s %d\n" "Gefunden:" "$FOUND"
  printf "%-24s %d\n" "Neu verschoben:" "$MOVED"
  printf "%-24s %d\n" "Duplikate zusammengeführt:" "$DEDUPED"
  printf "%-24s %d\n" "Symlinks aktualisiert:" "$SYMLINKED"
  printf "%-24s %d\n" "Übersprungen (in Benutzung):" "$SKIPPED_INUSE"
  printf "%-24s %d\n" "Übersprungen (sonst):" "$SKIPPED_OTHER"
  printf "%-24s %s\n" "Zentralordner:" "$CENTRAL"
  printf "%-24s %s\n" "Manifest:" "$MANIFEST"
  printf "%-24s %s\n" "Log:" "$LOG"
}

list_known_roots() {
  # dedupliziere und nur existierende Verzeichnisse ausgeben
  echo "$APP_DIRS_DEFAULT" | while IFS= read -r d; do
    [ -z "${d// /}" ] && continue
    [ -d "$d" ] && echo "$d"
  done
}

find_candidates() {
  # Quelle 1: bekannte App-Verzeichnisse
  list_known_roots | while IFS= read -r root; do
    find "$root" -type f \( $(ext_predicates) \) 2>/dev/null
  done

  # Quelle 2: optionaler Full-Scan (nur innerhalb $HOME, exkl. CENTRAL)
  if [ $FULLSCAN -eq 1 ]; then
    find "$HOME" -path "$CENTRAL" -prune -o -type f \( $(ext_predicates) \) -print 2>/dev/null
  fi
}

ext_predicates() {
  # baut ein FIND-Statement wie: -name "*.gguf" -o -name "*.safetensors" ...
  local first=1 out=""
  for e in $MODEL_EXTS; do
    if [ $first -eq 1 ]; then
      out="-name '*.$e'"
      first=0
    else
      out="$out -o -name '*.$e'"
    fi
  done
  echo "$out"
}

central_path_for() {
  local src="$1"
  local cat; cat="$(classify_model "$src")"
  local base; base="$(basename "$src")"
  echo "${CENTRAL}/${cat}/${base}"
}

dedup_match_in_central() {
  # dedup via Hash → gib vorhandenen Pfad zurück, falls gleicher Hash existiert
  local h="$1"
  # quick & dirty: grep im Manifest nach Hash und nimm letzte Zeile
  local line dst
  line=$(grep -F "\"sha256\":\"$h\"" "$MANIFEST" | tail -1 || true)
  if [ -n "$line" ]; then
    dst=$(printf "%s" "$line" | sed -n 's/.*"dst":"\([^"]*\)".*/\1/p')
    [ -f "$dst" ] && { echo "$dst"; return 0; }
  fi
  return 1
}

move_or_copy_to_central() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if same_device "$src" "$dst"; then
    # gleiches Volume → schnell: mv
    mv -f "$src" "$dst"
  else
    # anderes Volume → kopieren, dann Quelle löschen
    # Falls APFS: cp -c nutzt Clone, sonst normaler Copy
    if cp -c "$src" "$dst" 2>/dev/null; then
      :
    else
      cp "$src" "$dst"
    fi
    rm -f "$src"
  fi
  MOVED=$((MOVED+1))
}

collect_one() {
  local src="$1"
  FOUND=$((FOUND+1))

  # schnelle Negativfilter
  if [ ! -f "$src" ]; then
    SKIPPED_OTHER=$((SKIPPED_OTHER+1)); return
  fi

  # in Benutzung?
  if is_in_use "$src"; then
    log "⏩ in use, skip: $src"
    SKIPPED_INUSE=$((SKIPPED_INUSE+1)); return
  fi

  # Zielpfad
  local dst; dst="$(central_path_for "$src")"
  local hash; hash="$(sha256_of "$src")"

  # dedup?
  local existing
  if existing="$(dedup_match_in_central "$hash")"; then
    # bereits identischer Content im Zentralordner
    safe_mklink "$existing" "$src"
    write_manifest_line "$src" "$existing" "$hash" "dedup-link"
    DEDUPED=$((DEDUPED+1))
    return
  fi

  # falls Datei schon im Ziel liegt → nur Symlink zurück schreiben (idempotent)
  if [ "$(cd "$(dirname "$src")" && pwd)" = "$(cd "$(dirname "$dst")" && pwd)" ] \
     && [ "$(basename "$src")" = "$(basename "$dst")" ]; then
    # schon zentral → nichts verschieben, aber evtl. Link an Ursprungsort fehlt (hier keiner)
    write_manifest_line "$src" "$dst" "$hash" "already-central"
    return
  fi

  move_or_copy_to_central "$src" "$dst"
  write_manifest_line "$src" "$dst" "$hash" "moved"
  safe_mklink "$dst" "$src"
}

collect_and_link() {
  ensure_dirs
  log "=== Sammeln & Verlinken gestartet ==="

  # Kandidaten einsammeln
  # (lesen Zeile für Zeile; keine Bash-4-Features)
  find_candidates | while IFS= read -r file; do
    # Filter: ignoriere offensichtliche Nicht-Modelle (z.B. Firmware, Photos caches)
    low="$(echo "$file" | tr '[:upper:]' '[:lower:]')"
    case "$low" in
      *photoslibrary*|*instantview.app*|*firmware*|*/isolinux/*|*.bin) 
        # .bin lassen wir weiter durch die classifier-Heuristik (könnte LLM sein)
        :
        ;;
    esac
    collect_one "$file"
  done

  log "=== Fertig ==="
  summarize
}

make_workcopy() {
  local model_name_or_path="$1"
  local workdir="$2"

  # finde Zieldatei im CENTRAL, wenn nur Name übergeben wurde
  local src="$model_name_or_path"
  if [ ! -f "$src" ]; then
    # Suche im CENTRAL
    src=$(find "$CENTRAL" -type f -name "$(basename "$model_name_or_path")" 2>/dev/null | head -n 1 || true)
    [ -n "$src" ] && [ -f "$src" ] || { echo "❌ Modell nicht gefunden: $model_name_or_path"; exit 1; }
  fi

  mkdir -p "$workdir"
  local dst="$workdir/$(basename "$src")"

  # Versuche APFS-Clone
  if cp -c "$src" "$dst" 2>/dev/null; then
    echo "✔ APFS-Clone erstellt: $dst"
  else
    # Fallback: rsync (preserve attrs)
    rsync -a "$src" "$dst"
    echo "✔ Kopie erstellt: $dst"
  fi
  echo "Hinweis: Working-Copy ist unabhängig – Änderungen wirken NICHT auf das Zentralmodell."
}

set_readonly() {
  [ -d "$CENTRAL" ] || { echo "Zentralordner fehlt: $CENTRAL"; exit 1; }
  # Nur Dateien schreibschützen, nicht die Ordner (damit neue Links/Unterordner möglich bleiben)
  find "$CENTRAL" -type f -exec chmod a-w {} \; 2>/dev/null || true
  echo "✔ Modelle Read-Only gesetzt in: $CENTRAL"
}

set_writable() {
  [ -d "$CENTRAL" ] || { echo "Zentralordner fehlt: $CENTRAL"; exit 1; }
  find "$CENTRAL" -type f -exec chmod u+w {} \; 2>/dev/null || true
  echo "✔ Schreibschutz entfernt (Owner write) in: $CENTRAL"
}

usage() {
  cat <<'USAGE'
Usage:
  setup_central_models.sh --setup [--full-scan] [--verbose]
  setup_central_models.sh --make-workcopy "<modellname|pfad>" <zielordner>
  setup_central_models.sh --readonly
  setup_central_models.sh --writable
  setup_central_models.sh --menu

Tipps:
  --setup          Einsammeln & Verlinken aus bekannten App-Dirs
  --full-scan      Zusätzlich komplettes $HOME (ohne CENTRAL) durchsuchen
  --verbose        Laufende Ausgabe
  --menu           Interaktives Menü (auch bei Aufruf ohne Argumente)
USAGE
}

# ===========================
# Interaktives Menü (Bash 3.2)
# ===========================
run_menu() {
  ensure_dirs
  echo "──────────────── Model Manager Menü ────────────────"
  echo "  0) ALLES einsammeln & verlinken (Full-Scan + verbose)"
  echo "  1) Einsammeln & verlinken (schnell)"
  echo "  2) Trainings-Working-Copy anlegen"
  echo "  3) Zentralordner READ-ONLY schalten"
  echo "  4) Zentralordner wieder SCHREIBBAR schalten"
  echo "  q) Beenden"
  echo "────────────────────────────────────────────────────"
  printf "Auswahl: "
  read choice
  case "$choice" in
    0) VERBOSE=1; FULLSCAN=1; collect_and_link ;;
    1) VERBOSE=0; FULLSCAN=0; collect_and_link ;;
    2)
      echo "Dateiname ODER kompletter Pfad zum Modell:"
      read MODEL_ARG
      echo "Zielordner für Working-Copy:"
      read DEST_ARG
      [ -n "${MODEL_ARG:-}" ] && [ -n "${DEST_ARG:-}" ] || { echo "❌ Eingaben unvollständig."; exit 1; }
      make_workcopy "$MODEL_ARG" "$DEST_ARG"
      ;;
    3) set_readonly ;;
    4) set_writable ;;
    q|Q) exit 0 ;;
    *) echo "❌ Ungültige Auswahl."; exit 1 ;;
  esac
}

# ===========================
# Argument-Parsing
# ===========================
if [ $# -eq 0 ] || [ "${1:-}" = "--menu" ]; then
  run_menu
  exit 0
fi

CMD=""
MODEL_ARG=""
DEST_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --setup)        CMD="setup" ;;
    --full-scan)    FULLSCAN=1 ;;
    --verbose)      VERBOSE=1 ;;
    --make-workcopy) CMD="workcopy"; shift; MODEL_ARG="${1:-}"; shift; DEST_ARG="${1:-}";;
    --readonly)     CMD="readonly" ;;
    --writable)     CMD="writable" ;;
    --help|-h)      usage; exit 0 ;;
    *) echo "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
  shift || true
done

# ===========================
# Dispatch
# ===========================
case "${CMD:-}" in
  setup)       collect_and_link ;;
  workcopy)
    [ -n "${MODEL_ARG:-}" ] && [ -n "${DEST_ARG:-}" ] || { echo "❌ --make-workcopy braucht 2 Argumente."; usage; exit 1; }
    make_workcopy "$MODEL_ARG" "$DEST_ARG"
    ;;
  readonly)    set_readonly ;;
  writable)    set_writable ;;
  *)           usage; exit 1 ;;
esac
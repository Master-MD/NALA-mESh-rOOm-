cat > model_gc.command <<'EOF'
#!/bin/zsh
set -euo pipefail
CENTRAL="$HOME/AI_Models"
ARCHIVE="$CENTRAL/_Archive"
DRY=1; ZIP=0; KEEP_MONTHS=6
while [[ $# -gt 0 ]]; do case "$1" in --apply) DRY=0;; --zip) ZIP=1;; --months) KEEP_MONTHS="${2:-6}"; shift;; esac; shift || true; done
types=(-name "*.gguf" -o -name "*.safetensors" -o -name "*.ckpt" -o -name "*.pt" -o -name "*.pth" -o -name "*.onnx" -o -name "*.bin" -o -name "*.ggml" -o -name "*.mpt" -o -name "*.tflite")
mapfile -t FILES < <(find "$CENTRAL" -type f \( "${types[@]}" \) -print 2>/dev/null)
mkdir -p "$ARCHIVE"; todo_list="$(mktemp)"; typeset -A HASHMAP
cutoff=$(date -v -"${KEEP_MONTHS}"m +%s 2>/dev/null || python3 - <<PY
import time;print(int(time.time()-30*24*3600*${KEEP_MONTHS}))
PY
)
for p in "${FILES[@]}"; do h="$(shasum -a 256 "$p" | awk '{print $1}')"; HASHMAP["$h"]="${HASHMAP["$h"]}$p"$'\n'; done
is_referenced(){ local t="$1"; local ref=( "$HOME/Library/Application Support/Jan" "$HOME/ComfyMeshroom/ComfyUI/models" "$HOME/LLMStudio/models" ); for d in "${ref[@]}"; do [[ -d "$d" ]] || continue; while IFS= read -r -d '' L; do T="$(readlink "$L" 2>/dev/null || true)"; [[ "$T" == "$t" ]] && return 0; done < <(find "$d" -type l -print0 2>/dev/null); done; return 1; }
for h in "${!HASHMAP[@]}"; do
  mapfile -t arr <<<"${HASHMAP["$h"]}"
  IFS=$'\n' arr=($(for f in "${arr[@]}"; do echo "$(stat -f %m "$f" 2>/dev/null || echo 0) $f"; done | sort -rn | cut -d' ' -f2-))
  for ((i=1;i<${#arr[@]};i++)); do f="${arr[$i]}"; is_referenced "$f" || echo "$f" >> "$todo_list"; done
  for f in "${arr[@]}"; do mt="$(stat -f %m "$f" 2>/dev/null || echo 0)"; (( mt<cutoff )) && { is_referenced "$f" || echo "$f" >> "$todo_list"; }; done
done
echo "[i] Archivkandidaten:"; sort -u "$todo_list" | sed 's/^/  - /'
(( DRY==1 )) && { echo "[DRY] Nichts verschoben. Starte mit --apply."; exit 0; }
moved=0; zipped=0; while IFS= read -r f; do [[ -f "$f" ]] || continue; rel="${f#$CENTRAL/}"; destdir="$ARCHIVE/$(dirname "$rel")"; mkdir -p "$destdir"; mv -n "$f" "$destdir/"; ((moved++)); if ((ZIP==1)); then cd "$destdir"; bn="$(basename "$f")"; /usr/bin/zip -q -n .zip "${bn}.zip" "$bn" && rm -f "$bn" && (( zipped++ )); fi; done < <(sort -u "$todo_list")
echo "[OK] Archiv fertig. Moved=$moved, Zipped=$zipped"
EOF
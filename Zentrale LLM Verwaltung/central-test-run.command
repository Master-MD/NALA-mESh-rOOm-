#!/bin/zsh
set -euo pipefail

# Ordner dieser Datei
DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SCRIPT="$DIR/setup_central_models.sh"

# Setup-Script auffindbar machen
if [[ ! -f "$SCRIPT" ]]; then
  echo "[ERR] setup_central_models.sh nicht im gleichen Ordner gefunden: $DIR"
  exit 2
fi

# Eventuelle Windows-CRLFs entfernen, Quarantäne weg, ausführbar machen
command -v perl >/dev/null 2>&1 && perl -i -pe 's/\r$//' "$SCRIPT" || true
xattr -d com.apple.quarantine "$SCRIPT" 2>/dev/null || true
chmod +x "$SCRIPT"

# Lauf starten
echo "=== Sammeln & Verlinken gestartet ==="
"$SCRIPT" --setup --full-scan --verbose || true

CENTRAL="$HOME/AI_Models"
LOG="$CENTRAL/.last_run.log"
OUT_JSON="$DIR/last_summary.json"
HIST="$DIR/summary_history.jsonl"

# Fallbacks
found=0; moved=0; deduped=0; links=0; skipped_inuse=0; skipped_other=0

# Versuche, die letzte "Zusammenfassung" aus dem Log zu parsen
if [[ -f "$LOG" ]]; then
  # Schneide den letzten Block "Zusammenfassung" heraus (falls vorhanden)
  block="$(awk '/^──────────────── Zusammenfassung/{flag=1;print;next} /^$/{if(flag){exit}} flag' "$LOG" | tail -n 200)"
  if [[ -n "$block" ]]; then
    # Werte ziehen (robust auf doppelte/mehrfache Leerzeichen)
    found="$(echo "$block"          | awk -F: '/Gefunden/{gsub(/^[ \t]+/,"",$2); print $2}'            | tr -d ' ' || echo 0)"
    moved="$(echo "$block"          | awk -F: '/Neu verschoben/{gsub(/^[ \t]+/,"",$2); print $2}'      | tr -d ' ' || echo 0)"
    deduped="$(echo "$block"        | awk -F: '/Duplikate zusammengeführt/{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d ' ' || echo 0)"
    links="$(echo "$block"          | awk -F: '/Symlinks aktualisiert/{gsub(/^[ \t]+/,"",$2); print $2}'| tr -d ' ' || echo 0)"
    skipped_inuse="$(echo "$block"  | awk -F: '/Übersprungen \(in Benutzung\)/{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d ' ' || echo 0)"
    skipped_other="$(echo "$block"  | awk -F: '/Übersprungen \(sonst\)/{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d ' ' || echo 0)"
  fi
fi

# Timestamp + JSON schreiben
ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
cat > "$OUT_JSON" <<JSON
{
  "timestamp": "$ts",
  "found": ${found:-0},
  "moved": ${moved:-0},
  "deduped": ${deduped:-0},
  "symlinks": ${links:-0},
  "skipped_inuse": ${skipped_inuse:-0},
  "skipped_other": ${skipped_other:-0},
  "central": "$CENTRAL"
}
JSON
echo "✅ Summary: $OUT_JSON"

# an History anhängen (JSONL)
mkdir -p "$DIR"
echo "{\"timestamp\":\"$ts\",\"found\":${found:-0},\"moved\":${moved:-0},\"deduped\":${deduped:-0},\"symlinks\":${links:-0},\"skipped_inuse\":${skipped_inuse:-0},\"skipped_other\":${skipped_other:-0}}" >> "$HIST"
echo "📜 History aktualisiert: $HIST"
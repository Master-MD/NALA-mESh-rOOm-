#!/bin/zsh
set -euo pipefail

DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
HIST="$DIR/summary_history.jsonl"
LAST="$DIR/last_summary.json"

rm -f "$HIST" "$LAST"
echo "✅ Zurückgesetzt: $(basename "$HIST"), $(basename "$LAST") (nur diese Dateien)."
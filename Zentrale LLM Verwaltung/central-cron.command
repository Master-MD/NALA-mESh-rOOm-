#!/bin/zsh
set -euo pipefail

DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
TEST_RUN="$DIR/central-test-run.command"
PLIST_DIR="$HOME/Library/LaunchAgents"
LABEL="com.central-model-hub.scan"
PLIST="$PLIST_DIR/$LABEL.plist"

usage() {
  cat <<U
Usage:
  $0 --install 6h|12h|24h
  $0 --uninstall
  $0 --status
  $0 --runnow
U
}

install_plist() {
  local hours="$1"
  local interval
  case "$hours" in
    6h)  interval=$((6*3600));;
    12h) interval=$((12*3600));;
    24h) interval=$((24*3600));;
    *) echo "Ungültiges Intervall: $hours (erlaubt: 6h,12h,24h)"; exit 1;;
  esac

  [[ -x "$TEST_RUN" ]] || { echo "[ERR] $TEST_RUN nicht gefunden/ausführbar"; exit 2; }
  mkdir -p "$PLIST_DIR"

  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>exec "$TEST_RUN"</string>
  </array>
  <key>StartInterval</key><integer>$interval</integer>
  <key>StandardOutPath</key><string>$HOME/AI_Models/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/AI_Models/launchd.err.log</string>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PL

  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "✅ Installiert & geladen: $PLIST  (Intervall=${hours})"
}

uninstall_plist() {
  if [[ -f "$PLIST" ]]; then
    launchctl unload "$PLIST" || true
    rm -f "$PLIST"
    echo "🗑️  Entfernt: $PLIST"
  else
    echo "ℹ️  Nicht installiert."
  fi
}

status_plist() {
  if launchctl list | grep -q "$LABEL"; then
    echo "✅ Läuft (launchctl list enthält $LABEL)"
  else
    echo "❌ Nicht geladen."
  fi
  [[ -f "$PLIST" ]] && echo "Plist: $PLIST" || echo "Plist fehlt."
}

runnow() {
  [[ -x "$TEST_RUN" ]] || { echo "[ERR] $TEST_RUN nicht gefunden/ausführbar"; exit 2; }
  exec "$TEST_RUN"
}

# -------- main --------
cmd="${1:-}"
case "$cmd" in
  --install)    install_plist "${2:-}";;
  --uninstall)  uninstall_plist;;
  --status)     status_plist;;
  --runnow)     runnow;;
  *) usage; exit 1;;
esac
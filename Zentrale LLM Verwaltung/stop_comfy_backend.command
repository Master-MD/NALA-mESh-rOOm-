#!/bin/zsh
set -euo pipefail
PORT="${1:-8188}"
pids=$(lsof -nP -iTCP:${PORT} -sTCP:LISTEN -t || true)
if [[ -n "${pids:-}" ]]; then
  echo "Kill: $pids"
  kill -9 $pids || true
else
  echo "Kein Prozess auf ${PORT}."
fi
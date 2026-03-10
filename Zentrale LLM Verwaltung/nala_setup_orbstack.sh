#!/usr/bin/env bash
set -Eeuo pipefail

# === NALA One-Click: OrbStack + Portainer (+Yacht optional) + Ollama + Dashy (optional) ===
# ARM/Apple Silicon only; no Rosetta required if images are arm64.

# -------- Helpers --------
log(){ printf "\033[1;36m[INFO]\033[0m %s\n" "$*"; }
ok(){  printf "\033[1;32m[OK]\033[0m   %s\n" "$*"; }
warn(){printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERR]\033[0m  %s\n" "$*" >&2; }

require_arm(){
  arch="$(uname -m)"
  if [[ "$arch" != "arm64" ]]; then
    err "Dieses Skript ist für Apple Silicon (arm64). Gefunden: $arch"
    exit 1
  fi
}

need(){
  command -v "$1" >/dev/null 2>&1 || return 1
}

ensure_brew(){
  if ! need brew; then
    log "Homebrew nicht gefunden – installiere…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
}

ensure_orbstack(){
  if ! command -v orb >/dev/null 2>&1; then
    log "OrbStack nicht gefunden – installiere via Homebrew Cask…"
    brew install --cask orbstack
  else
    ok "OrbStack bereits installiert."
  fi
  # Ensure Docker CLI is wired by OrbStack
  if ! command -v docker >/dev/null 2>&1; then
    err "docker CLI nicht im PATH. Starte OrbStack einmal manuell & prüfe Einstellungen."
    exit 1
  fi
}

# -------- Choices (with safe defaults) --------
PORTAINER=${PORTAINER:-yes}   # yes/no
YACHT=${YACHT:-no}            # yes/no
DASHY=${DASHY:-yes}           # yes/no
OLLAMA=${OLLAMA:-yes}         # yes/no
COMFYUI=${COMFYUI:-no}        # du hast ComfyUI lokal; Container default off
# Tailscale: wir überspringen den Container bewusst auf macOS/OrbStack
TAILSCALE=${TAILSCALE:-skip}

# -------- Paths --------
ROOT="${HOME}/NALA-docker"
DATA="${ROOT}/data"
ENV="${ROOT}/.env"
COMPOSE="${ROOT}/docker-compose.yml"

mkdir -p "$DATA"
touch "$ENV"

# -------- .env defaults --------
if ! grep -q "^TZ=" "$ENV" 2>/dev/null; then
  echo "TZ=Europe/Zurich" >> "$ENV"
fi

# -------- Compose writer --------
write_compose(){
  log "Erzeuge docker-compose.yml in ${ROOT} …"
  cat > "$COMPOSE" <<'YAML'
name: nala-stack
services:
YAML

  # ---- Portainer ----
  if [[ "$PORTAINER" == "yes" ]]; then
    cat >> "$COMPOSE" <<'YAML'
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
YAML
  fi

  # ---- Yacht (optional) ----
  if [[ "$YACHT" == "yes" ]]; then
    cat >> "$COMPOSE" <<'YAML'
  yacht:
    image: selfhostedpro/yacht:latest
    restart: unless-stopped
    ports:
      - "8001:8000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - yacht_data:/config
YAML
  fi

  # ---- Dashy (schöner als Homer) ----
  if [[ "$DASHY" == "yes" ]]; then
    mkdir -p "${DATA}/dashy"
    cat >> "$COMPOSE" <<'YAML'
  dashy:
    image: lissy93/dashy:latest
    restart: unless-stopped
    ports:
      - "8085:80"
    environment:
      - TZ=${TZ}
    volumes:
      - dashy_data:/app/public
YAML
  fi

  # ---- Ollama (ARM ready) ----
  if [[ "$OLLAMA" == "yes" ]]; then
    mkdir -p "${DATA}/ollama"
    cat >> "$COMPOSE" <<'YAML'
  ollama:
    image: ollama/ollama:latest
    restart: unless-stopped
    ports:
      - "11434:11434"
    environment:
      - TZ=${TZ}
    volumes:
      - ollama_data:/root/.ollama
YAML
  fi

  # ---- ComfyUI (optional Container, default off) ----
  if [[ "$COMFYUI" == "yes" ]]; then
    mkdir -p "${DATA}/comfyui/models" "${DATA}/comfyui/output" "${DATA}/comfyui/input"
    cat >> "$COMPOSE" <<'YAML'
  comfyui:
    image: ghcr.io/ai-dock/comfyui:latest
    restart: unless-stopped
    ports:
      - "8188:8188"
    environment:
      - TZ=${TZ}
    volumes:
      - comfy_models:/opt/ComfyUI/models
      - comfy_input:/opt/ComfyUI/input
      - comfy_output:/opt/ComfyUI/output
YAML
  fi

  # ---- Volumes ----
  cat >> "$COMPOSE" <<'YAML'
volumes:
  portainer_data:
  yacht_data:
  dashy_data:
  ollama_data:
  comfy_models:
  comfy_input:
  comfy_output:
YAML
}

# -------- Main --------
require_arm
log "Apple Silicon erkannt."
ensure_brew
ok "Homebrew bereit."
ensure_orbstack
ok "OrbStack & docker CLI bereit."

# Kurze Zusammenfassung der Auswahl
log "Auswahl:"
echo "  Portainer: $PORTAINER"
echo "  Yacht:     $YACHT"
echo "  Dashy:     $DASHY"
echo "  Ollama:    $OLLAMA"
echo "  ComfyUI:   $COMFYUI (du hast’s lokal; Container ist optional)"
echo "  Tailscale: $TAILSCALE (übersprungen – du nutzt die App)"

write_compose
ok "docker-compose.yml erstellt."

log "Stack starten…"
cd "$ROOT"
docker compose pull
docker compose up -d

ok "Fertig! URLs:"
[[ "$PORTAINER" == "yes" ]] && echo "  Portainer → http://localhost:9000"
[[ "$YACHT" == "yes"     ]] && echo "  Yacht     → http://localhost:8001"
[[ "$DASHY" == "yes"     ]] && echo "  Dashy     → http://localhost:8085"
[[ "$OLLAMA" == "yes"    ]] && echo "  Ollama    → http://localhost:11434 (API)"
[[ "$COMFYUI" == "yes"   ]] && echo "  ComfyUI   → http://localhost:8188"

echo
ok "Tipps:"
echo "  • Portainer erster Login: Benutzer anlegen, dann Stacks/Volumes/Networks bequem klicken."
echo "  • Modelle in Ollama ziehen: z.B. 'ollama run llava:latest' (ARM-ready)."
echo "  • Dashy konfigurieren: auf das UI gehen, Settings öffnen, eigenes Board/Theme bauen."
echo "  • Compose anpassen: ${ROOT}/docker-compose.yml  (Services ja/nein, Ports ändern etc.)"
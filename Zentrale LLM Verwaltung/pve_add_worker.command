cat > pve_add_worker.command <<'EOF'
#!/bin/zsh
set -euo pipefail
HOST="${1:-remote-ip-address}"
USER="${2:-root}"
PORT="${3:-8288}"
read -r -d '' REMOTE <<"EOS"
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
BASE="/opt/comfy-worker"; VENV="$BASE/venv"; REPO="$BASE/ComfyUI"
apt-get update -y
apt-get install -y git python3.12-venv python3-pip pkg-config ffmpeg
mkdir -p "$BASE"
test -x "$VENV/bin/python" || python3 -m venv "$VENV"
source "$VENV/bin/activate"
if [ ! -d "$REPO/.git" ]; then
  git clone https://github.com/comfyanonymous/ComfyUI "$REPO"
else
  git -C "$REPO" fetch --all -p
  git -C "$REPO" checkout master
  git -C "$REPO" pull --ff-only
fi
pip install -r "$REPO/requirements.txt" --upgrade
cat >/etc/systemd/system/comfy-worker.service <<UNIT
[Unit]
Description=ComfyUI Worker
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$REPO
Environment="PYTHONUNBUFFERED=1"
ExecStart=$VENV/bin/python $REPO/main.py --listen 0.0.0.0 --port __PORT__ --dont-print-server
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
sed -i "s/__PORT__/$PORT/g" /etc/systemd/system/comfy-worker.service
systemctl daemon-reload
systemctl enable --now comfy-worker.service
echo "[OK] Worker läuft auf 0.0.0.0:$PORT"
EOS
ssh -o StrictHostKeyChecking=no "$USER@$HOST" "PORT='$PORT' bash -s" <<<"$REMOTE"
EOF
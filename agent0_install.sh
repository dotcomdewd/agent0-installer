#!/usr/bin/env bash
set -euo pipefail

MODE="docker"
INSTALL_DIR="$HOME/agent-zero"
DATA_DIR="$HOME/agent0_data"
PORT="50001"
HOST="0.0.0.0"
CONTAINER_NAME="agent-zero"
REPO_URL="https://github.com/agent0ai/agent-zero.git"
PYTHON_BIN="python3"

usage() {
  cat <<EOF
Usage: $0 [--mode docker|native] [--dir PATH] [--data-dir PATH] [--port N] [--host IP] [--name NAME]

Options:
  --mode       docker (default) or native
  --dir        install directory for native mode (default: $INSTALL_DIR)
  --data-dir   data directory for docker volume mapping (default: $DATA_DIR)
  --port       host port (docker maps to container:80; native runs UI on this port) (default: $PORT)
  --host       bind host for native mode (default: $HOST)
  --name       docker container name (default: $CONTAINER_NAME)
EOF
}

log() { echo -e "\n==> $*\n"; }
err() { echo -e "\nERROR: $*\n" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"; }

apt_update() {
  sudo apt-get update -y
}

apt_install_pkgs() {
  sudo apt-get install -y --no-install-recommends "$@"
}

apt_has_pkg() {
  # Returns 0 if package exists in apt cache
  apt-cache show "$1" >/dev/null 2>&1
}

install_docker_engine_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi

  log "Docker not found. Installing docker.io from APT..."
  need_cmd sudo
  need_cmd apt-get
  apt_update
  apt_install_pkgs docker.io

  # Compose is NOT required for Agent0 (we use docker run),
  # but we try to install it if available.
  log "Checking for compose packages..."
  if apt_has_pkg docker-compose-plugin; then
    log "Installing docker-compose-plugin (v2)..."
    apt_install_pkgs docker-compose-plugin
  elif apt_has_pkg docker-compose; then
    log "docker-compose-plugin not available; installing docker-compose (v1)..."
    apt_install_pkgs docker-compose
  else
    log "No compose package available in APT. Continuing without Docker Compose (not required)."
  fi

  log "Enabling and starting Docker service"
  sudo systemctl enable --now docker || true

  # Sanity check
  if ! sudo docker ps >/dev/null 2>&1; then
    log "Docker daemon started, but current user may not have permission."
    log "You can either run docker with sudo, or add your user to docker group:"
    echo "  sudo usermod -aG docker $USER"
    echo "  (then log out/in)"
  fi
}

docker_install() {
  log "Docker install selected"
  install_docker_engine_if_missing
  need_cmd docker

  log "Pulling official Agent Zero image: agent0ai/agent-zero"
  sudo docker pull agent0ai/agent-zero:latest

  mkdir -p "$DATA_DIR"

  if sudo docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    log "Existing container '$CONTAINER_NAME' found. Recreating..."
    sudo docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    sudo docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi

  log "Running container '$CONTAINER_NAME' on port $PORT (host) -> 80 (container)"
  log "Persisting data: $DATA_DIR -> /a0/usr"
  sudo docker run -d \
    --name "$CONTAINER_NAME" \
    -p "$PORT:80" \
    -v "$DATA_DIR:/a0/usr" \
    agent0ai/agent-zero:latest

  log "Done."
  echo "Open: http://localhost:$PORT"
  echo "Logs: sudo docker logs -f $CONTAINER_NAME"
}

# Native install kept here in case you want it later
install_host_deps_native() {
  apt_update
  apt_install_pkgs \
    ca-certificates curl git \
    build-essential pkg-config \
    $PYTHON_BIN python3-venv python3-dev \
    ffmpeg \
    poppler-utils \
    tesseract-ocr libtesseract-dev libleptonica-dev \
    libxml2-dev libxslt1-dev zlib1g-dev \
    libjpeg-dev libpng-dev \
    libffi-dev libssl-dev \
    libsndfile1 \
    libglib2.0-0 libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
    libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libasound2
}

ensure_venv_and_pip() {
  local venv_dir="$1"
  log "Creating/using venv: $venv_dir"
  $PYTHON_BIN -m venv "$venv_dir"
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
}

native_install() {
  log "Native install selected"
  need_cmd sudo
  need_cmd apt-get
  need_cmd $PYTHON_BIN
  install_host_deps_native

  if [ ! -d "$INSTALL_DIR/.git" ]; then
    log "Cloning repo to: $INSTALL_DIR"
    git clone "$REPO_URL" "$INSTALL_DIR"
  else
    log "Repo already present. Pulling latest in: $INSTALL_DIR"
    git -C "$INSTALL_DIR" pull --ff-only
  fi

  cd "$INSTALL_DIR"
  ensure_venv_and_pip "$INSTALL_DIR/.venv"

  log "Installing Python requirements (venv)"
  pip install -r requirements.txt

  log "Installing Playwright Chromium browser"
  playwright install chromium

  log "Starting Agent Zero UI on http://$HOST:$PORT"
  nohup python run_ui.py --host="$HOST" --port="$PORT" > agent0-ui.log 2>&1 &

  log "Done. Logs: $INSTALL_DIR/agent0-ui.log"
  echo "Open: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo "$HOST"):$PORT"
}

# args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --data-dir) DATA_DIR="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --name) CONTAINER_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1 (use --help)" ;;
  esac
done

case "$MODE" in
  docker) docker_install ;;
  native) native_install ;;
  *) err "Invalid --mode '$MODE' (must be docker or native)" ;;
esac

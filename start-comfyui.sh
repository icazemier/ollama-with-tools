#!/usr/bin/env bash
#
# start-comfyui.sh — Bootstrap and start ComfyUI natively (Apple Silicon / MPS)
#
# Idempotent: on first run, installs ComfyUI, creates a venv, installs
# dependencies, downloads the default SDXL checkpoint. On subsequent runs,
# just starts the server (or skips if already running).
#
# Why native? Docker on Mac has no Metal access — image gen would be CPU-only.
# Open WebUI (in Docker) reaches this via host.docker.internal:8188.
#
set -euo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-$HOME/ComfyUI}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_LOG="${COMFYUI_LOG:-$COMFYUI_DIR/comfyui.log}"
COMFYUI_PID_FILE="${COMFYUI_PID_FILE:-$COMFYUI_DIR/comfyui.pid}"
COMFYUI_PYTHON="${COMFYUI_PYTHON:-python3.12}"
COMFYUI_DEFAULT_MODEL_URL="${COMFYUI_DEFAULT_MODEL_URL:-https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors}"
COMFYUI_DEFAULT_MODEL_NAME="${COMFYUI_DEFAULT_MODEL_NAME:-sd_xl_base_1.0.safetensors}"

# Already running? (responsive on the port)
if curl -sf "http://127.0.0.1:${COMFYUI_PORT}/system_stats" > /dev/null 2>&1; then
    echo "ComfyUI already running on port ${COMFYUI_PORT}"
    exit 0
fi

# ── Bootstrap: clone ComfyUI ─────────────────────────────────
if [ ! -d "$COMFYUI_DIR" ]; then
    echo "ComfyUI not found at $COMFYUI_DIR — cloning..."
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
fi

# ── Bootstrap: create venv ───────────────────────────────────
if [ ! -f "$COMFYUI_DIR/venv/bin/activate" ]; then
    if ! command -v "$COMFYUI_PYTHON" > /dev/null 2>&1; then
        echo "Error: $COMFYUI_PYTHON not found. Install with: brew install python@3.12"
        exit 1
    fi
    echo "Creating Python venv at $COMFYUI_DIR/venv..."
    "$COMFYUI_PYTHON" -m venv "$COMFYUI_DIR/venv"
fi

# ── Bootstrap: install dependencies ──────────────────────────
# shellcheck disable=SC1091
source "$COMFYUI_DIR/venv/bin/activate"

if ! python -c "import torch" 2>/dev/null; then
    echo "Installing PyTorch (with MPS support for Apple Silicon)..."
    pip install --quiet --upgrade pip
    pip install --quiet torch torchvision torchaudio
fi

if ! python -c "import comfy" 2>/dev/null && [ ! -f "$COMFYUI_DIR/.deps_installed" ]; then
    echo "Installing ComfyUI requirements..."
    pip install --quiet -r "$COMFYUI_DIR/requirements.txt"
    touch "$COMFYUI_DIR/.deps_installed"
fi

# ── Bootstrap: download default checkpoint ───────────────────
CKPT_DIR="$COMFYUI_DIR/models/checkpoints"
mkdir -p "$CKPT_DIR"
if [ ! -f "$CKPT_DIR/$COMFYUI_DEFAULT_MODEL_NAME" ]; then
    echo "Downloading default checkpoint ($COMFYUI_DEFAULT_MODEL_NAME, ~6.5 GB)..."
    echo "This is a one-time download. Skip with: touch $CKPT_DIR/.skip_default"
    if [ ! -f "$CKPT_DIR/.skip_default" ]; then
        curl -L -o "$CKPT_DIR/$COMFYUI_DEFAULT_MODEL_NAME" "$COMFYUI_DEFAULT_MODEL_URL"
    fi
fi

# ── Start the server ─────────────────────────────────────────
echo "Starting ComfyUI on port ${COMFYUI_PORT}..."

cd "$COMFYUI_DIR"
nohup python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" \
    > "$COMFYUI_LOG" 2>&1 &
echo $! > "$COMFYUI_PID_FILE"

for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${COMFYUI_PORT}/system_stats" > /dev/null 2>&1; then
        echo "ComfyUI is up (PID $(cat "$COMFYUI_PID_FILE"))."
        echo "Logs: $COMFYUI_LOG"
        exit 0
    fi
    sleep 1
done

echo "Error: ComfyUI did not start within 30s. Check logs at $COMFYUI_LOG"
exit 1

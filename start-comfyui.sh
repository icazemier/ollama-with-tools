#!/usr/bin/env bash
#
# start-comfyui.sh — Bootstrap and start ComfyUI natively (Apple Silicon / MPS)
#
# Idempotent: on first run, installs ComfyUI, creates a venv, installs
# dependencies, downloads the default SDXL checkpoint. On subsequent runs,
# just starts the server (or skips if already running).
#
# On macOS: registers ComfyUI as a launchd user agent so it auto-starts
# on login (same pattern as Ollama). The plist is generated from current
# settings and reinstalled whenever the config changes (e.g. COMFYUI_PORT).
#
# On Linux: falls back to nohup daemonisation.
#
# Why native? Docker on Mac has no Metal access — image gen would be CPU-only.
# Open WebUI (in Docker) reaches this via host.docker.internal:8188.
#
set -euo pipefail

OS="$(uname -s)"
COMFYUI_DIR="${COMFYUI_DIR:-$HOME/ComfyUI}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_LOG="${COMFYUI_LOG:-$COMFYUI_DIR/comfyui.log}"
COMFYUI_PYTHON="${COMFYUI_PYTHON:-python3.12}"

# IMAGE_MODEL picks the default checkpoint and (in start.sh) the workflow
# preset. Direct overrides via COMFYUI_DEFAULT_MODEL_{NAME,URL} still win, so
# advanced users can drop in any .safetensors and bypass the presets.
IMAGE_MODEL="${IMAGE_MODEL:-sdxl}"

case "$IMAGE_MODEL" in
    sdxl)
        : "${COMFYUI_DEFAULT_MODEL_NAME:=sd_xl_base_1.0.safetensors}"
        : "${COMFYUI_DEFAULT_MODEL_URL:=https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors}"
        _expected_size="~6.5 GB"
        ;;
    flux-schnell)
        : "${COMFYUI_DEFAULT_MODEL_NAME:=flux1-schnell-fp8.safetensors}"
        : "${COMFYUI_DEFAULT_MODEL_URL:=https://huggingface.co/Comfy-Org/flux1-schnell/resolve/main/flux1-schnell-fp8.safetensors}"
        _expected_size="~17 GB"
        ;;
    flux-dev)
        # flux-dev is gated on HuggingFace — set HF_TOKEN to a token that has
        # accepted the license at https://huggingface.co/black-forest-labs/FLUX.1-dev
        : "${COMFYUI_DEFAULT_MODEL_NAME:=flux1-dev-fp8.safetensors}"
        : "${COMFYUI_DEFAULT_MODEL_URL:=https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors}"
        _expected_size="~17 GB"
        ;;
    *)
        echo "Error: unknown IMAGE_MODEL='$IMAGE_MODEL'. Use sdxl, flux-schnell, or flux-dev."
        exit 1
        ;;
esac
export COMFYUI_DEFAULT_MODEL_NAME COMFYUI_DEFAULT_MODEL_URL

PLIST_LABEL="local.comfyui.server"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

# ── Generates the launchd plist from current settings ────────
generate_comfyui_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  ComfyUI image generation server — Metal/MPS-accelerated, Apple Silicon.
  Runs natively (not in Docker) because Docker on macOS has no Metal access.
  Open WebUI reaches it via host.docker.internal:${COMFYUI_PORT}.

  Managed by start-comfyui.sh — do not edit manually (changes will be overwritten).

  To load/unload manually:
    launchctl load   ${PLIST_PATH}
    launchctl unload ${PLIST_PATH}
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${COMFYUI_DIR}/venv/bin/python</string>
        <string>main.py</string>
        <string>--listen</string>
        <string>0.0.0.0</string>
        <string>--port</string>
        <string>${COMFYUI_PORT}</string>
        <string>--cpu-vae</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>

    <key>KeepAlive</key>
    <true/>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${COMFYUI_DIR}/comfyui.log</string>
    <key>StandardErrorPath</key>
    <string>${COMFYUI_DIR}/comfyui.log</string>

    <key>WorkingDirectory</key>
    <string>${COMFYUI_DIR}</string>
</dict>
</plist>
EOF
}

# ── macOS: install/update launchd plist ──────────────────────
# Reinstalls if content changed (e.g. COMFYUI_PORT updated in .env),
# unloading first so launchd picks up the new file.
if [ "$OS" = "Darwin" ]; then
    NEW_PLIST="$(generate_comfyui_plist)"
    EXISTING_PLIST="$(cat "$PLIST_PATH" 2>/dev/null || true)"
    if [ "$NEW_PLIST" != "$EXISTING_PLIST" ]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        mkdir -p "$(dirname "$PLIST_PATH")"
        printf '%s\n' "$NEW_PLIST" > "$PLIST_PATH"
        echo "Installed ComfyUI launchd agent: $PLIST_PATH"
    fi
fi

# Detect whether ComfyUI is already responsive — but don't exit yet, we may
# still need to download a newly-selected checkpoint (e.g. user switched
# IMAGE_MODEL from sdxl to flux-schnell on a running instance).
COMFYUI_RUNNING=0
if curl -sf "http://127.0.0.1:${COMFYUI_PORT}/system_stats" > /dev/null 2>&1; then
    COMFYUI_RUNNING=1
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
# Skipped when ComfyUI is already running — venv is in use, deps are present.
if [ "$COMFYUI_RUNNING" = "0" ]; then
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
fi

# ── Bootstrap: download default checkpoint ───────────────────
CKPT_DIR="$COMFYUI_DIR/models/checkpoints"
mkdir -p "$CKPT_DIR"
if [ ! -f "$CKPT_DIR/$COMFYUI_DEFAULT_MODEL_NAME" ] && [ ! -f "$CKPT_DIR/.skip_default" ]; then
    echo "Downloading checkpoint for IMAGE_MODEL=$IMAGE_MODEL ($COMFYUI_DEFAULT_MODEL_NAME, $_expected_size)..."
    echo "This is a one-time download. Skip with: touch $CKPT_DIR/.skip_default"
    _curl_auth=()
    if [ -n "${HF_TOKEN:-}" ]; then
        _curl_auth=(-H "Authorization: Bearer ${HF_TOKEN}")
    fi
    # ${arr[@]+"${arr[@]}"} = expand iff the array has elements. Plain
    # "${arr[@]}" would trip `set -u` on macOS bash 3.2 when empty.
    if ! curl -fL --retry 3 ${_curl_auth[@]+"${_curl_auth[@]}"} -o "$CKPT_DIR/$COMFYUI_DEFAULT_MODEL_NAME" "$COMFYUI_DEFAULT_MODEL_URL"; then
        rm -f "$CKPT_DIR/$COMFYUI_DEFAULT_MODEL_NAME"
        echo "Error: checkpoint download failed."
        if [ "$IMAGE_MODEL" = "flux-dev" ] && [ -z "${HF_TOKEN:-}" ]; then
            echo "       flux-dev is gated. Accept the license at"
            echo "       https://huggingface.co/black-forest-labs/FLUX.1-dev and set HF_TOKEN in .env."
        fi
        exit 1
    fi
fi

# ── Start the server ─────────────────────────────────────────
# Already running? Done — checkpoint is on disk, ComfyUI will load it on
# first request. (No restart needed: ComfyUI scans models/checkpoints/ live.)
if [ "$COMFYUI_RUNNING" = "1" ]; then
    echo "ComfyUI already running on port ${COMFYUI_PORT} (checkpoint ready: $COMFYUI_DEFAULT_MODEL_NAME)"
    exit 0
fi

if [ "$OS" = "Darwin" ]; then
    echo "Starting ComfyUI via launchd (port ${COMFYUI_PORT})..."
    launchctl load "$PLIST_PATH"
else
    COMFYUI_PID_FILE="${COMFYUI_PID_FILE:-$COMFYUI_DIR/comfyui.pid}"
    echo "Starting ComfyUI on port ${COMFYUI_PORT}..."
    cd "$COMFYUI_DIR"
    nohup python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" --cpu-vae \
        > "$COMFYUI_LOG" 2>&1 &
    echo $! > "$COMFYUI_PID_FILE"
fi

for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${COMFYUI_PORT}/system_stats" > /dev/null 2>&1; then
        echo "ComfyUI is up."
        echo "Logs: $COMFYUI_LOG"
        exit 0
    fi
    sleep 1
done

echo "Error: ComfyUI did not start within 30s. Check logs at $COMFYUI_LOG"
exit 1

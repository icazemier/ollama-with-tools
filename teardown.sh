#!/usr/bin/env bash
#
# teardown.sh — Remove the local AI stack (data and/or installation)
#
# Levels (additive):
#
#   default   Remove Docker containers and volumes. Deletes chat history
#             and any models downloaded in Docker mode. Leaves ComfyUI,
#             native Ollama models, and TLS certs intact.
#
#   --full    Also unregisters ComfyUI from launchd and deletes ~/ComfyUI
#             (venv, SDXL checkpoint, all image generation data). Use when
#             you want a completely fresh image-gen setup on next start.
#
#   --nuclear Everything in --full, plus removes all native Ollama models
#             and the TLS certs. After this, ./start.sh rebuilds from scratch
#             (re-downloads everything). The project files themselves are kept.
#
# Usage:
#   ./teardown.sh             # Docker containers + volumes only
#   ./teardown.sh --full      # + ComfyUI installation
#   ./teardown.sh --nuclear   # + Ollama models + TLS certs
#   ./teardown.sh --help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    cat <<EOF
Usage: ./teardown.sh [--full] [--nuclear]

Remove the local AI stack. Levels are additive:

  (default)   Docker containers + volumes (chat history, Docker-mode models)
  --full      + ComfyUI launchd agent and ~/ComfyUI installation
  --nuclear   + all native Ollama models + TLS certs

After teardown, run ./start.sh to rebuild from scratch.
EOF
}

FULL=false
NUCLEAR=false

for arg in "$@"; do
    case "$arg" in
        --full)    FULL=true ;;
        --nuclear) FULL=true; NUCLEAR=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown flag: $arg"; echo "Run ./teardown.sh --help for usage."; exit 1 ;;
    esac
done

# ── Load settings ────────────────────────────────────────────
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi
OLLAMA_MODE="${OLLAMA_MODE:-native}"
COMFYUI_DIR="${COMFYUI_DIR:-$HOME/ComfyUI}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"

OS="$(uname -s)"
PLIST_LABEL="local.comfyui.server"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

# ── Confirm ──────────────────────────────────────────────────
echo "This will remove:"
echo "  - Docker containers and volumes (chat history, Docker-mode Ollama models)"
if [ "$FULL" = true ]; then
    echo "  - ComfyUI launchd agent + $COMFYUI_DIR"
fi
if [ "$NUCLEAR" = true ]; then
    echo "  - All native Ollama models"
    echo "  - TLS certificates (certs/)"
fi
echo ""
read -r -p "Continue? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi
echo ""

# ── Step 1: Stop and remove Docker stack ─────────────────────
echo "Removing Docker containers and volumes..."
if [ "$OLLAMA_MODE" = "docker" ]; then
    docker compose --profile docker down -v 2>/dev/null || docker compose down -v 2>/dev/null || true
else
    docker compose down -v 2>/dev/null || true
fi
echo "Done."
echo ""

# ── Step 2 (--full): Remove ComfyUI ──────────────────────────
if [ "$FULL" = true ]; then
    if [ "$OS" = "Darwin" ] && [ -f "$PLIST_PATH" ]; then
        echo "Unregistering ComfyUI launchd agent..."
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        echo "  Removed $PLIST_PATH"
    fi

    # Belt & braces: stop any running process on the port
    PORT_PID="$(lsof -tiTCP:"$COMFYUI_PORT" -sTCP:LISTEN 2>/dev/null || true)"
    if [ -n "$PORT_PID" ]; then
        kill "$PORT_PID" 2>/dev/null || true
    fi

    if [ -d "$COMFYUI_DIR" ]; then
        echo "Removing ComfyUI installation ($COMFYUI_DIR)..."
        rm -rf "$COMFYUI_DIR"
        echo "  Done."
    fi
    echo ""
fi

# ── Step 3 (--nuclear): Remove Ollama models + certs ─────────
if [ "$NUCLEAR" = true ]; then
    if command -v ollama > /dev/null 2>&1 && ollama list > /dev/null 2>&1; then
        echo "Removing all Ollama models..."
        while IFS= read -r model; do
            [ -n "$model" ] && ollama rm "$model" && echo "  Removed $model"
        done < <(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')
        echo "  Done."
    fi

    if [ -d certs ] && [ "$(ls -A certs)" ]; then
        echo "Removing TLS certificates..."
        rm -rf certs
        echo "  Done."
    fi
    echo ""
fi

# ── Summary ──────────────────────────────────────────────────
echo "Teardown complete."
echo ""
echo "Run ./start.sh to rebuild the stack from scratch."

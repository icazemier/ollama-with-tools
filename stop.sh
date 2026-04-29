#!/usr/bin/env bash
#
# stop.sh — Stop the local AI stack
#
# What this does:
#   Shuts down all Docker containers (Open WebUI, Sandbox, and in docker
#   mode also Ollama + proxy).
#
# What it does NOT do:
#   - It does NOT delete your downloaded models (stored in a Docker volume)
#   - It does NOT delete your chat history (stored in a Docker volume)
#   - It does NOT touch your shared folder
#   - In native mode, it does NOT stop the Ollama app on your host
#
# To start again:  ./start.sh
# To delete everything (models, history):  docker volume prune
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Load settings for mode detection
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi
OLLAMA_MODE="${OLLAMA_MODE:-native}"

echo "Stopping local AI stack..."
if [ "$OLLAMA_MODE" = "docker" ]; then
    docker compose --profile docker down
else
    docker compose down
fi

# Stop natively-running ComfyUI if present
if [ -x "./stop-comfyui.sh" ]; then
    ./stop-comfyui.sh
fi

echo ""
echo "Stack stopped. Volumes (models, chat history) are preserved."
echo "Run ./start.sh to restart."
if [ "$OLLAMA_MODE" = "native" ]; then
    echo ""
    echo "Note: Ollama is still running on your host (this is normal)."
    echo "To stop it: quit the Ollama app, or run 'pkill ollama'."
fi

#!/usr/bin/env bash
#
# stop-comfyui.sh — Stop the natively-running ComfyUI process
#
set -euo pipefail

COMFYUI_PID_FILE="${COMFYUI_PID_FILE:-$HOME/ComfyUI/comfyui.pid}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"

if [ -f "$COMFYUI_PID_FILE" ]; then
    PID="$(cat "$COMFYUI_PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping ComfyUI (PID $PID)..."
        kill "$PID"
        for _ in $(seq 1 10); do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        kill -9 "$PID" 2>/dev/null || true
    fi
    rm -f "$COMFYUI_PID_FILE"
fi

# Belt & braces: kill anything still bound to the port
PORT_PID="$(lsof -tiTCP:"$COMFYUI_PORT" -sTCP:LISTEN 2>/dev/null || true)"
if [ -n "$PORT_PID" ]; then
    echo "Killing remaining process on port $COMFYUI_PORT (PID $PORT_PID)..."
    kill "$PORT_PID" 2>/dev/null || true
fi

echo "ComfyUI stopped."

#!/usr/bin/env bash
#
# pull-models.sh — Download and manage AI models
#
# What this does:
#   1. Reads the model list from models.conf
#   2. Native mode: pulls models directly via your host's Ollama
#   3. Docker mode: spins up a TEMPORARY Ollama container that HAS internet
#      access to download models into a Docker volume
#   4. Checks which models are already downloaded (skips those — fast!)
#   5. Optionally removes models not in models.conf (--cleanup)
#
# Usage:
#   ./pull-models.sh              # Download missing models
#   ./pull-models.sh --cleanup    # Download missing + remove unused models
#
# Notes:
#   - Called automatically by start.sh — you usually don't need to run this directly
#   - Safe to run multiple times — already-downloaded models are skipped
#   - Large models (14B+) can be 8-20 GB — make sure you have disk space
#   - Edit models.conf to add or remove models, then re-run this script
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Parse flags ─────────────────────────────────────────────
CLEANUP=false
for arg in "$@"; do
    case "$arg" in
        --cleanup) CLEANUP=true ;;
        -h|--help)
            echo "Usage: ./pull-models.sh [--cleanup]"
            echo ""
            echo "Downloads AI models listed in models.conf."
            echo ""
            echo "Flags:"
            echo "  --cleanup    Also remove models NOT in models.conf to free disk space"
            exit 0
            ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

# ── Load settings ────────────────────────────────────────────
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi
OLLAMA_MODE="${OLLAMA_MODE:-native}"

# ── Read models.conf ─────────────────────────────────────────
MODELS_FILE="models.conf"

if [ ! -f "$MODELS_FILE" ]; then
    echo "Error: $MODELS_FILE not found."
    exit 1
fi

# Read model names, ignoring comments (#) and blank lines
# (compatible with Bash 3.2 — no mapfile)
MODELS=()
while IFS= read -r line; do
    # Trim whitespace
    line="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    [ -n "$line" ] && MODELS+=("$line")
done < <(grep -v '^\s*#' "$MODELS_FILE" | grep -v '^\s*$')

if [ ${#MODELS[@]} -eq 0 ] && [ "$CLEANUP" = false ]; then
    echo "No models found in $MODELS_FILE."
    exit 0
fi

# ── Helper: normalize model name ─────────────────────────────
# Ollama treats "llama3.1" as "llama3.1:latest" — normalize so
# comparisons work correctly.
normalize_model() {
    if echo "$1" | grep -q ':'; then
        echo "$1"
    else
        echo "$1:latest"
    fi
}

# ── Helper: check if a value is in a list ────────────────────
# (compatible with Bash 3.2 — no associative arrays)
list_contains() {
    local needle="$1"
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# ── Helper: run an ollama command (native or docker) ─────────
# In native mode: runs ollama directly on the host
# In docker mode: runs ollama inside the temporary container
CONTAINER_NAME="ollama-pull-tmp"

ollama_exec() {
    if [ "$OLLAMA_MODE" = "native" ]; then
        ollama "$@"
    else
        docker exec "$CONTAINER_NAME" ollama "$@"
    fi
}

# ── Docker mode: start temporary container ───────────────────
VOLUME_NAME="host-ai-locally_ollama-data"

if [ "$OLLAMA_MODE" = "docker" ]; then
    # Ensure the Docker volume exists for storing models
    docker volume create "$VOLUME_NAME" > /dev/null 2>&1 || true

    # Clean up any leftover temp container from a previous interrupted run
    docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true

    echo "Starting temporary Ollama container..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        -v "$VOLUME_NAME":/root/.ollama \
        ollama/ollama:latest > /dev/null

    # Wait up to 30 seconds for Ollama to be ready
    echo "Waiting for Ollama to be ready..."
    for i in $(seq 1 30); do
        if docker exec "$CONTAINER_NAME" ollama list > /dev/null 2>&1; then
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "Error: Ollama failed to start in time."
            docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
            exit 1
        fi
        sleep 1
    done
fi

# ── Check what's already installed ───────────────────────────
INSTALLED=()
while IFS= read -r m; do
    [ -n "$m" ] && INSTALLED+=("$m")
done < <(ollama_exec list 2>/dev/null | tail -n +2 | awk '{print $1}')

# ── Pull missing models ─────────────────────────────────────
PULL_FAILED=false
if [ ${#MODELS[@]} -gt 0 ]; then
    PULLED=0
    SKIPPED=0
    FAILED=()

    for model in "${MODELS[@]}"; do
        normalized=$(normalize_model "$model")
        if list_contains "$normalized" "${INSTALLED[@]+"${INSTALLED[@]}"}"; then
            echo "Already available: $model"
            SKIPPED=$((SKIPPED + 1))
        else
            echo ""
            echo "── Pulling: $model ──"
            if ollama_exec pull "$model"; then
                echo "Done: $model"
                PULLED=$((PULLED + 1))
            else
                echo "FAILED: $model"
                FAILED+=("$model")
            fi
        fi
    done

    echo ""
    echo "Models: $PULLED pulled, $SKIPPED already available, ${#FAILED[@]} failed."

    if [ ${#FAILED[@]} -gt 0 ]; then
        PULL_FAILED=true
        echo "Failed:"
        for model in "${FAILED[@]}"; do
            echo "  - $model"
        done
    fi
fi

# ── Cleanup: remove models not in models.conf ───────────────
if [ "$CLEANUP" = true ]; then
    echo ""
    echo "── Cleaning up unused models ──"

    # Build normalized list of expected models
    EXPECTED=()
    for model in "${MODELS[@]}"; do
        EXPECTED+=("$(normalize_model "$model")")
    done

    # Re-read installed list (may have changed after pulling)
    INSTALLED_NOW=()
    while IFS= read -r m; do
        [ -n "$m" ] && INSTALLED_NOW+=("$m")
    done < <(ollama_exec list 2>/dev/null | tail -n +2 | awk '{print $1}')

    REMOVED=0
    for installed_model in "${INSTALLED_NOW[@]+"${INSTALLED_NOW[@]}"}"; do
        if ! list_contains "$installed_model" "${EXPECTED[@]+"${EXPECTED[@]}"}"; then
            echo "Removing: $installed_model (not in models.conf)"
            ollama_exec rm "$installed_model" || echo "  Warning: failed to remove $installed_model"
            REMOVED=$((REMOVED + 1))
        fi
    done

    if [ "$REMOVED" -eq 0 ]; then
        echo "Nothing to clean up — all installed models are in models.conf."
    else
        echo "Removed $REMOVED unused model(s)."
    fi
fi

# ── Docker mode: stop temporary container ────────────────────
if [ "$OLLAMA_MODE" = "docker" ]; then
    echo ""
    echo "Stopping temporary container..."
    docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
fi

if [ "$PULL_FAILED" = true ]; then
    exit 1
fi

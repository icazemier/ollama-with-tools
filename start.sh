#!/usr/bin/env bash
#
# start.sh — Start the local AI stack
#
# What this does:
#   1. Copies .env.example to .env if you haven't created one yet
#   2. Reads your settings from .env (including OLLAMA_MODE)
#   3. Native mode: ensures Ollama is installed and running on your host
#   4. Docker mode: starts Ollama in an isolated container (no internet)
#   5. Wires optional bind mounts (shared folder, SSH keys, git config)
#   6. Ensures all models from models.conf are downloaded
#   7. Starts all containers
#
# Modes (set OLLAMA_MODE in .env):
#   "native"  = Ollama runs on your Mac with GPU acceleration (fast!)
#   "docker"  = Ollama runs in Docker, CPU-only but fully isolated
#
# Usage:
#   ./start.sh
#
# This is the only command you need. It handles everything:
#   - First run: downloads models, builds containers, starts the stack
#   - Subsequent runs: skips already-downloaded models, starts quickly
#   - Offline: works fine if models were previously downloaded
#   - After .env changes: picks up new settings automatically
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Detect platform ─────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin)
        case "$ARCH" in
            arm64) PLATFORM="macOS (Apple Silicon)" ;;
            *)     PLATFORM="macOS (Intel)" ;;
        esac
        ;;
    Linux)
        if command -v nvidia-smi > /dev/null 2>&1; then
            PLATFORM="Linux ($ARCH, NVIDIA GPU)"
        else
            PLATFORM="Linux ($ARCH)"
        fi
        ;;
    *)
        PLATFORM="$OS ($ARCH)"
        ;;
esac

# ── Step 1: Ensure .env exists ──────────────────────────────
if [ ! -f .env ]; then
    echo "No .env found — copying from .env.example"
    cp .env.example .env
fi

# Load settings
set -a
source .env
set +a

OLLAMA_MODE="${OLLAMA_MODE:-native}"

# ── Container engine (Colima) — patch daemon config ────────
# Colima's default Docker daemon config enables the containerd snapshotter,
# which hangs on multi-arch ghcr.io pulls (the Open WebUI image lives there).
# We force snapshotter=false in ~/.colima/default/colima.yaml so the daemon
# uses the classic overlay2 driver. Idempotent: only patches + restarts when
# the config differs.
if [ "$OS" = "Darwin" ] && command -v colima > /dev/null 2>&1; then
    COLIMA_CFG="$HOME/.colima/default/colima.yaml"
    if [ -f "$COLIMA_CFG" ] && ! grep -q "containerd-snapshotter: false" "$COLIMA_CFG"; then
        echo "Patching Colima config (disable containerd-snapshotter for ghcr.io pulls)..."
        # Replace `docker: {}` (Colima's default placeholder) or append a docker
        # section if missing. Uses perl for portable in-place editing on BSD/GNU.
        if grep -q "^docker: {}" "$COLIMA_CFG"; then
            perl -i -pe 's|^docker: \{\}$|docker:\n  features:\n    buildkit: true\n    containerd-snapshotter: false|' "$COLIMA_CFG"
        else
            printf '\ndocker:\n  features:\n    buildkit: true\n    containerd-snapshotter: false\n' >> "$COLIMA_CFG"
        fi
        if colima status > /dev/null 2>&1; then
            echo "Restarting Colima to apply daemon config..."
            colima restart > /dev/null 2>&1
        fi
    fi
    # Ensure Colima auto-starts at login (no-op if already enabled).
    if ! brew services list 2>/dev/null | grep -qE "^colima\s+started"; then
        brew services start colima > /dev/null 2>&1 || true
    fi
fi

# ── Install boot-stack launchd agent (macOS only) ────────────
# Registers boot-stack.sh as a login agent so the Docker stack comes
# up automatically after every reboot, power loss, or login — without
# needing to run start.sh manually each time.
BOOT_STACK_LABEL="local.ai-stack.boot"
BOOT_STACK_PLIST="$HOME/Library/LaunchAgents/${BOOT_STACK_LABEL}.plist"

generate_boot_stack_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  Brings up the Docker AI stack (Open WebUI + Caddy) after every login.
  Waits for Colima/Docker to be ready, then runs docker compose up -d and
  applies the ComfyUI DB patch if needed.

  Managed by start.sh — do not edit manually.

  To inspect logs: tail -f ${SCRIPT_DIR}/logs/boot-stack.log
  To disable:      launchctl unload ${BOOT_STACK_PLIST}
  To re-enable:    launchctl load   ${BOOT_STACK_PLIST}
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BOOT_STACK_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_DIR}/boot-stack.sh</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>

    <!-- Start at login -->
    <key>RunAtLoad</key>
    <true/>

    <!-- Restart only on failure (exit non-zero); stop once healthy (exit 0) -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <!-- Wait 30 s between retries so Docker has time to start -->
    <key>ThrottleInterval</key>
    <integer>30</integer>

    <!-- boot-stack.sh writes its own timestamped log to logs/boot-stack.log;
         stdout is silenced here to prevent launchd doubling every line. -->
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/logs/boot-stack.log</string>
</dict>
</plist>
EOF
}

if [ "$OS" = "Darwin" ]; then
    NEW_BOOT_PLIST="$(generate_boot_stack_plist)"
    EXISTING_BOOT_PLIST="$(cat "$BOOT_STACK_PLIST" 2>/dev/null || true)"
    if [ "$NEW_BOOT_PLIST" != "$EXISTING_BOOT_PLIST" ]; then
        mkdir -p "$(dirname "$BOOT_STACK_PLIST")"
        printf '%s\n' "$NEW_BOOT_PLIST" > "$BOOT_STACK_PLIST"
        launchctl unload "$BOOT_STACK_PLIST" 2>/dev/null || true
        launchctl load "$BOOT_STACK_PLIST"
        echo "Installed launchd agent: $BOOT_STACK_PLIST"
    fi
fi

echo "Platform: $PLATFORM"
echo "Ollama:   $OLLAMA_MODE mode"

case "$OLLAMA_MODE" in
    native)
        echo "          Ollama runs on your host with GPU acceleration."
        echo "          Open WebUI and Caddy run in Docker; ComfyUI runs natively."
        ;;
    docker)
        echo "          Everything runs in Docker. CPU-only but fully isolated."
        ;;
    *)
        echo "Error: OLLAMA_MODE must be 'native' or 'docker' (got: $OLLAMA_MODE)"
        exit 1
        ;;
esac
echo ""

# ── Step 2: Native mode — ensure Ollama is running and bound to 0.0.0.0 ──
# Why 0.0.0.0? Open WebUI runs in a container and reaches the host via
# host.docker.internal:11434. Ollama defaults to 127.0.0.1 only — Docker
# Desktop has magic routing that papers over this, but Colima/OrbStack do
# not, so the WebUI container can't reach Ollama unless it binds to all
# interfaces. We persist this via a launchd user agent that runs at login,
# and force-restart Ollama on this run if it's already bound to 127.0.0.1.
OLLAMA_ENV_LABEL="local.ollama-env"
OLLAMA_ENV_PLIST="$HOME/Library/LaunchAgents/${OLLAMA_ENV_LABEL}.plist"

generate_ollama_env_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  Sets OLLAMA_HOST=0.0.0.0:11434 in the launchd session environment so the
  Ollama Mac app, when started by its own launchd agent, binds to all
  interfaces. Required so containers (Open WebUI under Colima/OrbStack) can
  reach Ollama via host.docker.internal:11434.

  Managed by start.sh — do not edit manually.
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${OLLAMA_ENV_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/launchctl</string>
        <string>setenv</string>
        <string>OLLAMA_HOST</string>
        <string>0.0.0.0:11434</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
}

if [ "$OLLAMA_MODE" = "native" ]; then
    if ! command -v ollama > /dev/null 2>&1; then
        echo "Error: Ollama is not installed on your system."
        echo ""
        echo "Install it from: https://ollama.com/download"
        echo "Or switch to docker mode: set OLLAMA_MODE=docker in .env"
        exit 1
    fi

    # Install/update the launchd plist that sets OLLAMA_HOST at login.
    if [ "$OS" = "Darwin" ]; then
        NEW_PLIST="$(generate_ollama_env_plist)"
        EXISTING_PLIST="$(cat "$OLLAMA_ENV_PLIST" 2>/dev/null || true)"
        if [ "$NEW_PLIST" != "$EXISTING_PLIST" ]; then
            mkdir -p "$(dirname "$OLLAMA_ENV_PLIST")"
            printf '%s\n' "$NEW_PLIST" > "$OLLAMA_ENV_PLIST"
            launchctl unload "$OLLAMA_ENV_PLIST" 2>/dev/null || true
            launchctl load "$OLLAMA_ENV_PLIST"
            echo "Installed launchd agent: $OLLAMA_ENV_PLIST (sets OLLAMA_HOST=0.0.0.0:11434)"
        fi
        # Apply to the running session in case the agent above hasn't fired yet.
        launchctl setenv OLLAMA_HOST 0.0.0.0:11434
    fi

    # Check if Ollama is responding
    if ! ollama list > /dev/null 2>&1; then
        echo "Ollama is not running. Starting it..."
        if [ "$OS" = "Darwin" ]; then
            open -a Ollama 2>/dev/null || true
        else
            ollama serve > /dev/null 2>&1 &
        fi
        for i in $(seq 1 20); do
            if ollama list > /dev/null 2>&1; then
                break
            fi
            if [ "$i" -eq 20 ]; then
                echo "Error: Ollama failed to start. Please start it manually."
                exit 1
            fi
            sleep 1
        done
    fi

    # If Ollama is bound to 127.0.0.1 only, restart it so it picks up
    # OLLAMA_HOST=0.0.0.0:11434. lsof shows "*:11434" when bound to all
    # interfaces, "localhost:11434" or "127.0.0.1:11434" otherwise.
    if [ "$OS" = "Darwin" ]; then
        if lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | grep -qE '127\.0\.0\.1:11434|localhost:11434'; then
            echo "Ollama is bound to 127.0.0.1 — restarting so containers can reach it..."
            osascript -e 'quit app "Ollama"' 2>/dev/null || true
            pkill -f "ollama serve" 2>/dev/null || true
            sleep 2
            open -a Ollama 2>/dev/null || true
            for i in $(seq 1 15); do
                if lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | grep -q '\*:11434'; then
                    break
                fi
                sleep 1
            done
        fi
    fi
    echo "Ollama is running on your host (bound to 0.0.0.0:11434)."
    echo ""
fi

# ── Step 3: Generate docker-compose.override.yml ─────────────
# This file configures mode-specific settings and optional bind mounts.
# Docker Compose automatically merges it with docker-compose.yml.
OVERRIDE="docker-compose.override.yml"

ENABLE_IMAGE_GENERATION="${ENABLE_IMAGE_GENERATION:-true}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"

{
    echo "# Auto-generated by start.sh — do not edit manually"
    echo "services:"

    # ── open-webui overrides ──
    echo "  open-webui:"
    if [ "$OLLAMA_MODE" = "docker" ]; then
        echo "    depends_on:"
        echo "      ollama:"
        echo "        condition: service_healthy"
        echo "    environment:"
    else
        echo "    environment:"
        echo "      - OLLAMA_BASE_URL=http://host.docker.internal:11434"
    fi
    if [ "$ENABLE_IMAGE_GENERATION" = "true" ]; then
        echo "      - ENABLE_IMAGE_GENERATION=true"
        echo "      - IMAGE_GENERATION_ENGINE=comfyui"
        echo "      - COMFYUI_BASE_URL=http://host.docker.internal:${COMFYUI_PORT}"
        echo "      - IMAGES_EDIT_COMFYUI_BASE_URL=http://host.docker.internal:${COMFYUI_PORT}"
        # WebUI's validate_url blocks private-IP URLs by default. Since ComfyUI runs
        # on the host and its image URLs resolve to host.docker.internal (private IP),
        # we must enable local web fetch so get_image_data can retrieve generated images.
        echo "      - ENABLE_RAG_LOCAL_WEB_FETCH=true"
    fi

    # ── ollama-proxy overrides (docker mode only) ──
    if [ "$OLLAMA_MODE" = "docker" ]; then
        echo "  ollama-proxy:"
        echo "    depends_on:"
        echo "      ollama:"
        echo "        condition: service_healthy"
    fi
} > "$OVERRIDE"

echo "Generated $OVERRIDE"

# ── Step 4: Ensure TLS certs exist (mkcert) ──────────────────
CERT_DIR="certs"
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"

if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo ""
    echo "Generating TLS certificates with mkcert..."

    if ! command -v mkcert > /dev/null 2>&1; then
        echo ""
        echo "Error: mkcert is not installed. Install it with:"
        echo "  brew install mkcert"
        echo "  mkcert -install"
        echo ""
        echo "Then re-run ./start.sh"
        exit 1
    fi

    # Detect LAN IP (first non-loopback IPv4)
    LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"

    mkdir -p "$CERT_DIR"
    mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" \
        localhost 127.0.0.1 ::1 ai.local ${LAN_IP:+"$LAN_IP"}
    echo "Certificates written to $CERT_DIR/"
    echo ""
    echo "To trust this cert on other LAN devices, install the mkcert CA:"
    echo "  CA file: $(mkcert -CAROOT)/rootCA.pem"
    echo "  iOS/Android: AirDrop or email the CA file, then trust it in Settings"
    echo "  Windows:     Import into 'Trusted Root Certification Authorities'"
    echo "  Linux:       Add to /usr/local/share/ca-certificates/ and run update-ca-certificates"
fi

# ── Step 5: Ensure models are downloaded ──────────────────────
if [ "$OLLAMA_MODE" = "docker" ]; then
    # Stop Ollama if it's running from a previous start — two Ollama
    # processes on the same data volume can cause corruption.
    docker compose --profile docker stop ollama 2>/dev/null || true
fi

echo ""
echo "Checking AI models..."
if ./pull-models.sh; then
    echo ""
else
    echo ""
    echo "Note: Could not pull models. If you're offline and models were"
    echo "previously downloaded, they'll still work. Otherwise, get online"
    echo "and run ./start.sh again."
    echo ""
fi

# ── Step 6: Start ComfyUI natively (image generation) ────────
if [ "$ENABLE_IMAGE_GENERATION" = "true" ] && [ -x "./start-comfyui.sh" ]; then
    echo ""
    ./start-comfyui.sh || echo "Warning: ComfyUI failed to start — Open WebUI will run without image generation."
fi

# ── Step 6b: Pre-load the SDXL model ─────────────────────────
# Queue a 1-step 128×128 generation so the model is in RAM before the
# first real request. curl returns immediately; ComfyUI loads async.
if [ "$ENABLE_IMAGE_GENERATION" = "true" ] && \
   curl -sf "http://127.0.0.1:${COMFYUI_PORT:-8188}/system_stats" > /dev/null 2>&1; then
    _warmup_model="${COMFYUI_DEFAULT_MODEL_NAME:-sd_xl_base_1.0.safetensors}"
    if curl -sf "http://127.0.0.1:${COMFYUI_PORT:-8188}/prompt" \
            -H "Content-Type: application/json" \
            --data-binary @- > /dev/null 2>&1 << EOF
{"prompt":{"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"${_warmup_model}"}},"5":{"class_type":"EmptyLatentImage","inputs":{"width":128,"height":128,"batch_size":1}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"warmup","clip":["4",1]}},"7":{"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["4",1]}},"3":{"class_type":"KSampler","inputs":{"seed":1,"steps":1,"cfg":1,"sampler_name":"euler","scheduler":"normal","denoise":1,"model":["4",0],"positive":["6",0],"negative":["7",0],"latent_image":["5",0]}},"8":{"class_type":"VAEDecode","inputs":{"samples":["3",0],"vae":["4",2]}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"warmup","images":["8",0]}}}}
EOF
    then
        echo "ComfyUI warmup queued — SDXL model loading in background."
    else
        echo "Warning: ComfyUI warmup failed — first image generation may be slow."
    fi
fi

# ── Step 7: Start the stack ───────────────────────────────────
echo ""
echo "Starting local AI stack..."
if [ "$OLLAMA_MODE" = "docker" ]; then
    docker compose --profile docker up -d --build
else
    docker compose up -d --build
fi

echo ""
echo "Stack is up. Services:"
docker compose ps
echo ""

# ── Step 8: Patch ComfyUI workflow node_ids in WebUI DB ──────
# Open WebUI seeds its default ComfyUI workflow with empty node_ids, so
# prompt/model/size never get substituted into the workflow JSON. Result:
# ComfyUI rejects every prompt with "ckpt_name: 'model.safetensors' not in
# [...]". We patch the DB so the bundled workflow actually works.
#
# Sequence matters: WebUI caches PersistentConfig in memory and rewrites the
# row on shutdown. So we must (1) wait for first-run DB init, (2) stop WebUI
# to flush, (3) patch the now-quiescent DB, (4) start WebUI to read it.
if [ "$ENABLE_IMAGE_GENERATION" = "true" ]; then
    for i in $(seq 1 30); do
        if docker exec open-webui test -f /app/backend/data/webui.db 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # SDXL requires 1024x1024 — at WebUI's default 512x512, SDXL produces
    # solid black images. We force the size alongside the node_ids fix.
    NEEDS_PATCH=$(docker exec -i open-webui python - <<'PY' 2>/dev/null || echo "yes"
import sqlite3, json
row = sqlite3.connect('/app/backend/data/webui.db').cursor().execute(
    "SELECT data FROM config ORDER BY id DESC LIMIT 1").fetchone()
img = json.loads(row[0])['image_generation'] if row else {}
nodes_ok = any(n.get('node_ids') for n in img.get('comfyui', {}).get('nodes', []))
size_ok = img.get('size') == '1024x1024'
engine_ok = (img.get('engine') or 'comfyui') == 'comfyui'
model_ok = img.get('model') == 'sd_xl_base_1.0.safetensors'
openai_ok = not (img.get('openai') or {}).get('api_base_url')
print("no" if (nodes_ok and size_ok and engine_ok and model_ok and openai_ok) else "yes")
PY
)
    if [ "$NEEDS_PATCH" = "yes" ]; then
        echo "Patching ComfyUI workflow + image size in WebUI..."
        WEBUI_VOLUME="$(docker compose config --volumes | grep -E '^webui-data$' >/dev/null && \
            docker volume ls --format '{{.Name}}' | grep -E '_webui-data$' | head -n1)"
        # WebUI's PersistentConfig flushes in-memory state to the DB on graceful
        # shutdown, which would clobber our patch. `kill` (SIGKILL) skips the
        # flush so the DB stays quiescent for the rewrite.
        docker compose kill open-webui >/dev/null 2>&1
        docker compose rm -f open-webui >/dev/null 2>&1
        docker run --rm -v "${WEBUI_VOLUME}:/data" python:3.12-alpine python -c "
import sqlite3, json
db = sqlite3.connect('/data/webui.db')
c = db.cursor()
row = c.execute('SELECT id, data FROM config ORDER BY id DESC LIMIT 1').fetchone()
cid, data = row[0], json.loads(row[1])
img = data.setdefault('image_generation', {})
img['engine'] = 'comfyui'
img['model'] = 'sd_xl_base_1.0.safetensors'
img['size'] = '1024x1024'
img['openai'] = {}
img.setdefault('comfyui', {})['nodes'] = [
    {'type': 'prompt',   'key': 'text',      'node_ids': ['6']},
    {'type': 'model',    'key': 'ckpt_name', 'node_ids': ['4']},
    {'type': 'width',    'key': 'width',     'node_ids': ['5']},
    {'type': 'height',   'key': 'height',    'node_ids': ['5']},
    {'type': 'steps',    'key': 'steps',     'node_ids': ['3']},
    {'type': 'seed',     'key': 'seed',      'node_ids': ['3']},
]
c.execute('UPDATE config SET data=? WHERE id=?', (json.dumps(data), cid))
db.commit()
" || echo "Warning: ComfyUI workflow patch failed — set engine=comfyui, model=sd_xl_base_1.0.safetensors, size 1024x1024 manually in WebUI Settings → Images."
        docker compose up -d open-webui >/dev/null 2>&1
        # Wait for WebUI to start serving again so users don't hit a transient
        # 502 from Caddy if they reload during the patch window.
        for i in $(seq 1 30); do
            if curl -sf "http://localhost:${WEBUI_PORT:-3000}/health" >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
    fi
fi
echo ""
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ "${WEBUI_SSL_PORT:-443}" = "443" ]; then
    echo "Open WebUI: https://localhost  (this machine)"
    echo "            https://ai.local   (LAN — mDNS)${LAN_IP:+", https://$LAN_IP  (LAN — IP)"}"
else
    echo "Open WebUI: https://localhost:${WEBUI_SSL_PORT}  (this machine)"
    echo "            https://ai.local:${WEBUI_SSL_PORT}   (LAN — mDNS)"
fi
echo "            http://localhost:${WEBUI_PORT:-3000}  (HTTP fallback)"
if [ "$OLLAMA_MODE" = "native" ]; then
    echo "Ollama:     running natively on your host (localhost:11434)"
fi
if [ "$ENABLE_IMAGE_GENERATION" = "true" ]; then
    echo "ComfyUI:    running natively on your host (localhost:${COMFYUI_PORT})"
fi

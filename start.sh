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
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30s}"
IMAGE_GEN_BACKEND="${IMAGE_GEN_BACKEND:-comfyui}"
DRAW_THINGS_PORT="${DRAW_THINGS_PORT:-7860}"
DRAW_THINGS_PROXY_PORT="${DRAW_THINGS_PROXY_PORT:-7861}"
DRAW_THINGS_DEFAULT_MODEL="${DRAW_THINGS_DEFAULT_MODEL:-flux_1_dev_q8p.ckpt}"

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

# ── Install cleanup-media launchd agent (macOS only) ─────────
# Hourly janitor — surgical orphan GC in WebUI DB + uploads.
# See cleanup-media.sh for the work it does.
CLEANUP_LABEL="local.ai-stack.cleanup-media"
CLEANUP_PLIST="$HOME/Library/LaunchAgents/${CLEANUP_LABEL}.plist"

generate_cleanup_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  Hourly janitor — runs cleanup-media.sh every 3600 seconds.
  Surgically GCs orphaned WebUI file rows + their bytes on disk
  and any dangling chat_file rows. Tiny cost per run (<1 s).

  Managed by start.sh — do not edit manually.

  Logs: ${SCRIPT_DIR}/logs/cleanup-media.log (script) and
        ${SCRIPT_DIR}/logs/cleanup-media.launchd.log (launchd stdio)
  Disable: launchctl unload ${CLEANUP_PLIST}
  Run now: ${SCRIPT_DIR}/cleanup-media.sh [--dry-run]
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${CLEANUP_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_DIR}/cleanup-media.sh</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>

    <key>StartInterval</key>
    <integer>3600</integer>

    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/logs/cleanup-media.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/logs/cleanup-media.launchd.log</string>
</dict>
</plist>
EOF
}

if [ "$OS" = "Darwin" ]; then
    NEW_CLEANUP_PLIST="$(generate_cleanup_plist)"
    EXISTING_CLEANUP_PLIST="$(cat "$CLEANUP_PLIST" 2>/dev/null || true)"
    if [ "$NEW_CLEANUP_PLIST" != "$EXISTING_CLEANUP_PLIST" ]; then
        mkdir -p "$(dirname "$CLEANUP_PLIST")"
        printf '%s\n' "$NEW_CLEANUP_PLIST" > "$CLEANUP_PLIST"
        launchctl unload "$CLEANUP_PLIST" 2>/dev/null || true
        launchctl load "$CLEANUP_PLIST"
        echo "Installed launchd agent: $CLEANUP_PLIST (hourly)"
    fi
fi

echo "Platform: $PLATFORM"
echo "Ollama:   $OLLAMA_MODE mode"

case "$OLLAMA_MODE" in
    native)
        echo "          Ollama runs on your host with GPU acceleration."
        echo "          Open WebUI runs in Docker; Caddy and ComfyUI run natively."
        ;;
    docker)
        echo "          Ollama and Open WebUI run in Docker (CPU-only, isolated)."
        echo "          Caddy runs natively (needs host port 443 — Lima can't forward it)."
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
OLLAMA_SERVER_LABEL="local.ollama.server"
OLLAMA_SERVER_PLIST="$HOME/Library/LaunchAgents/${OLLAMA_SERVER_LABEL}.plist"

generate_ollama_server_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  Ollama server — LAN-accessible, M4-optimised.

  Runs the brew-installed ollama binary (not the .app or homebrew.mxcl.ollama
  service) so brew upgrade won't overwrite it and we don't end up with a
  second competing agent.

  Managed by start.sh — do not edit manually. Tunables live in .env.

  To load/unload:
    launchctl load   ${OLLAMA_SERVER_PLIST}
    launchctl unload ${OLLAMA_SERVER_PLIST}
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${OLLAMA_SERVER_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/ollama</string>
        <string>serve</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>OLLAMA_HOST</key>
        <string>0.0.0.0:11434</string>
        <key>OLLAMA_FLASH_ATTENTION</key>
        <string>1</string>
        <key>OLLAMA_KV_CACHE_TYPE</key>
        <string>q8_0</string>
        <key>OLLAMA_NUM_PARALLEL</key>
        <string>4</string>
        <key>OLLAMA_MAX_LOADED_MODELS</key>
        <string>1</string>
        <key>OLLAMA_KEEP_ALIVE</key>
        <string>${OLLAMA_KEEP_ALIVE}</string>
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
    <string>/opt/homebrew/var/log/ollama.log</string>
    <key>StandardErrorPath</key>
    <string>/opt/homebrew/var/log/ollama.log</string>

    <key>WorkingDirectory</key>
    <string>/opt/homebrew/var</string>
</dict>
</plist>
EOF
}

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

        # Install/update the launchd plist that runs `ollama serve` with the
        # tuned environment (incl. OLLAMA_KEEP_ALIVE from .env). Reloading
        # restarts the running ollama serve so the new env takes effect.
        NEW_SERVER_PLIST="$(generate_ollama_server_plist)"
        EXISTING_SERVER_PLIST="$(cat "$OLLAMA_SERVER_PLIST" 2>/dev/null || true)"
        if [ "$NEW_SERVER_PLIST" != "$EXISTING_SERVER_PLIST" ]; then
            mkdir -p "$(dirname "$OLLAMA_SERVER_PLIST")"
            printf '%s\n' "$NEW_SERVER_PLIST" > "$OLLAMA_SERVER_PLIST"
            launchctl unload "$OLLAMA_SERVER_PLIST" 2>/dev/null || true
            launchctl load "$OLLAMA_SERVER_PLIST"
            echo "Updated launchd agent: $OLLAMA_SERVER_PLIST (OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE})"
        fi
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
        if [ "$IMAGE_GEN_BACKEND" = "drawthings" ]; then
            # A1111-compatible proxy on host bridges Open WebUI to Draw Things.
            echo "      - IMAGE_GENERATION_ENGINE=automatic1111"
            echo "      - AUTOMATIC1111_BASE_URL=http://host.docker.internal:${DRAW_THINGS_PROXY_PORT}"
        else
            echo "      - IMAGE_GENERATION_ENGINE=comfyui"
            echo "      - COMFYUI_BASE_URL=http://host.docker.internal:${COMFYUI_PORT}"
            echo "      - IMAGES_EDIT_COMFYUI_BASE_URL=http://host.docker.internal:${COMFYUI_PORT}"
            # validate_url blocks private-IP URLs by default; ComfyUI image URLs
            # use host.docker.internal which resolves to a private IP.
            echo "      - ENABLE_RAG_LOCAL_WEB_FETCH=true"
        fi
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

# ── Step 4b: Install Caddy as a system LaunchDaemon ──────────
# Caddy terminates HTTPS on port 443. Colima/Lima cannot forward host
# ports below 1024 — its port forwarder uses unprivileged SSH -L, which
# can't bind privileged ports on macOS — so Caddy lives outside Docker
# and runs natively as root (the only way to bind :443 on macOS without
# socket activation). It reverse-proxies to http://127.0.0.1:${WEBUI_PORT}.
# The LaunchDaemon starts at boot before any user logs in, so HTTPS is
# answering before login. Idempotent: only sudo-prompts when the plist
# content actually changes.
CADDY_LABEL="local.ai-stack.caddy"
CADDY_PLIST="/Library/LaunchDaemons/${CADDY_LABEL}.plist"
WEBUI_PORT="${WEBUI_PORT:-3000}"

generate_caddy_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  Caddy — native HTTPS:443 termination for Open WebUI.

  System LaunchDaemon (runs as root so it can bind privileged port 443).
  Reads ${SCRIPT_DIR}/Caddyfile, terminates TLS with the mkcert certs in
  ${SCRIPT_DIR}/certs/, reverse-proxies to http://127.0.0.1:${WEBUI_PORT}.

  Managed by start.sh — do not edit manually.

  Logs:    tail -f ${SCRIPT_DIR}/logs/caddy.log
  Restart: sudo launchctl kickstart -k system/${CADDY_LABEL}
  Unload:  sudo launchctl bootout system ${CADDY_PLIST}
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${CADDY_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/caddy</string>
        <string>run</string>
        <string>--config</string>
        <string>${SCRIPT_DIR}/Caddyfile</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>

    <key>EnvironmentVariables</key>
    <dict>
        <!-- Without HOME, Caddy stores autosave/cache under ./caddy/
             relative to WorkingDirectory, polluting the project tree. -->
        <key>HOME</key>
        <string>/var/root</string>
        <key>AI_STACK_CERT</key>
        <string>${SCRIPT_DIR}/certs/cert.pem</string>
        <key>AI_STACK_KEY</key>
        <string>${SCRIPT_DIR}/certs/key.pem</string>
        <key>AI_STACK_UPSTREAM</key>
        <string>127.0.0.1:${WEBUI_PORT}</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/logs/caddy.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/logs/caddy.log</string>
</dict>
</plist>
EOF
}

if [ "$OS" = "Darwin" ]; then
    mkdir -p "$SCRIPT_DIR/logs"

    if ! command -v caddy > /dev/null 2>&1; then
        if command -v brew > /dev/null 2>&1; then
            echo "Installing Caddy via brew (one-time)..."
            brew install caddy
        else
            echo "Error: caddy is not installed and brew is unavailable."
            echo "       Install Caddy manually, then re-run ./start.sh"
            exit 1
        fi
    fi

    NEW_CADDY_PLIST="$(generate_caddy_plist)"
    EXISTING_CADDY_PLIST="$(cat "$CADDY_PLIST" 2>/dev/null || true)"
    if [ "$NEW_CADDY_PLIST" != "$EXISTING_CADDY_PLIST" ]; then
        echo "Installing Caddy LaunchDaemon (system-level — sudo prompt incoming)..."
        if printf '%s\n' "$NEW_CADDY_PLIST" | sudo tee "$CADDY_PLIST" >/dev/null && \
           sudo chown root:wheel "$CADDY_PLIST" && \
           sudo chmod 644 "$CADDY_PLIST"; then
            sudo launchctl bootout "system/${CADDY_LABEL}" 2>/dev/null || true
            # bootout is async — bootstrapping during teardown fails with
            # "Bootstrap failed: 5: Input/output error". Poll until the
            # service is fully gone before re-registering. ~7.5 s ceiling.
            for _i in $(seq 1 15); do
                if ! sudo launchctl print "system/${CADDY_LABEL}" >/dev/null 2>&1; then
                    break
                fi
                sleep 0.5
            done
            sudo launchctl bootstrap system "$CADDY_PLIST"
            echo "Installed system LaunchDaemon: $CADDY_PLIST"
        else
            echo "Warning: Caddy LaunchDaemon install skipped (sudo denied)."
            echo "         HTTPS on :443 will not work until installed. HTTP on :${WEBUI_PORT} is fine."
        fi
    fi
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

# ── Step 5b: Build custom-context coder model ─────────────────
# Extends qwen2.5-coder:14b to 16K context (32K caused CPU offload on 16 GB).
if [ "$OLLAMA_MODE" = "native" ] && command -v ollama > /dev/null 2>&1; then
    if ! ollama show qwen2.5-coder-16k > /dev/null 2>&1; then
        echo "Building qwen2.5-coder-16k (extended 16K context)..."
        ollama create qwen2.5-coder-16k -f "$SCRIPT_DIR/qwen-coder.Modelfile"
    fi
fi

# ── Step 6: Start ComfyUI natively (image generation) ────────
if [ "$ENABLE_IMAGE_GENERATION" = "true" ] && [ "$IMAGE_GEN_BACKEND" = "comfyui" ] && [ -x "./start-comfyui.sh" ]; then
    echo ""
    ./start-comfyui.sh || echo "Warning: ComfyUI failed to start — Open WebUI will run without image generation."
fi

# ── Step 6a: Allow ComfyUI venv Python through macOS firewall ─
# macOS Application Firewall silently drops payloads to unsigned binaries
# on non-loopback interfaces (even when bound to 0.0.0.0). ComfyUI runs
# from a venv Python that isn't in the allow-list by default — so LAN
# devices can't reach :${COMFYUI_PORT}. Whitelist it once; idempotent on
# subsequent runs (skipped silently when already present).
if [ "$OS" = "Darwin" ] && [ "$ENABLE_IMAGE_GENERATION" = "true" ] && [ "$IMAGE_GEN_BACKEND" = "comfyui" ]; then
    COMFYUI_DIR="${COMFYUI_DIR:-$HOME/ComfyUI}"
    COMFYUI_PYTHON_BIN="$COMFYUI_DIR/venv/bin/python"
    SOCKETFILTER="/usr/libexec/ApplicationFirewall/socketfilterfw"
    _COMFYUI_PORT="${COMFYUI_PORT:-8188}"
    _LAN_IP_FW="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"

    # Probe behavior, not config: macOS Application Firewall may match by
    # code signature rather than strict path, so an existing whitelist on
    # *any* brew Python often covers our venv too. If ComfyUI already
    # answers on the LAN IP, nothing to fix. Only when localhost works
    # AND the LAN IP times out does the firewall need the venv added.
    if [ -x "$COMFYUI_PYTHON_BIN" ] && [ -x "$SOCKETFILTER" ] && [ -n "$_LAN_IP_FW" ]; then
        if curl -sf -m 2 "http://127.0.0.1:${_COMFYUI_PORT}/system_stats" >/dev/null 2>&1 && \
           ! curl -sf -m 3 "http://${_LAN_IP_FW}:${_COMFYUI_PORT}/system_stats" >/dev/null 2>&1; then
            echo "Whitelisting ComfyUI venv Python in macOS Application Firewall (sudo)..."
            if sudo "$SOCKETFILTER" --add "$COMFYUI_PYTHON_BIN" >/dev/null && \
               sudo "$SOCKETFILTER" --unblockapp "$COMFYUI_PYTHON_BIN" >/dev/null; then
                echo "  ComfyUI is now reachable on the LAN at http://${_LAN_IP_FW}:${_COMFYUI_PORT}"
            else
                echo "Warning: firewall whitelist failed — ComfyUI may not be reachable from LAN."
            fi
        fi
    fi
    unset _COMFYUI_PORT _LAN_IP_FW
fi

# ── Step 6b: Pre-load the FLUX model ─────────────────────────
# Queue a 1-step 256×256 FLUX generation so the GGUF UNet + T5 + VAE are in
# MPS memory before the first real request. curl returns immediately; ComfyUI
# loads async. Mirrors the production workflow's node IDs so the same loader
# stack stays cached.
if [ "$ENABLE_IMAGE_GENERATION" = "true" ] && [ "$IMAGE_GEN_BACKEND" = "comfyui" ] && \
   curl -sf "http://127.0.0.1:${COMFYUI_PORT:-8188}/system_stats" > /dev/null 2>&1; then
    if curl -sf "http://127.0.0.1:${COMFYUI_PORT:-8188}/prompt" \
            -H "Content-Type: application/json" \
            --data-binary @- > /dev/null 2>&1 << 'EOF'
{"prompt":{"3":{"class_type":"KSampler","inputs":{"seed":1,"steps":1,"cfg":1.0,"sampler_name":"euler","scheduler":"simple","denoise":1.0,"model":["4",0],"positive":["12",0],"negative":["7",0],"latent_image":["5",0]}},"4":{"class_type":"UnetLoaderGGUF","inputs":{"unet_name":"flux1-dev-Q4_K_S.gguf"}},"5":{"class_type":"EmptySD3LatentImage","inputs":{"width":256,"height":256,"batch_size":1}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"warmup","clip":["11",0]}},"7":{"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["11",0]}},"8":{"class_type":"VAEDecode","inputs":{"samples":["3",0],"vae":["10",0]}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"warmup","images":["8",0]}},"10":{"class_type":"VAELoader","inputs":{"vae_name":"ae.safetensors"}},"11":{"class_type":"DualCLIPLoader","inputs":{"clip_name1":"t5xxl_fp8_e4m3fn.safetensors","clip_name2":"clip_l.safetensors","type":"flux"}},"12":{"class_type":"FluxGuidance","inputs":{"conditioning":["6",0],"guidance":3.5}}}}
EOF
    then
        echo "ComfyUI warmup queued — FLUX UNet + text encoders loading in background."
    else
        echo "Warning: ComfyUI warmup failed — first image generation may be slow."
    fi
fi

# ── Step 6c: Start Draw Things + A1111 proxy ─────────────────
if [ "$ENABLE_IMAGE_GENERATION" = "true" ] && [ "$IMAGE_GEN_BACKEND" = "drawthings" ]; then
    echo ""
    # Open Draw Things GUI app (its API server starts with the app).
    if open -a "Draw Things" 2>/dev/null; then
        echo "Draw Things launched."
    else
        echo "Warning: Draw Things not found — install it from the App Store."
        echo "         Then enable: Settings → Advanced → API Server (port ${DRAW_THINGS_PORT})."
    fi

    # Start the A1111-compatible proxy shim.
    PROXY_PID_FILE="$SCRIPT_DIR/logs/draw-things-proxy.pid"
    mkdir -p "$SCRIPT_DIR/logs"
    if [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat "$PROXY_PID_FILE")" 2>/dev/null; then
        echo "Draw Things proxy already running (PID $(cat "$PROXY_PID_FILE"))."
    else
        DRAW_THINGS_URL="http://127.0.0.1:${DRAW_THINGS_PORT}" \
        DRAW_THINGS_PROXY_PORT="${DRAW_THINGS_PROXY_PORT}" \
        DRAW_THINGS_DEFAULT_MODEL="${DRAW_THINGS_DEFAULT_MODEL}" \
        nohup python3 "$SCRIPT_DIR/draw-things-proxy.py" \
            >> "$SCRIPT_DIR/logs/draw-things-proxy.log" 2>&1 &
        echo $! > "$PROXY_PID_FILE"
        echo "Draw Things proxy started (PID $!) on port ${DRAW_THINGS_PROXY_PORT}."
    fi

    # Wait up to 30 s for Draw Things API to become available.
    echo "Waiting for Draw Things API on port ${DRAW_THINGS_PORT}..."
    _dt_ready=false
    for i in $(seq 1 15); do
        if nc -z localhost "$DRAW_THINGS_PORT" 2>/dev/null; then
            echo "Draw Things API ready."
            _dt_ready=true
            break
        fi
        sleep 2
    done
    if [ "$_dt_ready" = false ]; then
        echo "Warning: Draw Things API not responding on port ${DRAW_THINGS_PORT}."
        echo "         Make sure Draw Things is open and API Server is enabled."
    fi
fi

# ── Step 7: Start the stack ───────────────────────────────────
echo ""
echo "Starting local AI stack..."
# --remove-orphans cleans up the old `caddy` container left behind by the
# move from containerized Caddy to native Caddy (system LaunchDaemon).
if [ "$OLLAMA_MODE" = "docker" ]; then
    docker compose --profile docker up -d --build --remove-orphans
else
    docker compose up -d --build --remove-orphans
fi

echo ""
echo "Stack is up. Services:"
docker compose ps
echo ""

# ── Step 8: Patch image engine settings in WebUI DB ──────────
# Open WebUI caches image engine config in a SQLite DB. We patch it to
# match the active backend so users don't have to configure it manually.
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

    if [ "$IMAGE_GEN_BACKEND" = "drawthings" ]; then
        NEEDS_PATCH=$(docker exec -i open-webui python3 - <<'PY' 2>/dev/null || echo "yes"
import sqlite3, json
row = sqlite3.connect('/app/backend/data/webui.db').cursor().execute(
    "SELECT data FROM config ORDER BY id DESC LIMIT 1").fetchone()
img = json.loads(row[0])['image_generation'] if row else {}
engine_ok = img.get('engine') == 'automatic1111'
size_ok = img.get('size') == '1024x1024'
url_ok = bool((img.get('automatic1111') or {}).get('base_url'))
openai_ok = not (img.get('openai') or {}).get('api_base_url')
print("no" if (engine_ok and size_ok and url_ok and openai_ok) else "yes")
PY
        )
        if [ "$NEEDS_PATCH" = "yes" ]; then
            echo "Patching WebUI DB for Draw Things (automatic1111 engine)..."
            WEBUI_VOLUME="$(docker volume ls --format '{{.Name}}' | grep -E '_webui-data$' | head -n1)"
            docker compose kill open-webui >/dev/null 2>&1
            docker compose rm -f open-webui >/dev/null 2>&1
            docker run --rm -v "${WEBUI_VOLUME}:/data" python:3.12-alpine python -c "
import sqlite3, json
db = sqlite3.connect('/data/webui.db')
c = db.cursor()
row = c.execute('SELECT id, data FROM config ORDER BY id DESC LIMIT 1').fetchone()
cid, data = row[0], json.loads(row[1])
img = data.setdefault('image_generation', {})
img['engine'] = 'automatic1111'
img['size'] = '1024x1024'
img['openai'] = {}
img.setdefault('automatic1111', {})['base_url'] = 'http://host.docker.internal:${DRAW_THINGS_PROXY_PORT}'
c.execute('UPDATE config SET data=? WHERE id=?', (json.dumps(data), cid))
db.commit()
" || echo "Warning: DB patch failed — set engine=automatic1111, base_url=http://host.docker.internal:${DRAW_THINGS_PROXY_PORT} manually in WebUI Settings → Images."
            docker compose up -d open-webui >/dev/null 2>&1
            for i in $(seq 1 30); do
                if curl -sf "http://localhost:${WEBUI_PORT:-3000}/health" >/dev/null 2>&1; then
                    break
                fi
                sleep 1
            done
        fi
    else
        # Validate FLUX_LORA_NAME before wiring it in. Only .safetensors (load-only,
        # no pickle code execution) is allowed; legacy .ckpt/.pt/.bin/.pth pickles
        # can run arbitrary Python on load and must be refused. Also require the
        # file to actually exist under loras/ so we fail loudly on typos rather
        # than silently inserting a broken workflow node.
        if [ -n "${FLUX_LORA_NAME:-}" ]; then
            _lora_dir="${COMFYUI_DIR:-$HOME/ComfyUI}/models/loras"
            _lora_lower="$(printf '%s' "$FLUX_LORA_NAME" | tr '[:upper:]' '[:lower:]')"
            case "$_lora_lower" in
                *.safetensors) : ;;
                *)
                    echo "WARN: FLUX_LORA_NAME='${FLUX_LORA_NAME}' is not a .safetensors file — refusing to load." >&2
                    echo "      Legacy pickle formats (.ckpt/.pt/.bin/.pth) can execute arbitrary code on load." >&2
                    echo "      Ignoring FLUX_LORA_NAME for this run." >&2
                    FLUX_LORA_NAME=""
                    ;;
            esac
            if [ -n "${FLUX_LORA_NAME:-}" ] && [ ! -f "${_lora_dir}/${FLUX_LORA_NAME}" ]; then
                echo "WARN: FLUX_LORA_NAME='${FLUX_LORA_NAME}' not found at ${_lora_dir}/." >&2
                echo "      Ignoring FLUX_LORA_NAME for this run." >&2
                FLUX_LORA_NAME=""
            fi
            unset _lora_dir _lora_lower
        fi
        # comfyui: patch engine, model, size, and a FLUX.1-dev GGUF workflow.
        # FLUX is wired through three loaders (UnetLoaderGGUF + DualCLIPLoader + VAELoader)
        # plus a FluxGuidance node, so the workflow JSON is set explicitly here — WebUI's
        # built-in default workflow only covers a single CheckpointLoaderSimple.
        # 1024x1024 is FLUX's native training size; smaller dims produce poor results.
        NEEDS_PATCH=$(docker exec -i \
            -e "FLUX_LORA_NAME=${FLUX_LORA_NAME:-}" \
            -e "FLUX_LORA_STRENGTH=${FLUX_LORA_STRENGTH:-0.8}" \
            open-webui python3 - <<'PY' 2>/dev/null || echo "yes"
import sqlite3, json, os
row = sqlite3.connect('/app/backend/data/webui.db').cursor().execute(
    "SELECT data FROM config ORDER BY id DESC LIMIT 1").fetchone()
img = json.loads(row[0])['image_generation'] if row else {}
nodes_ok = any(n.get('key') == 'unet_name' for n in img.get('comfyui', {}).get('nodes', []))
size_ok = img.get('size') == '1024x1024'
engine_ok = (img.get('engine') or 'comfyui') == 'comfyui'
model_ok = img.get('model') == 'flux1-dev-Q4_K_S.gguf'
openai_ok = not (img.get('openai') or {}).get('api_base_url')
prompt_passthru_ok = (img.get('prompt') or {}).get('enable') is False
lora_name = os.environ.get('FLUX_LORA_NAME', '').strip()
try:
    wf = json.loads(img.get('comfyui', {}).get('workflow') or '{}')
    workflow_ok = wf.get('4', {}).get('class_type') == 'UnetLoaderGGUF'
    # LoRA drift check: workflow must match what .env asks for.
    if lora_name:
        n13 = wf.get('13', {})
        lora_ok = (n13.get('class_type') == 'LoraLoaderModelOnly'
                   and n13.get('inputs', {}).get('lora_name') == lora_name)
    else:
        lora_ok = '13' not in wf
    workflow_ok = workflow_ok and lora_ok
except Exception:
    workflow_ok = False
print("no" if (nodes_ok and size_ok and engine_ok and model_ok and openai_ok and workflow_ok and prompt_passthru_ok) else "yes")
PY
        )
        if [ "$NEEDS_PATCH" = "yes" ]; then
            echo "Patching ComfyUI FLUX workflow + image settings in WebUI..."
            WEBUI_VOLUME="$(docker volume ls --format '{{.Name}}' | grep -E '_webui-data$' | head -n1)"
            # WebUI's PersistentConfig flushes in-memory state to the DB on graceful
            # shutdown, which would clobber our patch. `kill` (SIGKILL) skips the flush.
            docker compose kill open-webui >/dev/null 2>&1
            docker compose rm -f open-webui >/dev/null 2>&1
            docker run --rm \
                -e "FLUX_LORA_NAME=${FLUX_LORA_NAME:-}" \
                -e "FLUX_LORA_STRENGTH=${FLUX_LORA_STRENGTH:-0.8}" \
                -v "${WEBUI_VOLUME}:/data" python:3.12-alpine python -c "
import sqlite3, json, os
FLUX_WORKFLOW = {
    '3':  {'class_type': 'KSampler', 'inputs': {
        'seed': 0, 'steps': 20, 'cfg': 1.0,
        'sampler_name': 'euler', 'scheduler': 'simple', 'denoise': 1.0,
        'model': ['4', 0], 'positive': ['12', 0], 'negative': ['7', 0],
        'latent_image': ['5', 0],
    }},
    '4':  {'class_type': 'UnetLoaderGGUF',     'inputs': {'unet_name': 'flux1-dev-Q4_K_S.gguf'}},
    '5':  {'class_type': 'EmptySD3LatentImage','inputs': {'width': 1024, 'height': 1024, 'batch_size': 1}},
    '6':  {'class_type': 'CLIPTextEncode',     'inputs': {'text': '', 'clip': ['11', 0]}},
    '7':  {'class_type': 'CLIPTextEncode',     'inputs': {'text': '', 'clip': ['11', 0]}},
    '8':  {'class_type': 'VAEDecode',          'inputs': {'samples': ['3', 0], 'vae': ['10', 0]}},
    '9':  {'class_type': 'SaveImage',          'inputs': {'filename_prefix': 'Flux', 'images': ['8', 0]}},
    '10': {'class_type': 'VAELoader',          'inputs': {'vae_name': 'ae.safetensors'}},
    '11': {'class_type': 'DualCLIPLoader',     'inputs': {
        'clip_name1': 't5xxl_fp8_e4m3fn.safetensors',
        'clip_name2': 'clip_l.safetensors',
        'type': 'flux',
    }},
    '12': {'class_type': 'FluxGuidance',       'inputs': {'conditioning': ['6', 0], 'guidance': 3.5}},
}
# Optional LoRA: insert LoraLoaderModelOnly between UnetLoaderGGUF and KSampler.
# Belt-and-suspenders: shell-layer already validates the file, but reject anything
# that isn't a .safetensors here too so a stale env var can't sneak a pickle in.
lora_name = os.environ.get('FLUX_LORA_NAME', '').strip()
if lora_name and not lora_name.lower().endswith('.safetensors'):
    print('Ignoring non-.safetensors FLUX_LORA_NAME:', lora_name)
    lora_name = ''
if lora_name:
    try:
        lora_strength = float(os.environ.get('FLUX_LORA_STRENGTH', '0.8') or 0.8)
    except ValueError:
        lora_strength = 0.8
    FLUX_WORKFLOW['13'] = {
        'class_type': 'LoraLoaderModelOnly',
        'inputs': {
            'model': ['4', 0],
            'lora_name': lora_name,
            'strength_model': lora_strength,
        },
    }
    FLUX_WORKFLOW['3']['inputs']['model'] = ['13', 0]
db = sqlite3.connect('/data/webui.db')
c = db.cursor()
row = c.execute('SELECT id, data FROM config ORDER BY id DESC LIMIT 1').fetchone()
cid, data = row[0], json.loads(row[1])
img = data.setdefault('image_generation', {})
img['engine'] = 'comfyui'
img['model'] = 'flux1-dev-Q4_K_S.gguf'
img['size'] = '1024x1024'
img['steps'] = 20
img['openai'] = {}
# Disable WebUI's LLM-side prompt enhancement so prompts go to ComfyUI verbatim
# without the chat model softening / rewriting them.
img['prompt'] = {'enable': False}
cfg = img.setdefault('comfyui', {})
cfg['workflow'] = json.dumps(FLUX_WORKFLOW)
cfg['nodes'] = [
    {'type': 'prompt',   'key': 'text',       'node_ids': ['6']},
    {'type': 'model',    'key': 'unet_name',  'node_ids': ['4']},
    {'type': 'width',    'key': 'width',      'node_ids': ['5']},
    {'type': 'height',   'key': 'height',     'node_ids': ['5']},
    {'type': 'steps',    'key': 'steps',      'node_ids': ['3']},
    {'type': 'seed',     'key': 'seed',       'node_ids': ['3']},
]
c.execute('UPDATE config SET data=? WHERE id=?', (json.dumps(data), cid))
db.commit()
" || echo "Warning: ComfyUI FLUX workflow patch failed — set engine=comfyui, model=flux1-dev-Q4_K_S.gguf, size 1024x1024 and the FLUX workflow manually in WebUI Settings → Images."
            docker compose up -d open-webui >/dev/null 2>&1
            for i in $(seq 1 30); do
                if curl -sf "http://localhost:${WEBUI_PORT:-3000}/health" >/dev/null 2>&1; then
                    break
                fi
                sleep 1
            done
        fi
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
    if [ "$IMAGE_GEN_BACKEND" = "drawthings" ]; then
        echo "Draw Things: running natively on your host (localhost:${DRAW_THINGS_PORT})"
        echo "DT Proxy:    A1111 shim on localhost:${DRAW_THINGS_PROXY_PORT} → Draw Things"
    else
        echo "ComfyUI:    http://localhost:${COMFYUI_PORT}  (this machine)${LAN_IP:+", http://$LAN_IP:${COMFYUI_PORT}  (LAN — IP)"}"
    fi
fi

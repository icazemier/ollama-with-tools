#!/usr/bin/env bash
#
# status.sh — Show what's running in the local AI stack
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

OLLAMA_MODE="${OLLAMA_MODE:-native}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
WEBUI_SSL_PORT="${WEBUI_SSL_PORT:-443}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
ENABLE_IMAGE_GENERATION="${ENABLE_IMAGE_GENERATION:-true}"

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

running() { printf "${GREEN}● running${RESET}"; }
stopped() { printf "${RED}○ stopped${RESET}"; }

# ── Services ─────────────────────────────────────────────────
echo ""
echo "── Services ─────────────────────────────────────────────"

# Ollama
printf "  %-14s" "Ollama"
if curl -sf --connect-timeout 2 "http://localhost:11434/api/tags" > /dev/null 2>&1; then
    printf "%s  %s\n" "$(running)" "(${OLLAMA_MODE}, localhost:11434)"
else
    printf "%s  %s\n" "$(stopped)" "(${OLLAMA_MODE})"
fi

# ComfyUI
if [ "$ENABLE_IMAGE_GENERATION" = "true" ]; then
    printf "  %-14s" "ComfyUI"
    if curl -sf --connect-timeout 2 "http://localhost:${COMFYUI_PORT}/system_stats" > /dev/null 2>&1; then
        printf "%s  %s\n" "$(running)" "(native, localhost:${COMFYUI_PORT})"
    else
        printf "%s  %s\n" "$(stopped)" "(native)"
    fi
fi

# Docker containers
CONTAINER_STATUS="$(docker compose ps --format json 2>/dev/null || true)"
for name in open-webui caddy; do
    printf "  %-14s" "$name"
    STATE="$(echo "$CONTAINER_STATUS" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    svc = json.loads(line)
    if svc.get('Name') == '$name':
        print(svc.get('State', 'unknown'))
        break
" 2>/dev/null || true)"
    if [ "$STATE" = "running" ]; then
        printf "%s  %s\n" "$(running)" "(Docker)"
    else
        printf "%s  %s\n" "$(stopped)" "(Docker${STATE:+, $STATE})"
    fi
done

# ── Models ───────────────────────────────────────────────────
echo ""
echo "── Models ───────────────────────────────────────────────"

if curl -sf --connect-timeout 2 "http://localhost:11434/api/tags" > /dev/null 2>&1; then
    LOADED="$(ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}' | awk '{printf "%s%s", sep, $0; sep=", "} END {print ""}' || true)"
    AVAILABLE="$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | awk '{printf "%s%s", sep, $0; sep=", "} END {print ""}' || true)"
    printf "  %-14s%s\n" "Loaded" "${LOADED:-${DIM}none${RESET}}"
    printf "  %-14s%s\n" "Available" "${AVAILABLE:-${DIM}none${RESET}}"
else
    printf "  ${DIM}(Ollama not running)${RESET}\n"
fi

# ── Access ────────────────────────────────────────────────────
echo ""
echo "── Access ───────────────────────────────────────────────"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ "$WEBUI_SSL_PORT" = "443" ]; then
    echo "  https://localhost"
    echo "  https://ai.local         (LAN — mDNS)"
    [ -n "$LAN_IP" ] && echo "  https://$LAN_IP   (LAN — IP)"
else
    echo "  https://localhost:${WEBUI_SSL_PORT}"
    echo "  https://ai.local:${WEBUI_SSL_PORT}   (LAN — mDNS)"
    [ -n "$LAN_IP" ] && echo "  https://$LAN_IP:${WEBUI_SSL_PORT}  (LAN — IP)"
fi
echo "  http://localhost:${WEBUI_PORT}     (HTTP fallback)"
echo ""

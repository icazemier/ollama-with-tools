#!/usr/bin/env bash
#
# test-privacy.sh — Verify that the AI stack is properly isolated
#
# What this does:
#   Runs a series of checks to confirm that:
#   - Docker mode: Ollama cannot access the internet, DNS is blocked,
#     Ollama is only on the internal network
#   - Both modes: telemetry is disabled, only expected ports are exposed,
#     the internal Docker network is marked as internal
#
# Usage:
#   ./start.sh                    # Stack must be running first
#   ./test-privacy.sh             # Run the tests
#
# Output:
#   PASS/FAIL for each test. Exit code 0 = all passed, 1 = something failed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Load settings
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi
OLLAMA_MODE="${OLLAMA_MODE:-native}"

PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

echo "========================================"
echo " Privacy & Isolation Tests"
echo " Mode: $OLLAMA_MODE"
echo "========================================"
echo ""

# ── Pre-check: Is the stack running? ────────────────────────
echo "── Pre-check: Stack running ──"
if [ "$OLLAMA_MODE" = "docker" ]; then
    if ! docker compose ps --status running | grep -q "ollama"; then
        echo "  ERROR: Stack is not running. Start it with ./start.sh first."
        exit 1
    fi
    pass "Docker stack is running (including Ollama container)"
else
    # Native mode: check that WebUI is running in Docker and Ollama on host
    if ! docker compose ps --status running | grep -q "open-webui"; then
        echo "  ERROR: Docker stack is not running. Start it with ./start.sh first."
        exit 1
    fi
    pass "Docker stack is running (WebUI + Sandbox)"
    if curl -sf --connect-timeout 3 http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        pass "Native Ollama is responding on localhost:11434"
    else
        fail "Native Ollama is NOT responding on localhost:11434"
    fi
fi
echo ""

# ── Docker mode only: Ollama container isolation ────────────
if [ "$OLLAMA_MODE" = "docker" ]; then
    # Test: Ollama cannot reach the internet
    echo "── Test: Ollama network isolation ──"
    # Use bash's built-in /dev/tcp to test connectivity (no curl/ping in Ollama image)
    if docker exec ollama bash -c '(echo > /dev/tcp/google.com/80) 2>/dev/null'; then
        fail "Ollama CAN reach google.com:80 (expected: blocked)"
    else
        pass "Ollama cannot reach the internet"
    fi

    if docker exec ollama bash -c '(echo > /dev/tcp/8.8.8.8/53) 2>/dev/null'; then
        fail "Ollama CAN reach 8.8.8.8:53 (expected: blocked)"
    else
        pass "Ollama cannot reach external IPs"
    fi
    echo ""

    # Test: Ollama cannot resolve DNS
    echo "── Test: Ollama DNS isolation ──"
    if docker exec ollama bash -c '(echo > /dev/tcp/example.com/80) 2>/dev/null'; then
        fail "Ollama CAN resolve external DNS (expected: blocked)"
    else
        pass "Ollama cannot resolve external DNS"
    fi
    echo ""
else
    echo "── Info: Ollama container isolation ──"
    echo "  SKIP: Ollama runs natively on your host (not in a container)."
    echo "  SKIP: Container network isolation does not apply in native mode."
    echo "  INFO: All AI processing is local. Ollama does not phone home."
    echo ""
fi

# ── Test: Open WebUI internet access note ────────────────────
echo "── Test: Open WebUI internet access ──"
echo "  INFO: Open WebUI is on a non-internal network (for host access). This is by design."
if [ "$OLLAMA_MODE" = "docker" ]; then
    echo "  INFO: The critical isolation is that Ollama has NO internet access."
fi
echo ""

# ── Test: Telemetry is disabled ──────────────────────────────
echo "── Test: Telemetry disabled ──"
check_env() {
    local container="$1" var="$2" expected="$3"
    local actual
    actual=$(docker exec "$container" printenv "$var" 2>/dev/null || echo "__UNSET__")
    if [ "$actual" = "$expected" ]; then
        pass "$container: $var=$expected"
    else
        fail "$container: $var expected '$expected' got '$actual'"
    fi
}

check_env "open-webui" "ENABLE_TELEMETRY" "false"
check_env "open-webui" "SCARF_NO_ANALYTICS" "true"
check_env "open-webui" "DO_NOT_TRACK" "true"
check_env "open-webui" "ANONYMIZED_TELEMETRY" "false"
check_env "open-webui" "ENABLE_UPDATE_CHECK" "false"
echo ""

# ── Test: Only expected ports are published ──────────────────
echo "── Test: Published ports ──"
PUBLISHED=$(docker compose ps --format json 2>/dev/null | python3 -c "
import sys, json
ports = set()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    svc = json.loads(line)
    for p in svc.get('Publishers', []):
        if p.get('PublishedPort', 0) > 0:
            ports.add(str(p['PublishedPort']))
print(' '.join(sorted(ports)))
" 2>/dev/null || echo "PARSE_ERROR")

EXPECTED_PORT="${WEBUI_PORT:-3000}"

if [ "$OLLAMA_MODE" = "docker" ]; then
    # Docker mode: WebUI port + proxy port (11434)
    EXPECTED_PORTS="$EXPECTED_PORT 11434"
else
    # Native mode: only WebUI port (Ollama is on host, not Docker)
    EXPECTED_PORTS="$EXPECTED_PORT"
fi

EXPECTED_SORTED=$(echo "$EXPECTED_PORTS" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)
PUBLISHED_SORTED=$(echo "$PUBLISHED" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)

if [ "$PUBLISHED_SORTED" = "$EXPECTED_SORTED" ]; then
    pass "Only expected ports published: $PUBLISHED_SORTED"
else
    fail "Expected ports '$EXPECTED_SORTED', got '$PUBLISHED_SORTED'"
fi
echo ""

# ── Test: The internal network is actually internal ──────────
echo "── Test: ailocal network is internal ──"
NETWORK_NAME=$(docker network ls --format '{{.Name}}' | grep "ailocal" | head -1)
if [ -z "$NETWORK_NAME" ]; then
    fail "Could not find ailocal network"
else
    IS_INTERNAL=$(docker network inspect "$NETWORK_NAME" --format '{{.Internal}}')
    if [ "$IS_INTERNAL" = "true" ]; then
        pass "Network '$NETWORK_NAME' is internal: true"
    else
        fail "Network '$NETWORK_NAME' is internal: $IS_INTERNAL (expected: true)"
    fi
fi
echo ""

# ── Test: Ollama API reachable on localhost ──────────────────
echo "── Test: Ollama API reachable on localhost ──"
if curl -sf --connect-timeout 3 http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
    if [ "$OLLAMA_MODE" = "docker" ]; then
        pass "Ollama API is reachable on localhost:11434 (via proxy)"
    else
        pass "Ollama API is reachable on localhost:11434 (native)"
    fi
else
    fail "Ollama API is NOT reachable on localhost:11434"
fi
echo ""

# ── Docker mode only: Ollama network membership ─────────────
if [ "$OLLAMA_MODE" = "docker" ]; then
    echo "── Test: Ollama is only on the internal network ──"
    OLLAMA_NETWORKS=$(docker inspect ollama --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | xargs)
    if echo "$OLLAMA_NETWORKS" | grep -q "ailocal"; then
        NET_COUNT=$(echo "$OLLAMA_NETWORKS" | wc -w | xargs)
        if [ "$NET_COUNT" -eq 1 ]; then
            pass "Ollama is only on the ailocal network"
        else
            fail "Ollama is on multiple networks: $OLLAMA_NETWORKS (expected: only ailocal)"
        fi
    else
        fail "Ollama is not on ailocal network. Networks: $OLLAMA_NETWORKS"
    fi
    echo ""
fi

# ── Summary ──────────────────────────────────────────────────
echo "========================================"
echo " Results: $PASS passed, $FAIL failed"
if [ "$OLLAMA_MODE" = "native" ]; then
    echo " (Some container tests skipped — native mode)"
fi
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

#!/usr/bin/env bash
# add-lora.sh — download a FLUX LoRA from Hugging Face, wire it into .env,
# and (optionally) re-run ./start.sh so the new workflow takes effect.
#
# Refuses anything that isn't .safetensors. Skips download if the target
# filename already exists in the loras dir.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LORAS_DIR="${COMFYUI_DIR:-$HOME/ComfyUI}/models/loras"

usage() {
    cat <<EOF
Usage: ./add-lora.sh <huggingface-url> [options]

Downloads a FLUX LoRA from Hugging Face into:
  ${LORAS_DIR}
…points FLUX_LORA_NAME in .env at it, and re-runs ./start.sh.

Accepts either URL form (the 'blob' form is normalized to 'resolve'):
  https://huggingface.co/<user>/<repo>/resolve/main/<file>.safetensors
  https://huggingface.co/<user>/<repo>/blob/main/<file>.safetensors

Options:
  --strength <float>   LoRA strength (e.g. 0.8). Default: leave current.
  --name <filename>    Save under this filename instead of the URL basename.
                       Useful when the upstream file is named 'lora.safetensors'.
  --token <hf_xxx>     HF access token for gated repos (or export HF_TOKEN).
  --no-restart         Edit files only; don't run ./start.sh.
  -h, --help           Show this help.

If the target file already exists, the download is skipped (the script
still updates .env and re-runs ./start.sh, so re-running with the same URL
is a cheap way to switch back to an already-downloaded LoRA). To force a
re-download, delete the file first:
    rm ~/ComfyUI/models/loras/<filename>.safetensors

Examples:
  ./add-lora.sh https://huggingface.co/alvdansen/m3lt/resolve/main/m3lt.safetensors
  ./add-lora.sh https://huggingface.co/aleksa-codes/flux-ghibsky-illustration/resolve/main/lora_v2.safetensors --name ghibsky.safetensors --strength 0.8
EOF
}

URL=""
STRENGTH=""
RENAME=""
TOKEN="${HF_TOKEN:-}"
NO_RESTART=0

while [ $# -gt 0 ]; do
    case "$1" in
        --strength) STRENGTH="$2"; shift 2;;
        --name) RENAME="$2"; shift 2;;
        --token) TOKEN="$2"; shift 2;;
        --no-restart) NO_RESTART=1; shift;;
        -h|--help) usage; exit 0;;
        -*) echo "Unknown option: $1" >&2; usage; exit 1;;
        *)
            if [ -n "$URL" ]; then
                echo "More than one URL given." >&2; usage; exit 1
            fi
            URL="$1"; shift
            ;;
    esac
done

if [ -z "$URL" ]; then
    usage; exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "No .env at $ENV_FILE. Copy .env.example to .env first." >&2
    exit 1
fi

# Normalize blob -> resolve so the page URL works too.
URL="${URL//\/blob\//\/resolve\/}"

case "$URL" in
    https://huggingface.co/*) ;;
    *) echo "URL must start with https://huggingface.co/" >&2; exit 1;;
esac

# Filename = last URL segment with query string stripped.
URL_BASENAME="${URL##*/}"
URL_BASENAME="${URL_BASENAME%%\?*}"
TARGET="${RENAME:-$URL_BASENAME}"

# Guardrail: only .safetensors. Pickle formats can execute code on load.
case "$(printf '%s' "$TARGET" | tr '[:upper:]' '[:lower:]')" in
    *.safetensors) ;;
    *)
        echo "Refusing: '$TARGET' is not a .safetensors file." >&2
        echo "Legacy pickle formats (.ckpt/.pt/.bin/.pth) can execute arbitrary code on load." >&2
        exit 1
        ;;
esac

mkdir -p "$LORAS_DIR"
DEST="$LORAS_DIR/$TARGET"

if [ -f "$DEST" ]; then
    echo "Already present: $DEST"
    echo "(Delete the file first if you want to re-download.)"
else
    echo "Downloading: $URL"
    echo "        ->  $DEST"
    if [ -n "$TOKEN" ]; then
        curl -L --fail --progress-bar \
            -H "Authorization: Bearer $TOKEN" \
            -o "$DEST" "$URL" || {
                rm -f "$DEST"
                echo "Download failed." >&2
                exit 1
            }
    else
        curl -L --fail --progress-bar -o "$DEST" "$URL" || {
            rm -f "$DEST"
            echo "Download failed." >&2
            echo "If the repo is gated (401), accept the terms on the model page" >&2
            echo "while signed in, then re-run with --token <hf_xxx> (or export HF_TOKEN)." >&2
            exit 1
        }
    fi
fi

# Sanity-check it parsed as a safetensors header. First 8 bytes are a
# little-endian uint64 header length; reject if obviously bogus or HTML.
if head -c 5 "$DEST" | grep -qi '<html\|<!doc'; then
    echo "Downloaded file looks like HTML, not a model. Removing." >&2
    rm -f "$DEST"
    exit 1
fi

python3 - "$ENV_FILE" "$TARGET" "$STRENGTH" <<'PY'
import sys, re, pathlib
env_path, name, strength = sys.argv[1], sys.argv[2], sys.argv[3]
path = pathlib.Path(env_path)
text = path.read_text()

def upsert(text, key, value):
    pattern = re.compile(rf'^{re.escape(key)}=.*$', re.M)
    line = f'{key}={value}'
    if pattern.search(text):
        return pattern.sub(line, text)
    if text and not text.endswith('\n'):
        text += '\n'
    return text + line + '\n'

text = upsert(text, 'FLUX_LORA_NAME', name)
if strength:
    text = upsert(text, 'FLUX_LORA_STRENGTH', strength)
path.write_text(text)
msg = f'.env updated: FLUX_LORA_NAME={name}'
if strength:
    msg += f', FLUX_LORA_STRENGTH={strength}'
print(msg)
PY

if [ "$NO_RESTART" = "1" ]; then
    echo "Skipping ./start.sh (--no-restart). Run it yourself to apply."
    exit 0
fi

echo "Applying via ./start.sh ..."
cd "$SCRIPT_DIR"
./start.sh

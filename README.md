# Local AI Stack

Run AI models on your own machine. Your code and conversations never leave your computer.

## Quick start

You'll need [Docker Desktop](https://www.docker.com/products/docker-desktop/),
[Ollama](https://ollama.com/download), and [mkcert](https://github.com/FiloSottile/mkcert)
installed. Then:

```bash
./start.sh
```

Open **https://localhost** — you now have a local ChatGPT (with image
generation, mic, camera). HTTP fallback at http://localhost:3000.

> First run takes a while (downloads Ollama LLM ~9 GB, SDXL ~6.5 GB, ComfyUI
> Python deps ~2 GB). After that, `./start.sh` takes seconds and works fully
> offline.

## Use it in VS Code

Install the **[Continue](https://marketplace.visualstudio.com/items?itemName=Continue.continue)** extension, then:

1. In VS Code, open Continue's config (gear icon in the Continue sidebar → click on the `config.yaml` link at the top)
2. Replace the contents with:

```yaml
name: Local AI
version: 0.0.1
schema: v1
models:
  - name: Qwen Coder 14B
    provider: ollama
    model: qwen2.5-coder:14b
    roles: [chat, edit, apply]
  - name: Qwen Coder 14B (Autocomplete)
    provider: ollama
    model: qwen2.5-coder:14b
    roles: [autocomplete]
```

That's it — no API keys needed. Continue connects to Ollama on `localhost:11434` by default.

Now you have:
- **`Cmd+L`** — AI chat sidebar (ask questions, explain code, get help)
- **Tab completion** — AI suggests code as you type

> **Autocomplete too slow?** The 14B model is great for chat but can be sluggish for
> real-time completions (which need sub-200ms responses). Add a small fast model
> for autocomplete:
>
> 1. Add `qwen2.5-coder:1.5b` to `models.conf`
> 2. Run `./start.sh` (downloads the new model automatically)
> 3. Change the autocomplete model in `config.yaml` to `qwen2.5-coder:1.5b`

## What you get

- **Chat UI** at localhost:3000 (HTTP) and https://localhost (HTTPS, mic/camera enabled)
- **Image generation** via ComfyUI (Apple Silicon: Metal-accelerated)
- **VS Code integration** — AI chat + code completions via Continue
- **100% local** — your prompts, code, and images never leave the machine
- **Chat history** — saved locally, survives restarts
- **Swappable models** — try different AI models by editing `models.conf`

## Stopping and restarting

```bash
./stop.sh               # Stop (models and chat history are kept)
./start.sh              # Start again
```

## How it works

The stack runs in two layers:

**In Docker (isolated, no internet for AI):**

| Container | What it does | Internet? |
|---|---|---|
| **Open WebUI** | Chat UI for your browser + API for VS Code | Local only |
| **Caddy** | HTTPS reverse proxy (TLS termination on port 443) | Local only |
| **Ollama** *(docker mode)* | Runs LLMs in a container | Blocked — cannot phone home |

**Native on the host (for GPU access):**

| Process | What it does | Why native |
|---|---|---|
| **Ollama** *(native mode, default)* | Runs LLMs with Metal GPU | Docker on Mac has no Metal access |
| **ComfyUI** | Image generation with Metal GPU | Same — needs MPS for speed |

Open WebUI (in Docker) reaches both native processes via `host.docker.internal`.
The Docker network is internal-only — no LLM container can reach the internet.

Verify it yourself: `./test-privacy.sh`

## Configuration

Edit `.env` and re-run `./start.sh` to apply changes.

### Resource limits (Docker mode only)

In native mode (default), Ollama uses host resources directly and these are
ignored. They only apply to the WebUI container and to Ollama when running in
Docker mode.

```env
OLLAMA_CPUS=10       # Docker-mode Ollama only
OLLAMA_MEMORY=14g    # Must fit the model + overhead
WEBUI_CPUS=1
WEBUI_MEMORY=1g
```

### Mode switch

```env
OLLAMA_MODE=native   # Ollama on host with Metal GPU (fast, default)
# OLLAMA_MODE=docker # Ollama in container, CPU-only, fully isolated
```

### Image generation toggle

```env
ENABLE_IMAGE_GENERATION=true   # Auto-start ComfyUI with the stack
COMFYUI_PORT=8188
```

## Choosing AI models

Edit `models.conf` to pick which models to use, then run `./start.sh` — new models are downloaded automatically.

| Model | Download | Good for |
|---|---|---|
| `qwen2.5-coder:14b` | ~9 GB | Coding — great balance of speed and quality |
| `qwen2.5-coder:1.5b` | ~1 GB | Fast autocomplete — pair with a bigger chat model |
| `qwen2.5-coder:32b` | ~20 GB | Coding — smarter but slower, needs 24+ GB RAM |
| `llama3.1:8b` | ~5 GB | General purpose — fast, good for quick questions |
| `deepseek-coder-v2:16b` | ~9 GB | Coding — strong at code generation |
| `codellama:13b` | ~7 GB | Coding — Meta's code-focused model |

Browse all models at [ollama.com/library](https://ollama.com/library).

To remove old models you no longer use (and free disk space):

```bash
./pull-models.sh --cleanup
```

## Image generation

Image generation uses **ComfyUI**, running natively on the host (not in Docker).
Open WebUI in Docker reaches it via `host.docker.internal:8188`.

### Why native, not Docker?

Docker on macOS runs in a Linux VM and has **no access to Metal/MPS** — image
generation in a container would be CPU-only and take minutes per image. Native
ComfyUI uses Apple Silicon's GPU and finishes in 15–30 seconds per image.

This is the same pattern as Ollama: heavy GPU workloads run on the host, the
WebUI runs in Docker and reaches both via `host.docker.internal`.

### What's included by default

- **Backend:** ComfyUI (latest), auto-installed at `~/ComfyUI` on first run
- **Model:** Stable Diffusion XL Base 1.0 (~6.5 GB), auto-downloaded on first run
- **Python:** ComfyUI uses its own Python 3.12 venv at `~/ComfyUI/venv`
  (PyTorch + dependencies are installed automatically)
- **Auto-start:** wired into `./start.sh` and `./stop.sh`
- **Disable:** set `ENABLE_IMAGE_GENERATION=false` in `.env`

On a fresh Mac, `./start.sh` does everything — clones ComfyUI, builds the
venv, installs PyTorch with MPS, downloads SDXL, then starts the server.
First run takes ~10–15 minutes (mostly the SDXL download). Subsequent runs
are instant.

### How to use it in Open WebUI

**First-time setup** (required even though env vars set the defaults — saving
once in the UI persists them to the DB):

1. Open WebUI → **profile menu → Admin Panel → Settings → Images**
2. **Image Generation Engine:** ComfyUI (already populated)
3. **ComfyUI Base URL:** `http://host.docker.internal:8188` (already populated)
4. **ComfyUI API Key:** leave empty (no auth on local ComfyUI)
5. **Default Model:** pick `sd_xl_base_1.0.safetensors` from the dropdown
6. Recommended defaults: 1024×1024, 30 steps, CFG 7, sampler `euler`
7. Hit **Save** — should show "Connection successful"

**Generating images in a chat** — there is **no** `/image` slash command in
current Open WebUI builds. Use one of:

- **Per-message toggle:** click the **`+` (plus)** icon next to the message
  input → flip the **Image** / "Generate an image" toggle on → type your
  prompt → send. The message goes straight to ComfyUI instead of Ollama.
- **From an LLM reply:** chat normally with Ollama, then on the assistant's
  message hover toolbar click the **picture icon**. WebUI uses that whole
  message as the image prompt — great for "write a detailed description of a
  cyberpunk cat" → click → image.

If the `+` menu has no **Image** option:
- Make sure you saved the Admin → Images settings (above)
- The currently-selected model may have `image_generation` capability disabled
  — try another model, or check **Admin → Models → [model] → Capabilities**

You don't need to open ComfyUI's own UI. It just runs as an API. If you ever
want full workflow control (LoRAs, ControlNet, custom workflows), it lives at
http://localhost:8188.

### Prompt tips for SDXL

SDXL responds best to **comma-separated descriptive phrases**, not full
sentences:

```
cyberpunk cat, neon-lit alley, rain, glowing eyes, cinematic lighting,
shallow depth of field, photorealistic, 8k, highly detailed
```

A useful **negative prompt** (set in image settings):

```
blurry, lowres, bad anatomy, watermark, text, jpeg artifacts
```

First image after starting the stack takes ~30–60s (model loads into MPS).
Subsequent images: ~15–25s.

### Editing existing images

WebUI's image edit feature is also wired to ComfyUI via the
`IMAGES_EDIT_COMFYUI_BASE_URL` env var (same backend, same port). To edit:
upload or generate an image, click the **edit icon**, paint a mask over the
area you want to change, and describe what should appear there.

Editing uses the **same SDXL Base model** via ComfyUI's mask-aware inpainting
workflow (`VAEEncodeForInpaint`). No separate inpainting checkpoint is
installed — the practical SDXL inpainting models on Hugging Face are either
gated, NSFW-only, or shipped only in multi-file diffusers format that doesn't
drop into WebUI's default edit workflow. Quality with the base model is decent
for masked edits, not great.

If you want substantially better editing later, the right upgrade is
**FLUX.1 Kontext** (instruction-style editing — "make the cat blue and add a
hat" — no mask needed). It needs ~12 GB peak RAM, so plan to swap out Ollama
or use a smaller LLM during editing sessions.

### Memory notes

On a 16 GB Mac:
- macOS uses ~4 GB
- Ollama with a 14B model uses ~9 GB
- SDXL needs ~6 GB peak

That's tight — macOS unified memory will page when both are loaded. It works,
just expect first-image latency. To stay snappy, either use a smaller Ollama
model (e.g. `qwen2.5-coder:7b`) when generating images, or unload Ollama with
`ollama stop <model>` before a heavy image session.

### Adding more models

Drop any `.safetensors` checkpoint into `~/ComfyUI/models/checkpoints/`, then
pick it from the model dropdown in WebUI's image settings. Newer options worth
trying (with their RAM trade-offs):

| Model | Size | Notes |
|---|---|---|
| **SDXL Base 1.0** | ~6.5 GB | Default. Open license. Reliable. |
| **SD 3.5 Medium** | ~5 GB | Newer, smaller. Requires HF token (license accept). |
| **FLUX.1 schnell** | ~12 GB | Best quality, Apache 2.0, 4-step inference. Tight on 16 GB alongside Ollama. |
| **FLUX.1 dev** | ~24 GB | Top quality. Non-commercial license. Requires 32+ GB RAM. |

## LAN access

The stack is reachable from other devices on your network at **https://ai.local**
(via mDNS/Bonjour) or **https://`<your-LAN-IP>`**. The TLS cert covers all of
those, but it's signed by your local mkcert CA — other devices won't trust it
out of the box.

To get a green padlock on phones/laptops, install the mkcert CA on each device:

```bash
# Find the CA file:
mkcert -CAROOT
# Then:
#   iOS/Android — AirDrop or email rootCA.pem to the device, install via Settings, then trust it.
#   Windows    — import into "Trusted Root Certification Authorities".
#   Linux      — copy to /usr/local/share/ca-certificates/ and run update-ca-certificates.
```

## Prerequisites

- **macOS** (Apple Silicon recommended for Metal-accelerated Ollama + ComfyUI)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) running
- [Ollama](https://ollama.com/download) installed (native mode runs it on the host)
- [mkcert](https://github.com/FiloSottile/mkcert) for local TLS (`brew install mkcert && mkcert -install`)
- At least **16 GB of RAM** (LLM + image gen are tight at this size, see Memory notes above)
- At least **30 GB of free disk space** (LLM ~9 GB, SDXL ~6.5 GB, ComfyUI deps ~2 GB, headroom)

## File overview

```
├── start.sh              Start everything (Docker stack + native ComfyUI)
├── stop.sh               Stop everything (keeps your data)
├── start-comfyui.sh      Start ComfyUI natively (called by start.sh)
├── stop-comfyui.sh       Stop ComfyUI natively (called by stop.sh)
├── pull-models.sh        Manage Ollama models (--cleanup to remove unused)
├── test-privacy.sh       Verify the AI is properly isolated
├── .env.example          Settings template (copy to .env)
├── .env                  Your settings (not in git)
├── models.conf           Which Ollama models to download
├── Caddyfile             TLS reverse proxy config (Caddy serves WebUI on 443)
├── certs/                mkcert-generated TLS certs (not in git)
└── docker-compose.yml    Defines containers and networks
```

## Troubleshooting

**"No models available" in the chat UI**
Run `./start.sh` — it downloads models automatically. Make sure you have internet on the first run.

**Models are slow**
In native mode (default), Ollama uses Metal — it should be fast. If it isn't,
check the active model with `ollama ps` and try a smaller one. In docker mode,
Ollama is CPU-only and will be slow on macOS.

**Out of memory**
Use a smaller LLM in `models.conf`, or stop Ollama (`ollama stop <model>`)
before generating images. macOS unified memory pages between Ollama and
ComfyUI when both are loaded on a 16 GB machine.

**Port 443 already in use**
Another service is bound to HTTPS. Either stop it, or change `WEBUI_SSL_PORT`
in `.env` (e.g. `3443`) and use `https://localhost:3443`.

**Image generation button does nothing / "Connection failed" in WebUI Images settings**
Check ComfyUI is up: `curl http://localhost:8188/system_stats`. If it's not,
run `./start-comfyui.sh` directly and look at `~/ComfyUI/comfyui.log`.

**Browser shows cert warning**
On *this* machine: run `mkcert -install` and restart your browser. On *other*
LAN devices: install the mkcert CA file on each device (see LAN access above).

**VS Code Continue can't connect**
Make sure Ollama is running (`ollama ps`). In native mode it must be running
on the host before `./start.sh`.

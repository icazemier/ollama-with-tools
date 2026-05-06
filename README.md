# Local AI Stack

Run AI models on your own machine. Your code and conversations never leave your computer.

## Quick start

You'll need a Docker engine ([Colima](https://github.com/abiosoft/colima)
recommended — see [Container engine](#container-engine) below),
[Ollama](https://ollama.com/download), and [mkcert](https://github.com/FiloSottile/mkcert)
installed. Then:

```bash
./start.sh
```

Open **https://localhost** — you now have a local ChatGPT (with image
generation, mic, camera). HTTP fallback at http://localhost:3000.

> First run takes a while (downloads the Ollama chat LLM ~9 GB and the chosen
> image model). After that, `./start.sh` takes seconds and works fully offline.

### Pick your image backend (optional)

Two backends ship out of the box. `./start.sh` auto-detects: existing
`~/ComfyUI` install → `comfyui` (no surprise migration), otherwise
`ollama` (the simpler default for fresh installs). Override anytime in `.env`:

```env
# IMAGE_BACKEND=ollama     # Ollama image models via a tiny OpenAI-compatible
                           # bridge container. Dead simple, macOS only.
# IMAGE_BACKEND=comfyui    # ComfyUI in a venv on the host. More flexible,
                           # works on Linux too, more moving parts.

# IMAGE_MODEL semantics depend on IMAGE_BACKEND:
#   ollama  → Ollama tag, e.g. x/flux2-klein:4b (5.7 GB, default, Apache 2.0)
#   comfyui → preset, e.g. sdxl (default), flux-schnell, flux-dev
```

For the Ollama backend `./start.sh` pulls the model via `ollama pull`, brings
up the bridge container, and patches Open WebUI to talk to it.
For the ComfyUI backend it bootstraps `~/ComfyUI`, downloads the matching
checkpoint, and patches the workflow JSON. See [Image generation](#image-generation)
for the full picture.

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

## Teardown

```bash
./teardown.sh             # Remove Docker containers + volumes (chat history, models)
./teardown.sh --full      # Also remove ComfyUI installation (~/ComfyUI)
./teardown.sh --nuclear   # Also remove all Ollama models + TLS certs
```

After any teardown, `./start.sh` rebuilds from scratch.

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

Both native processes are registered as **launchd user agents** on macOS, so
they auto-start on login and restart automatically if they crash. `start.sh`
installs these agents on first run — no manual setup needed.

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
IMAGE_MODEL=sdxl               # sdxl | flux-schnell | flux-dev
# HF_TOKEN=hf_xxx               # Required only for flux-dev (gated repo)
```

`IMAGE_MODEL` decides the checkpoint, sampler, cfg, step count, and
workflow that `start.sh` writes into Open WebUI. Direct overrides
(`COMFYUI_DEFAULT_MODEL_NAME` / `_URL`) still win for advanced users
dropping in a custom `.safetensors`.

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

Two backends, picked via `IMAGE_BACKEND` in `.env` (auto-detected if unset:
existing `~/ComfyUI` → `comfyui`, otherwise `ollama`).

### Backend: `ollama` (default for fresh installs, macOS only)

Open WebUI is wired to its built-in `openai` image engine, but the URL points
at `ollama-image-bridge` — a ~70-line FastAPI service that translates
`POST /v1/images/generations` into Ollama's `POST /api/generate`. Image gen
runs through the same Ollama process you already use for chat (Metal-accelerated
via Apple's Metal Performance Shaders).

Pros: no extra Python venv, no MPS dtype dragons, one fewer launchd agent,
~5.7 GB on disk for `x/flux2-klein:4b` (Apache 2.0). Cons: macOS only (Ollama
upstream limitation), still flagged "experimental" by Ollama.

### Backend: `comfyui` (Linux + power users)

ComfyUI runs natively on the host (not in Docker — Docker on macOS has **no**
access to Metal/MPS, so a container would be CPU-only). Open WebUI in Docker
reaches it via `host.docker.internal:8188`. SDXL VAE runs on CPU (`--cpu-vae`)
to dodge the recurring black-image NaN issue on Apple Silicon.

### What's included by default

- **Backend:** ComfyUI (latest), auto-installed at `~/ComfyUI` on first run
- **Model:** picked by `IMAGE_MODEL` in `.env` — defaults to **SDXL Base 1.0**
  (~6.5 GB). Set to `flux-schnell` (~17 GB) for higher quality and better
  prompt adherence; see [Switching image models](#switching-image-models).
- **Python:** ComfyUI uses its own Python 3.12 venv at `~/ComfyUI/venv`
  (PyTorch + dependencies are installed automatically)
- **Auto-start:** wired into `./start.sh` and `./stop.sh`
- **Disable:** set `ENABLE_IMAGE_GENERATION=false` in `.env`

On a fresh Mac, `./start.sh` does everything — clones ComfyUI, builds the
venv, installs PyTorch with MPS, downloads the checkpoint, then starts the
server. First run takes ~10–15 minutes for SDXL (or ~25–30 minutes for
Flux at typical home bandwidth). Subsequent runs are instant.

### Switching image models

Three presets ship out of the box. Set `IMAGE_MODEL` in `.env` and re-run
`./start.sh`:

| `IMAGE_MODEL` | Checkpoint | Size | Steps | CFG | Scheduler | License | Notes |
|---|---|---|---|---|---|---|---|
| `sdxl` | `sd_xl_base_1.0.safetensors` | 6.5 GB | 20 | 7.0 | normal | OpenRAIL | Reliable default. Comma-phrase prompts. |
| `flux-schnell` | `flux1-schnell-fp8.safetensors` | ~17 GB | 4 | 1.0 | simple | Apache-2.0 | Fast (4 steps), great prompt adherence, ungated. |
| `flux-dev` | `flux1-dev-fp8.safetensors` | ~17 GB | 20 | 1.0 | simple | Non-commercial | Top quality. **Gated** — set `HF_TOKEN` after [accepting the license](https://huggingface.co/black-forest-labs/FLUX.1-dev). |

What `./start.sh` does each time you switch:

1. Downloads the matching checkpoint into `~/ComfyUI/models/checkpoints/`
   (skipped if already present).
2. Warms ComfyUI by loading the checkpoint into MPS memory.
3. Patches the Open WebUI database with a model-tuned workflow JSON
   (correct cfg, steps, sampler, scheduler) and a `_managed_image_model`
   marker, then restarts the WebUI container so it picks up the new config.

All previously downloaded checkpoints stay on disk, so flipping back and
forth is just an `.env` edit + a script run — no re-download. The model
dropdown in WebUI's image settings will list every `.safetensors` in the
checkpoints directory; pick the one that matches `IMAGE_MODEL` for correct
results, since the workflow's cfg/steps/scheduler only match that one.

> **Why not configure Flux through WebUI's image settings UI?** WebUI
> exposes prompt, model, size, steps, and seed — but not cfg, sampler, or
> scheduler. Flux needs cfg=1.0 and scheduler=simple to produce sharp
> images; SDXL needs cfg=7 and scheduler=normal. Those live inside the
> workflow JSON, which `start.sh` writes to the DB on your behalf.

### How to use it in Open WebUI

No manual setup required — `./start.sh` configures the engine, URL, and
workflow automatically. Just open the chat and generate.

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

### Prompt tips

**SDXL** responds best to **comma-separated descriptive phrases**:

```
cyberpunk cat, neon-lit alley, rain, glowing eyes, cinematic lighting,
shallow depth of field, photorealistic, 8k, highly detailed
```

Useful negative prompt (image settings): `blurry, lowres, bad anatomy,
watermark, text, jpeg artifacts`.

**Flux (schnell or dev)** is the opposite — it understands **natural
sentences and even short paragraphs**, including text rendered inside the
image. No keyword-stuffing required:

```
A cyberpunk cat sitting in a rainy neon-lit alley, holding a paper sign
that reads "open source", cinematic lighting, shallow depth of field.
```

Flux is **distilled**, so the negative prompt is effectively unused — leave
it empty. CFG above 1 will make Flux output mushy or oversaturated.

`./start.sh` queues a warmup generation at startup so whichever checkpoint
is active is already in MPS memory when you first use the chat.
Generation times on Apple Silicon (M-series, 1024²): SDXL ~15–25 s,
Flux schnell ~30–60 s (4 steps), Flux dev ~2–4 min (20 steps).

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

Approximate peak working-set on Apple Silicon:

| Component | Peak RAM |
|---|---|
| macOS | ~4 GB |
| Ollama, 14B model | ~9 GB |
| SDXL (1024²) | ~6 GB |
| Flux schnell fp8 (1024²) | ~14 GB |
| Flux dev fp8 (1024²) | ~16 GB |

On a 16 GB Mac, **SDXL + Ollama** is tight but workable — macOS unified
memory will page when both are loaded. **Flux + Ollama on 16 GB is not
realistic**: stop Ollama (`ollama stop <model>`) before image sessions,
switch to a smaller LLM like `qwen2.5-coder:7b`, or plan on 32 GB+ for a
"both loaded" workflow.

### Adding more checkpoints

The three presets above (`sdxl`, `flux-schnell`, `flux-dev`) are managed
end-to-end by `./start.sh` — checkpoint download, warmup, and WebUI
workflow all line up. For anything else, drop a `.safetensors` file into
`~/ComfyUI/models/checkpoints/` and pick it from the model dropdown in
WebUI's image settings. The dropdown lists every file in that directory.

Heads-up: WebUI's bundled workflow expects a single-file checkpoint
loadable via `CheckpointLoaderSimple` (UNet+CLIP+VAE bundled). Multi-file
diffusers, GGUF quants, and SD 3.5 split-file releases need either custom
ComfyUI nodes or a custom workflow JSON. If you go down that road, you'll
likely also need to override `IMAGE_MODEL`'s defaults via the direct
escape hatches:

```env
COMFYUI_DEFAULT_MODEL_NAME=your-model.safetensors
COMFYUI_DEFAULT_MODEL_URL=https://...
```

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

## Container engine

The stack needs *some* Docker-compatible engine to run Open WebUI + Caddy.
**Colima** is the recommended pick: open source, ~200 MB RAM overhead,
auto-starts via `brew services`, supports `host.docker.internal` so
containers can reach the native Ollama and ComfyUI on the host.

```bash
brew install colima docker docker-compose
mkdir -p ~/.docker
echo '{"cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}' > ~/.docker/config.json
colima start --vm-type=vz --mount-type=virtiofs --cpu 2 --memory 4 --disk 30 \
    --mount "/Volumes/Development:w"   # add any other paths your project lives under
brew services start colima             # auto-start on login
```

> **Important:** containers reach the host via `host.docker.internal`,
> but native Ollama defaults to `127.0.0.1`-only. Set
> `launchctl setenv OLLAMA_HOST 0.0.0.0:11434` and restart Ollama (the
> Mac app reads it on launch) so the WebUI container can reach it. On
> Apple Silicon the Colima VM uses Apple's Virtualization framework
> (`vz`) for fast, low-overhead startup.

### Optional GUI

Colima is headless. If you want a desktop dashboard for containers,
install **[Podman Desktop](https://podman-desktop.io)** — it's FOSS,
talks to Docker sockets out of the box, and runs *independently* of the
engine. Open it when you need a GUI; quit it whenever — Colima and your
containers keep running untouched.

```bash
brew install --cask podman-desktop
```

Other supported engines (you don't have to use Colima):

| Engine | Notes |
|---|---|
| **Colima** | FOSS, lightweight, headless. Recommended. |
| **OrbStack** | Closed-source (free for personal use), faster boot, native GUI, very low overhead. |
| **Docker Desktop** | Heaviest of the three (~2–4 GB RAM). Works, but overkill for a server. |

## Prerequisites

- **macOS** (Apple Silicon recommended for Metal-accelerated Ollama + ComfyUI)
- A Docker engine — [Colima](https://github.com/abiosoft/colima) recommended (FOSS, lightweight). See [Container engine](#container-engine).
- [Ollama](https://ollama.com/download) installed (native mode runs it on the host)
- [mkcert](https://github.com/FiloSottile/mkcert) for local TLS (`brew install mkcert && mkcert -install`)
- At least **16 GB of RAM** (LLM + image gen are tight at this size, see Memory notes above)
- At least **30 GB of free disk space** for the SDXL default (LLM ~9 GB, SDXL ~6.5 GB, ComfyUI deps ~2 GB, headroom). Bump to **45 GB** if you plan to use Flux schnell or dev (~17 GB checkpoint).

## File overview

```
├── start.sh              Start everything (Docker stack + native ComfyUI)
├── stop.sh               Stop everything (keeps your data)
├── status.sh             Show what's running (services, loaded models, URLs)
├── teardown.sh           Remove data/installation (--full, --nuclear)
├── start-comfyui.sh      Start ComfyUI natively; installs launchd agent on macOS
├── stop-comfyui.sh       Stop ComfyUI natively; unloads launchd agent on macOS
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

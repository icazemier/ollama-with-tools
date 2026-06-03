# Local AI Stack

Run AI models on your own machine. Your code and conversations never leave your computer.

## Quick start

You'll need a Docker engine ([Colima](https://github.com/abiosoft/colima)
recommended — see [Container engine](#container-engine) below),
[Ollama](https://ollama.com/download), [mkcert](https://github.com/FiloSottile/mkcert),
and [Caddy](https://caddyserver.com/) (`brew install caddy` — `start.sh`
will install it for you if missing). Then:

```bash
./start.sh
```

> First run prompts for your sudo password once. It writes a system
> LaunchDaemon for Caddy (so HTTPS:443 binds at boot) and adds the
> ComfyUI venv Python to the macOS firewall (so other LAN devices can
> reach image generation). Subsequent runs are sudo-free.

Open **https://localhost** — you now have a local ChatGPT (with image
generation, mic, camera). HTTP fallback at http://localhost:3000.

On first visit you'll be asked to create an account; that account becomes
the admin. More users can be added from **Admin Panel → Users**. See
[Authentication](#authentication) for self-signup, role defaults, and how
to disable the login screen.

> First run takes a while (downloads Ollama LLM ~9 GB, FLUX.1-dev Q4_K_S GGUF
> stack ~12 GB, ComfyUI Python deps ~2 GB). After that, `./start.sh` takes
> seconds and works fully offline.

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

## Automatic cleanup

Open WebUI never garbage-collects its own file references — when you
delete a chat in the UI, the `file` row and its bytes in
`/app/backend/data/uploads/` stay forever. Over time the SQLite DB and
the volume bloat with orphaned attachments and generated-image copies.

`cleanup-media.sh` does a surgical GC across every chat-related table:

- delete `file` rows not referenced by any `chat_file`, `channel_file`,
  or `knowledge_file` row, plus their bytes on disk;
- delete `chat_file`, `chat_message`, `shared_chat`, `chatidtag`,
  `automation_run` rows whose `chat_id` no longer matches any `chat`;
- VACUUM the DB.

Every deletion is a strict anti-join — only rows with no live reference
go away. Nothing heuristic; nothing user-owned but not chat-bound (tags,
feedback, user accounts, folders, knowledge bases) is touched.

It runs **every hour** via launchd (agent
`local.ai-stack.cleanup-media`, installed by `start.sh`). Each run takes
under a second; no measurable cost.

```bash
./cleanup-media.sh             # run now
./cleanup-media.sh --dry-run   # preview what would be removed
```

Logs live at `logs/cleanup-media.log`. A timestamped backup of the
WebUI DB is written inside the container (`webui.db.bak-cleanup-…`)
before each real run.

The script deliberately **does not touch `~/ComfyUI/output/`**. WebUI
re-encodes images on import, so there's no byte-level correlation that
would let us prove a ComfyUI-side file is orphaned — those PNGs are the
full-quality originals; manage that directory by hand if it grows.

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
| **Ollama** *(docker mode)* | Runs LLMs in a container | Blocked — cannot phone home |

**Native on the host (managed by launchd):**

| Process | What it does | Why native |
|---|---|---|
| **Caddy** | HTTPS:443 terminator → reverse-proxy to WebUI | Colima/Lima can't forward host ports < 1024 (its port-forwarder uses unprivileged SSH); Caddy outside Docker is the only way HTTPS actually binds |
| **Ollama** *(native mode, default)* | Runs LLMs with Metal GPU | Docker on Mac has no Metal access |
| **ComfyUI** | Image generation with Metal GPU | Same — needs MPS for speed |

Caddy runs as a **system LaunchDaemon** (loaded into the root domain), so it
starts at boot *before* anyone logs in — HTTPS answers from a cold power-on.
Ollama and ComfyUI run as **user LaunchAgents** that start at login.

`start.sh` installs all three on first run. The Caddy install needs **one
sudo prompt** the first time, to write its plist into `/Library/LaunchDaemons/`;
afterwards every `./start.sh` is sudo-free (and idempotent — sudo is only
re-prompted if the plist content actually changes).

Open WebUI (in Docker) is reached by Caddy via `http://127.0.0.1:${WEBUI_PORT}`
on the host. The Docker network for AI containers is internal-only — no LLM
container can reach the internet.

### LAN access

Once `./start.sh` has run, the stack is reachable from any device on your
local network:

| URL | Goes to |
|---|---|
| `https://ai.local` *(mDNS)* | Open WebUI via Caddy (real HTTPS, trusted cert) |
| `https://<your-mac-LAN-IP>` | Same — for devices that don't do mDNS |
| `http://<your-mac-LAN-IP>:8188` | ComfyUI direct (image-gen API + UI) |
| `http://<your-mac-LAN-IP>:11434` | Ollama direct (LLM API) |

To trust the HTTPS cert on phones/tablets/other laptops, install the mkcert
root CA on them — `start.sh` prints the CA file path on first run.

> **ComfyUI on LAN — firewall whitelist:** macOS's Application Firewall
> silently drops connections to unsigned binaries on non-loopback interfaces,
> even when the binary listens on `0.0.0.0`. `start.sh` adds the ComfyUI
> venv Python to the firewall allow-list automatically (one sudo prompt the
> first time). Without that step, ComfyUI would only be reachable from the
> host itself.

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

### Authentication

Open WebUI runs with `WEBUI_AUTH=true` in `docker-compose.yml`, so a real
login screen guards the UI. On the very first page load after a fresh
install, the first account you create becomes the admin; subsequent users
are added from **Admin Panel → Users**.

- Sign-out genuinely logs you out (you land on `/auth`, not back in chat).
- Each user has their own chat history, settings, models, and files —
  switching accounts in a different browser/profile gives a clean inbox.
- Self-signup is off by default. To open it up for LAN guests, set
  `ENABLE_SIGNUP=true` in the WebUI environment and optionally
  `DEFAULT_USER_ROLE=user` to skip the admin-approval step.
- Sessions survive container restarts because the JWT signing key is
  persisted on the `webui-data` volume.

To temporarily switch back to the original single-user / no-login mode,
flip `WEBUI_AUTH=false` in `docker-compose.yml` and recreate the
`open-webui` container. Existing user accounts stay in the DB but become
unreachable until auth is re-enabled.

### Ollama keep-alive (FLUX OOM mitigation)

```env
OLLAMA_KEEP_ALIVE=30s   # Evict chat model from GPU 30 s after last request
```

On 16 GB unified memory the loaded chat model and a FLUX sample can't both
sit on the GPU at once. See [Memory notes](#memory-notes) for the full
diagnosis. `start.sh` propagates this value into the Ollama launchd plist
on every run.

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
- **Custom node:** [city96/ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF),
  auto-cloned so ComfyUI can load GGUF-quantized UNets
- **Model:** FLUX.1-dev Q4_K_S GGUF (~6.5 GB UNet) plus its text encoders
  (CLIP-L ~250 MB, T5-XXL FP8 ~4.9 GB) and VAE (~335 MB) — **~12 GB total**,
  all auto-downloaded on first run
- **Python:** ComfyUI uses its own Python 3.12 venv at `~/ComfyUI/venv`
  (PyTorch + dependencies are installed automatically)
- **Auto-start:** wired into `./start.sh` and `./stop.sh`
- **Disable:** set `ENABLE_IMAGE_GENERATION=false` in `.env`

On a fresh Mac, `./start.sh` does everything — clones ComfyUI, builds the
venv, installs PyTorch with MPS, installs the GGUF custom node, downloads
the four FLUX assets, then starts the server. First run takes ~15–25 minutes
(mostly the FLUX downloads). Subsequent runs are instant.

> **Why FLUX.1-dev Q4_K_S?** It's the largest/best-quality FLUX-dev quant that
> fits on a 16 GB Apple Silicon Mac alongside Ollama. Unquantized FLUX-dev
> needs 24+ GB; the Q4_K_S GGUF runs in ~6.5 GB and produces images that are
> a clear step up from SDXL. Expect 3–6 min per 1024×1024 image, longer if
> Ollama is sharing memory.

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

### Prompt tips for FLUX

FLUX is the opposite of SDXL on prompts. It was trained on natural-language
captions (via the T5 text encoder), so **full sentences with concrete
detail beat comma-separated tag soup**:

```
A serene mountain lake at golden hour, mist rising off the water, a single
small wooden rowboat near the far shore, dense pine forest on the hills
behind, cinematic photograph, shallow depth of field.
```

You can still drop adjectives in a list, but FLUX rewards specificity over
keyword stuffing. **Negative prompts are mostly inert** for FLUX-dev (it's
distilled with `cfg=1`), so leave the negative blank unless you have a
specific reason.

`./start.sh` queues a tiny 1-step warmup at startup so the GGUF UNet + T5
text encoder are already in MPS memory when you first use the chat.

### Editing existing images

WebUI's image edit feature is also wired to ComfyUI via the
`IMAGES_EDIT_COMFYUI_BASE_URL` env var (same backend, same port). To edit:
upload or generate an image, click the **edit icon**, paint a mask over the
area you want to change, and describe what should appear there.

Note: the default workflow used by `./start.sh` is text-to-image. Mask-aware
inpainting with FLUX requires a different workflow (FLUX.1 Fill or a custom
inpainting graph). That's not wired up by default — quality with the
text-to-image workflow used as inpainting is hit-or-miss. If you need real
inpainting, the upgrade path is **FLUX.1 Fill** (a separate ~6.6 GB GGUF
quant from city96) or **FLUX.1 Kontext** (instruction-style edits without
a mask).

### Memory notes

On a 16 GB Mac:
- macOS uses ~4 GB
- Ollama with a 14B model uses ~11 GB resident on the GPU
- FLUX peak: UNet (Q4_K_S) ~6.5 GB + T5-XXL FP8 ~5 GB + VAE/CLIP-L ~0.6 GB ≈ 12 GB

These can't all be resident at once. Worse, on Apple Silicon an in-flight
FLUX sample will OOM hard if Ollama is parked on the GPU — Metal aborts the
command buffer (`kIOGPUCommandBufferCallbackErrorOutOfMemory`), the sampler
keeps "progressing" through NaN tensors, and the VAE decodes a uniform
noise grid instead of an image.

The stack mitigates this by evicting Ollama from GPU memory aggressively:

- **`OLLAMA_KEEP_ALIVE=30s`** in `.env` — after the last chat request the
  loaded model is unloaded after 30 s, freeing ~11 GB for FLUX. Pay a one-time
  ~5–10 s reload tax the next time you chat; generation speed itself is
  unaffected. Tune higher if you don't use image gen often; tune lower if you
  want even more aggressive eviction.
- The value is wired through to `~/Library/LaunchAgents/local.ollama.server.plist`
  by `start.sh` (re-run it after editing `.env` to apply changes).

If you still see noise-grid output, manually unload Ollama with
`ollama stop <model>` and retry — or swap to a smaller Ollama model
(`qwen2.5-coder:7b`, ~5 GB) so the two can coexist.

### Swapping the FLUX quant

To trade quality against memory/speed, pick a different
[city96/FLUX.1-dev-gguf](https://huggingface.co/city96/FLUX.1-dev-gguf) quant
and drop it into `~/ComfyUI/models/unet/`. Quants on this hardware:

| Quant | UNet size | Notes |
|---|---|---|
| **Q2_K** | ~4 GB | Smallest. Visible quality loss but fastest, leaves memory for Ollama. |
| **Q4_K_S** | ~6.5 GB | **Default.** Best quality-per-byte balance for 16 GB. |
| **Q5_K_S** | ~8.3 GB | Sharper detail, tighter on memory with Ollama loaded. |
| **Q8_0** | ~12.7 GB | Near-FP16 quality, won't co-exist with Ollama 14B. |

After dropping a new file in, also update the `unet_name` reference in
`start.sh` (WebUI DB patch + warmup workflow) and `boot-stack.sh`, or just
edit it in **WebUI → Admin → Settings → Images → Default Model**.

### Adding a LoRA on top of FLUX

LoRAs are small (~50–300 MB) style/concept add-ons that ride alongside the
base UNet. The stack supports a single LoRA via two `.env` variables:

```dotenv
FLUX_LORA_NAME=my-style.safetensors
FLUX_LORA_STRENGTH=0.8
```

Steps:

1. Drop a FLUX-compatible `.safetensors` LoRA into
   `~/ComfyUI/models/loras/`. Civitai and Hugging Face both host plenty —
   make sure the model card says **FLUX.1** (SDXL LoRAs won't work).
2. Set `FLUX_LORA_NAME` to the filename only (no path). Leave it empty to
   disable. `FLUX_LORA_STRENGTH` is the model strength (typical range
   0.6–1.0; the LoRA's README usually recommends a value).
3. Re-run `./start.sh`. The patcher injects a `LoraLoaderModelOnly` node
   between `UnetLoaderGGUF` and the sampler, and rewrites the WebUI default
   workflow. Drift detection means subsequent runs are a no-op until you
   change the name/strength again.

**Shortcut: `./add-lora.sh <hf-url>`** does steps 1–3 in one shot — downloads
into `~/ComfyUI/models/loras/`, edits `.env`, and re-runs `./start.sh`. Pass
`--strength 0.7` to set the strength, `--name foo.safetensors` to rename on
download, `--token hf_xxx` for gated repos, or `--no-restart` to skip the
apply. `./add-lora.sh --help` for full usage.

If the target file already lives in `~/ComfyUI/models/loras/`, the script
skips the download and still updates `.env` + re-runs `./start.sh` — so
re-running with the same URL is a cheap way to **switch back** to an
already-downloaded LoRA. To force a fresh download, `rm` the file first.

**Safety: only `.safetensors` is accepted.** Legacy weight formats
(`.ckpt`, `.pt`, `.bin`, `.pth`) are Python pickles and can execute
arbitrary code on load. Both `start.sh` and `boot-stack.sh` refuse anything
that isn't `.safetensors` and warn loudly if `FLUX_LORA_NAME` points at a
file that doesn't exist on disk. The bytes in a `.safetensors` are inert
tensors, but the *behavior* a LoRA biases the model toward is still on you:
prefer LoRAs from named authors with documented trigger words, and skip
the ones with zero downloads and an empty model card.

Memory impact is small (LoRAs add ~1–2 GB on top of the UNet) but **does**
eat into the FLUX/Ollama coexistence margin — if you start seeing noise
grids again, that's the reason. Drop to a smaller quant or `qwen2.5-coder:7b`.

To stack multiple LoRAs you'd need a custom workflow in ComfyUI's own UI
(`http://localhost:8188`); the WebUI-driven path here is single-LoRA only
by design.

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
- At least **35 GB of free disk space** (LLM ~9 GB, FLUX assets ~12 GB, ComfyUI deps ~2 GB, headroom)

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

**Out of memory / FLUX produces a noise grid instead of an image**
On 16 GB Macs, an Ollama chat model parked on the GPU collides with the
FLUX sample → MPS aborts mid-step with
`kIOGPUCommandBufferCallbackErrorOutOfMemory` (visible in
`~/ComfyUI/comfyui.log`), the sampler runs to completion on NaN tensors,
and you get a flat noise grid. Mitigated by `OLLAMA_KEEP_ALIVE=30s` in
`.env` — see [Ollama keep-alive](#ollama-keep-alive-flux-oom-mitigation)
and [Memory notes](#memory-notes). If it still happens, `ollama stop
<model>` before triggering image gen, or pick a smaller chat model.

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

# FLUX.1-dev GGUF Migration — Progress Tracker

Living document so we can pick up where we left off across sessions.
**Delete this file once the migration is complete and merged into README.**

## Goal

Move the project's image-generation backend from **SDXL Base 1.0** to
**FLUX.1-dev Q4_K_S GGUF** running in ComfyUI on Apple M4 / 16 GB.

Why: SDXL works but quality is the floor of what's acceptable in 2026.
FLUX.1-dev is substantially better, and the GGUF Q4_K_S quant fits in
16 GB unified memory (the unquantized FLUX.1-dev needs 24+ GB).

## Hardware budget (M4, 16 GB unified)

| Component                          | Peak RAM |
|------------------------------------|----------|
| macOS                              | ~4 GB    |
| Ollama qwen2.5-coder:14b           | ~9 GB    |
| FLUX.1-dev Q4_K_S UNet (GGUF)      | ~6.5 GB  |
| T5-XXL FP8 text encoder            | ~5 GB    |
| CLIP-L                             | ~250 MB  |
| FLUX VAE (ae.safetensors)          | ~335 MB  |

Total of FLUX components alone: ~12 GB. With Ollama loaded too, we page —
stop Ollama with `ollama stop qwen2.5-coder:14b` before heavy image work
if needed. Expected time-to-image at 1024×1024 / 20 steps: 3–6 min.

## Component inventory

What FLUX needs that SDXL didn't:

| Where in ComfyUI                                   | File                                          | Source                                                |
|----------------------------------------------------|-----------------------------------------------|-------------------------------------------------------|
| `custom_nodes/ComfyUI-GGUF/`                       | (git clone)                                   | https://github.com/city96/ComfyUI-GGUF                |
| `models/unet/flux1-dev-Q4_K_S.gguf`                | ~6.5 GB                                       | https://huggingface.co/city96/FLUX.1-dev-gguf         |
| `models/clip/clip_l.safetensors`                   | ~250 MB                                       | https://huggingface.co/comfyanonymous/flux_text_encoders |
| `models/clip/t5xxl_fp8_e4m3fn.safetensors`         | ~4.9 GB                                       | https://huggingface.co/comfyanonymous/flux_text_encoders |
| `models/vae/ae.safetensors`                        | ~335 MB                                       | https://huggingface.co/black-forest-labs/FLUX.1-schnell (Apache 2.0 mirror of the same VAE) |

Total new download: ~12 GB.

## Migration steps & status

Statuses: `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked

### Install + assets
- [x] **2 — Install ComfyUI-GGUF custom node** in `~/ComfyUI/custom_nodes/`
  - Cloned `city96/ComfyUI-GGUF` to `~/ComfyUI/custom_nodes/ComfyUI-GGUF`
  - Installed `gguf`, `sentencepiece`, `protobuf` into `~/ComfyUI/venv`
  - All three import cleanly from the venv
- [x] **3 — Download FLUX.1-dev Q4_K_S GGUF UNet** into `~/ComfyUI/models/unet/` (6.3 GB on disk, ~6.81 GB byte count)
- [x] **4 — Download FLUX text encoders** into `~/ComfyUI/models/clip/`
  - `clip_l.safetensors` (235 MB) ✓
  - `t5xxl_fp8_e4m3fn.safetensors` (4.6 GB) ✓
- [x] **5 — Download FLUX VAE** into `~/ComfyUI/models/vae/`
  - Source: `Comfy-Org/Lumina_Image_2.0_Repackaged/split_files/vae/ae.safetensors` (335 MB, ungated mirror — the BFL FLUX.1-schnell repo turned out to be 401-gated)

### Verify ComfyUI side works
- [x] **6 — Smoke test FLUX directly** via ComfyUI `/prompt` API at 1024×1024
  - Output: `~/ComfyUI/output/Flux_00001_.png` (1024×1024, 1.1 MB, atmospheric misty mountain lake — quality clearly above SDXL)
  - Sampling time: 20 steps × ~30 s/step = ~10 min wall-clock with Ollama 14B still resident (~9 GB). Without Ollama in memory it should land in the 3–6 min range as predicted.
  - GGUF loader reported `gguf qtypes: F32 (471), Q4_K (304), F16 (5)` — Q4 quant active as intended.

### Wire the project up
- [x] **7 — Update `start-comfyui.sh`**
  - Dropped `COMFYUI_DEFAULT_MODEL_NAME` / `COMFYUI_DEFAULT_MODEL_URL` (no longer a single checkpoint)
  - Added `FLUX_ASSETS` array (path|URL pairs) and a download loop that skips files already present
  - Added auto-install of the `city96/ComfyUI-GGUF` custom node (clones + `pip install -r requirements.txt`)
  - Kept `--force-upcast-attention --cpu-vae --lowvram` flags (FLUX has the same MPS NaN issues)
  - Updated `.env.example` — removed dead SDXL env vars, documented the `.skip_flux_download` escape hatch
- [x] **8 — Update WebUI DB patch** in `start.sh` AND `boot-stack.sh`
  - `model` → `flux1-dev-Q4_K_S.gguf`, `engine` → `comfyui`, `size` → `1024x1024`, `steps` → `20`
  - `comfyui.workflow` now set explicitly to the FLUX workflow JSON (Open WebUI's default is SDXL-shaped, so we must write our own)
  - `comfyui.nodes` mapping: only delta vs SDXL is `ckpt_name` → `unet_name`
  - `NEEDS_PATCH` detection now also parses the stored workflow and checks node 4 is `UnetLoaderGGUF`
- [x] **9 — Update warmup workflow** in `start.sh` and `boot-stack.sh` to a 1-step / 256×256 FLUX workflow
- [x] **10 — Update `README.md`**
  - Removed "FLUX.1-dev needs 32+ GB" claim and the SDXL prompt-tips
  - New "Prompt tips for FLUX" with natural-sentence guidance
  - "What's included by default" now lists all four FLUX assets and the GGUF custom node
  - New "Swapping the FLUX quant" table for Q2_K through Q8_0
  - Disk-space estimate bumped to 35 GB

### Validate
- [x] **11 — End-to-end test**: switched `.env` to `IMAGE_GEN_BACKEND=comfyui`, ran `./start.sh`
  - DB verification: engine=comfyui ✓, model=flux1-dev-Q4_K_S.gguf ✓, workflow has UnetLoaderGGUF/EmptySD3LatentImage/DualCLIPLoader/FluxGuidance ✓
  - Simulated-WebUI substitution (looked up the workflow + `nodes` mapping straight out of webui.db, injected values by `type`, posted to ComfyUI) — output `Flux_00003_.png` matches the prompt exactly. Workflow + node mapping + WebUI substitution mechanism all confirmed correct.
  - Still untested by the *actual* WebUI HTTP path, but that path only does what we just simulated. Worth a sanity click through the WebUI chat (`+ → Image` toggle) just to be sure the UI surfaces the engine correctly — see "Remaining for the user" below.

## Open decisions

- **Keep SDXL files around?** Yes for now — they cost only disk. The DB patch picks the active workflow, so a manual rollback is just `git revert` of the patch commit. Once FLUX has run in anger for a week, we can prune SDXL.
- **Auto-download FLUX assets in `start-comfyui.sh`?** Lean yes for parity with the old SDXL bootstrap — but ~12 GB on first run is a lot. Maybe gate behind a `COMFYUI_AUTO_DOWNLOAD_FLUX=true` env (default true), so power users on metered connections can opt out.
- **Schnell as a faster fallback?** Out of scope for this migration. Revisit if 3–6 min/image proves annoying.

## FLUX workflow JSON (design — locked unless smoke test fails)

Draft saved at `/tmp/flux-workflow.json` during the live session. Node-ID layout
deliberately keeps the SDXL workflow's IDs (3 = KSampler, 4 = model loader,
5 = empty latent, 6/7 = positive/negative CLIPTextEncode, 8 = VAEDecode,
9 = SaveImage) so the Open WebUI `nodes` mapping only needs one key
change. New nodes 10, 11, 12 hold FLUX-specific pieces.

| Node | Class                  | Purpose                                            |
|------|------------------------|----------------------------------------------------|
| 3    | KSampler               | cfg=1.0, sampler=euler, scheduler=simple, steps=20 |
| 4    | UnetLoaderGGUF         | loads `flux1-dev-Q4_K_S.gguf` (key: `unet_name`)   |
| 5    | EmptySD3LatentImage    | FLUX needs 16-channel latent, NOT EmptyLatentImage |
| 6    | CLIPTextEncode         | positive prompt, clip from node 11                 |
| 7    | CLIPTextEncode         | negative (empty — FLUX uses cfg=1)                 |
| 8    | VAEDecode              | vae from node 10                                   |
| 9    | SaveImage              | filename_prefix=Flux                               |
| 10   | VAELoader              | loads `ae.safetensors`                             |
| 11   | DualCLIPLoader         | `clip_name1=t5xxl_fp8_e4m3fn`, `clip_name2=clip_l`, `type=flux` |
| 12   | FluxGuidance           | guidance=3.5; wraps node 6 → KSampler positive     |

WebUI `nodes` mapping — **only diff vs SDXL is `'ckpt_name'` → `'unet_name'`**:

```python
[
    {'type': 'prompt',   'key': 'text',       'node_ids': ['6']},
    {'type': 'model',    'key': 'unet_name',  'node_ids': ['4']},
    {'type': 'width',    'key': 'width',      'node_ids': ['5']},
    {'type': 'height',   'key': 'height',     'node_ids': ['5']},
    {'type': 'steps',    'key': 'steps',      'node_ids': ['3']},
    {'type': 'seed',     'key': 'seed',       'node_ids': ['3']},
]
```

Other config:
- `engine = 'comfyui'`
- `model = 'flux1-dev-Q4_K_S.gguf'`
- `size = '1024x1024'`
- `steps = 20`
- `comfyui.workflow = json.dumps(<the JSON above>)` — **must set explicitly**; the current SDXL workflow in webui.db came from Open WebUI's built-in default, which our previous patch never wrote. For FLUX we must.

## Remaining for the user

- [ ] Open `https://localhost` in a browser, start a chat, click the **`+`** menu next to the input, flip the **Image** toggle on, type a prompt (a full sentence works best for FLUX), send. Confirm an image arrives within ~3–10 min. Compare against the embedded test outputs at `~/ComfyUI/output/Flux_00001_.png` (mountain lake) and `Flux_00003_.png` (robot artist).
- [ ] *Optional, when satisfied:* delete `~/ComfyUI/models/checkpoints/sd_xl_base_1.0.safetensors` to free 6.5 GB. Nothing in the active workflow uses it anymore.
- [ ] *Optional:* `kill $(cat logs/draw-things-proxy.pid)` to stop the orphaned Draw Things A1111 proxy that was running before the switch. It's harmless but binds port 7861.
- [ ] *Optional:* delete this `FLUX-MIGRATION.md` once you're happy — the README now documents the FLUX setup. Keep it only as long as the migration is "still being absorbed."

## Notes & gotchas as we hit them

(Append findings here as we discover them — keep raw, no need to be polished.)

- 2026-05-28 FLUX.1-schnell on Hugging Face is **gated** (401) even though licensed Apache 2.0 — pulling the VAE from `Comfy-Org/Lumina_Image_2.0_Repackaged/split_files/vae/ae.safetensors` works ungated; same 335 MB file. This is also the path ComfyUI's own FLUX tutorial recommends.
- 2026-05-28 `gguf` Python module installs from PyPI without `__version__` attr; don't probe it.
- 2026-05-28 ComfyUI is currently running with `--force-upcast-attention --cpu-vae --lowvram`. These flags are kept for FLUX too; `--cpu-vae` is especially important because FLUX VAE on MPS has the same NaN-black-image issue as SDXL.
- 2026-05-28 The Open WebUI `nodes` mapping uses each entry's `type` as the lookup key into WebUI's runtime value dict (`{'prompt', 'model', 'width', 'height', 'steps', 'seed'}`), and uses `key` as the *ComfyUI input field name* to write into. So changing the loader class (CheckpointLoaderSimple → UnetLoaderGGUF) only required flipping `key` from `ckpt_name` to `unet_name`; `type` stays `model`.
- 2026-05-28 First FLUX image at 1024×1024 / 20 steps with Ollama 14B resident took ~10 min wall (~30 s/step). With Ollama unloaded (`ollama stop qwen2.5-coder:14b`) it should land in the 3–6 min range — worth measuring once the dust settles.

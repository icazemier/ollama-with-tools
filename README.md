# Local AI Stack

Run AI models on your own machine. Your code and conversations never leave your computer.

## Quick start

Make sure [Docker Desktop](https://www.docker.com/products/docker-desktop/) is installed and running, then:

```bash
./start.sh
```

That's it. Open **http://localhost:3000** — you now have a local ChatGPT.

> First run takes a few minutes (building containers + downloading ~9 GB model).
> After that, `./start.sh` takes seconds and works fully offline.

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

- **Chat UI** at localhost:3000 — looks and feels like ChatGPT
- **VS Code integration** — AI chat + code completions via Continue
- **100% local** — your prompts and code are never sent anywhere
- **Chat history** — saved locally, survives restarts
- **Swappable models** — try different AI models by editing `models.conf`
- **Dev sandbox** — a container with Node.js 22, git, and Azure CLI

## Stopping and restarting

```bash
./stop.sh               # Stop (models and chat history are kept)
./start.sh              # Start again
```

## How it works

Three containers run inside Docker:

| Container | What it does | Internet? |
|---|---|---|
| **Ollama** | Runs the AI model | Blocked — cannot phone home |
| **Open WebUI** | Chat UI for your browser + API for VS Code | Local only |
| **Sandbox** | Node.js + git + Azure CLI dev environment | Git/Azure only |

The AI model has **zero internet access**. It physically cannot send your code or conversations anywhere — it's on an isolated Docker network with no route to the outside world.

Verify it yourself: `./test-privacy.sh`

## Configuration

Edit `.env` and re-run `./start.sh` to apply changes.

### Resource limits

```env
OLLAMA_CPUS=4        # More CPUs = faster AI responses
OLLAMA_MEMORY=12g    # Must fit the model + overhead — 12g for 14B models
WEBUI_CPUS=1
WEBUI_MEMORY=1g
SANDBOX_CPUS=2
SANDBOX_MEMORY=4g
```

### Shared folder (optional)

Share a folder from your machine with the sandbox container — this is how you get project files in and out:

```env
SHARED_FOLDER=./workspace
# or an absolute path:
# SHARED_FOLDER=/Users/you/projects/my-app
```

The folder appears at `/workspace` inside the sandbox.

### Git and SSH (optional)

Mount your SSH keys and git config so you can push/pull repos from the sandbox:

```env
SSH_KEY_PATH=~/.ssh
GIT_CONFIG_PATH=~/.gitconfig
```

These are mounted **read-only** — the sandbox can use your keys but cannot change them.

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

## Using the sandbox

```bash
# Open a shell
docker exec -it sandbox bash

# Run Node.js
docker exec sandbox node -e "console.log('hello')"

# Git (requires SSH_KEY_PATH in .env)
docker exec sandbox git clone git@github.com:you/your-repo.git

# Azure CLI (authenticate first: az login --use-device-code)
docker exec sandbox az devops project list --organization https://dev.azure.com/your-org
```

### JavaScript/TypeScript projects

Set `SHARED_FOLDER` in `.env` to your project folder, then:

```bash
docker exec -it sandbox bash
cd /workspace
npm install          # node_modules stay inside the container
npm run build
npm test
```

The `node_modules` folder is stored in a Docker volume — it won't conflict with any local `node_modules` on your machine.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- At least **16 GB of RAM** (the default model uses ~10 GB)
- At least **20 GB of free disk space** for model downloads

## File overview

```
├── start.sh              Start everything (downloads models automatically)
├── stop.sh               Stop everything (keeps your data)
├── pull-models.sh        Manage models (--cleanup to remove unused)
├── test-privacy.sh       Verify the AI is properly isolated
├── .env.example          Settings template (copy to .env)
├── .env                  Your settings (not in git)
├── models.conf           Which AI models to download
├── docker-compose.yml    Defines containers and networks
└── sandbox/
    └── Dockerfile        What's installed in the sandbox
```

## Troubleshooting

**"No models available" in the chat UI**
Run `./start.sh` — it downloads models automatically. Make sure you have internet on the first run.

**Models are slow**
This runs on CPU (no GPU in Docker on macOS). Use smaller models or increase `OLLAMA_CPUS` in `.env`.

**Out of memory**
Lower `OLLAMA_MEMORY` in `.env`, or give Docker Desktop more RAM (Settings → Resources).

**Port 3000 already in use**
Change `WEBUI_PORT` in `.env`, then `./start.sh`.

**VS Code Continue can't connect**
Make sure the stack is running (`./start.sh`), and that the API key in `config.yaml` matches the one from Open WebUI.

**Sandbox can't git push/pull**
Uncomment `SSH_KEY_PATH` in `.env` and restart with `./start.sh`.

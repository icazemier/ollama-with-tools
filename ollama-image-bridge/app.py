"""
ollama-image-bridge — translates OpenAI-style image generation requests into
Ollama /api/generate calls so Open WebUI's "openai" image engine can target
Ollama image models (x/flux2-klein, x/z-image-turbo).

Endpoints:
  POST /v1/images/generations  — OpenAI-compatible (b64_json response only)
  GET  /v1/models              — courtesy listing of the configured model
  GET  /health                 — liveness check
"""
from __future__ import annotations

import os
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434").rstrip("/")
DEFAULT_MODEL = os.environ.get("IMAGE_MODEL", "x/flux2-klein:4b")
DEFAULT_SIZE = os.environ.get("DEFAULT_IMAGE_SIZE", "1024x1024")
REQUEST_TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT", "600"))

app = FastAPI(title="ollama-image-bridge")


class ImageRequest(BaseModel):
    model: Optional[str] = None
    prompt: str
    n: int = 1
    size: Optional[str] = None
    response_format: Optional[str] = None  # ignored — we always return b64_json


def parse_size(size: Optional[str]) -> tuple[int, int]:
    raw = (size or DEFAULT_SIZE).lower().replace("×", "x")
    try:
        w, h = raw.split("x", 1)
        return int(w), int(h)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"invalid size: {size!r}") from exc


async def ollama_generate(client: httpx.AsyncClient, model: str, prompt: str, w: int, h: int) -> str:
    r = await client.post(
        f"{OLLAMA_BASE_URL}/api/generate",
        json={"model": model, "prompt": prompt, "width": w, "height": h, "stream": False},
        timeout=REQUEST_TIMEOUT,
    )
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"ollama {r.status_code}: {r.text[:500]}")
    body = r.json()
    image = body.get("image")
    if not image:
        raise HTTPException(status_code=502, detail=f"ollama returned no image: {str(body)[:500]}")
    return image


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "ollama": OLLAMA_BASE_URL, "default_model": DEFAULT_MODEL}


@app.get("/v1/models")
async def list_models() -> dict:
    return {
        "object": "list",
        "data": [{"id": DEFAULT_MODEL, "object": "model", "owned_by": "ollama"}],
    }


@app.post("/v1/images/generations")
async def create_image(req: ImageRequest) -> dict:
    model = req.model or DEFAULT_MODEL
    width, height = parse_size(req.size)
    n = max(1, req.n)
    images: list[str] = []
    async with httpx.AsyncClient() as client:
        for _ in range(n):
            images.append(await ollama_generate(client, model, req.prompt, width, height))
    return {"created": 0, "data": [{"b64_json": img} for img in images]}

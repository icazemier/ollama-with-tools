#!/usr/bin/env python3
"""
Draw Things → A1111 API proxy.

Open WebUI's automatic1111 engine expects three endpoints that Draw Things
does not implement: GET/POST /sdapi/v1/options and GET /sdapi/v1/sd-models.
This proxy provides those stubs and translates POST /sdapi/v1/txt2img to
Draw Things' actual format (model passed in payload, cfg_scale→guidance_scale).

Port 7861 (proxy) → Draw Things port 7860.
Edit MODELS below to match the models you have downloaded in Draw Things.
"""
import json
import os
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

DRAW_THINGS_URL = os.environ.get("DRAW_THINGS_URL", "http://localhost:7860")
PROXY_PORT = int(os.environ.get("DRAW_THINGS_PROXY_PORT", "7861"))
DEFAULT_MODEL = os.environ.get("DRAW_THINGS_DEFAULT_MODEL", "flux_1_dev_q4p.ckpt")

MODELS = [
    {"title": "FLUX.1-dev Q4", "model_name": "flux_1_dev_q4p.ckpt"},
    {"title": "FLUX.1-dev Q6", "model_name": "flux_1_dev_q6p.ckpt"},
    {"title": "FLUX.1-schnell Q4", "model_name": "flux_1_schnell_q4p.ckpt"},
    {"title": "FLUX.1-schnell Q6", "model_name": "flux_1_schnell_q6p.ckpt"},
]

_state_lock = threading.Lock()
_current_model = DEFAULT_MODEL


class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        pass

    def _send_json(self, status: int, data: object) -> None:
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length)) if length else {}

    def do_GET(self) -> None:
        if self.path.startswith("/sdapi/v1/options"):
            with _state_lock:
                model = _current_model
            self._send_json(200, {"sd_model_checkpoint": model, "sd_vae": "Automatic"})
        elif self.path.startswith("/sdapi/v1/sd-models"):
            self._send_json(200, MODELS)
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        global _current_model
        body = self._read_body()

        if self.path.startswith("/sdapi/v1/options"):
            if "sd_model_checkpoint" in body:
                with _state_lock:
                    _current_model = body["sd_model_checkpoint"]
            self._send_json(200, {})

        elif self.path.startswith("/sdapi/v1/txt2img"):
            with _state_lock:
                model = _current_model
            draw_things_payload = {
                "model": model,
                "prompt": body.get("prompt", ""),
                "negative_prompt": body.get("negative_prompt", ""),
                "steps": body.get("steps", 20),
                "guidance_scale": body.get("cfg_scale", 7.5),
                "width": body.get("width", 1024),
                "height": body.get("height", 1024),
                "seed": body.get("seed", -1),
                "batch_size": body.get("batch_size", 1),
            }
            if "sampler_name" in body:
                draw_things_payload["sampler"] = body["sampler_name"]

            try:
                encoded = json.dumps(draw_things_payload).encode()
                request = urllib.request.Request(
                    f"{DRAW_THINGS_URL}/sdapi/v1/txt2img",
                    data=encoded,
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(request, timeout=600) as response:
                    result = json.loads(response.read())
                self._send_json(200, result)
            except urllib.error.URLError as error:
                self._send_json(502, {"error": str(error)})
            except Exception as error:
                self._send_json(500, {"error": str(error)})

        else:
            self._send_json(404, {"error": "not found"})


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PROXY_PORT), ProxyHandler)
    print(f"Draw Things proxy on :{PROXY_PORT} → {DRAW_THINGS_URL}", flush=True)
    server.serve_forever()

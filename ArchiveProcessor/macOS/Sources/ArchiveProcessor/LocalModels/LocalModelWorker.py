"""Private mlx-vlm worker for Archive Processor's app-managed local models.

LocalModelSupervisor.swift is the only thing that starts it, one model at a time: the model and its pinned revision
arrive in ARCHIVE_MODEL_REPO and ARCHIVE_MODEL_REVISION, the per-launch secret in ARCHIVE_MODEL_SECRET.

Two requests: POST /read (one image and a prompt, the label reader's) and POST /v1/chat/completions, the subset of the
OpenAI API the app's client for a model on this Mac sends (W49.proc-managed-local-ocr): one user message of text and
data-URL JPEG parts, max_tokens, temperature, repetition_penalty, enable_thinking, and stream (server-sent events).
"""
import base64
import hmac
import io
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

MODEL = os.environ["ARCHIVE_MODEL_REPO"]
REVISION = os.environ["ARCHIVE_MODEL_REVISION"]
# The request names its own cap (a label reply is one short JSON object); this bounds what it may ask for.
MAX_TOKENS_CEILING = 8192
# A chat request may carry a page and the page before it, as base64 JPEGs.
MAX_CHAT_BYTES = 40_000_000


def download():
    # Check the installed inference software before marking the download complete.
    from mlx_vlm import load, stream_generate  # noqa: F401

    snapshot()


def snapshot(local_only=False):
    from huggingface_hub import snapshot_download

    return snapshot_download(
        MODEL, revision=REVISION, token=False, local_files_only=local_only,
        allow_patterns=["*.jinja", "*.json", "*.model", "*.safetensors", "*.txt"],
    )


def serve(secret):
    # No SIGTERM handler: the supervisor's stop at app quit relies on SIGTERM's default action (and stdin closing).
    # The parent keeps stdin open. EOF lets an idle worker exit cleanly and bounds
    # the lifetime of a worker still loading or generating after a forced quit.
    parent_gone = threading.Event()
    stopped = threading.Event()

    def watch_parent():
        sys.stdin.buffer.read(1)
        parent_gone.set()
        if not stopped.wait(2):
            os._exit(0)

    threading.Thread(target=watch_parent, daemon=True).start()

    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from PIL import Image

    mx.set_cache_limit(256 * 2**20)
    model, processor = load(snapshot(local_only=True))

    def chat_inputs(data):
        """The prompt text and the images of the request's messages, in order."""
        texts, images = [], []
        for message in data.get("messages") or []:
            content = message.get("content")
            for part in [{"type": "text", "text": content}] if isinstance(content, str) else content or []:
                if part.get("type") == "text":
                    texts.append(part.get("text") or "")
                elif part.get("type") == "image_url":
                    field = part.get("image_url")
                    url = field.get("url") if isinstance(field, dict) else field
                    if not isinstance(url, str) or not url.startswith("data:") or "," not in url:
                        raise ValueError("images must be data URLs")
                    raw = base64.b64decode(url.split(",", 1)[1], validate=True)
                    with Image.open(io.BytesIO(raw)) as photo:
                        images.append(photo.convert("RGB"))
        return "\n".join(texts), images

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.path not in ("/read", "/v1/chat/completions") or not hmac.compare_digest(
                self.headers.get("Authorization", ""), secret
            ):
                self.send_error(403)
                return
            if self.path == "/v1/chat/completions":
                self.chat()
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 6_000_000:
                    self.send_error(413)
                    return
                data = json.loads(self.rfile.read(size))
                max_tokens = int(data.get("max_tokens", 640))
                if not 0 < max_tokens <= MAX_TOKENS_CEILING:
                    self.send_error(400)
                    return
                with Image.open(io.BytesIO(base64.b64decode(data["image"], validate=True))) as photo:
                    chat = apply_chat_template(processor, model.config, data["prompt"], num_images=1)
                    parts, tokens = [], 0
                    for part in stream_generate(
                        model, processor, chat, image=[photo.convert("RGB")],
                        max_tokens=max_tokens, temperature=0.0,
                    ):
                        parts.append(part.text)
                        tokens = part.generation_tokens
                body = json.dumps({"text": "".join(parts) if tokens < max_tokens else ""}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception:
                self.send_error(500)

        def chat(self):
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= MAX_CHAT_BYTES:
                    self.send_error(413)
                    return
                data = json.loads(self.rfile.read(size))
                max_tokens = int(data.get("max_tokens", 4096))
                penalty = data.get("repetition_penalty")
                if not 0 < max_tokens <= MAX_TOKENS_CEILING or (
                    penalty is not None and not 1 <= float(penalty) <= 2
                ):
                    self.send_error(400)
                    return
                prompt, images = chat_inputs(data)
                stream = data.get("stream") is True
                options = {"max_tokens": max_tokens, "temperature": float(data.get("temperature", 0.0))}
                if penalty is not None:
                    options["repetition_penalty"] = float(penalty)
            except (ValueError, KeyError, TypeError, OSError, AttributeError):
                self.send_error(400)
                return
            started = False
            try:
                chat = apply_chat_template(processor, model.config, prompt, num_images=len(images),
                                           enable_thinking=data.get("enable_thinking") is True)
                if stream:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    started = True
                parts, tokens = [], 0
                for part in stream_generate(model, processor, chat, image=images or None, **options):
                    tokens = part.generation_tokens
                    if stream and part.text:
                        self.event({"choices": [{"index": 0, "delta": {"content": part.text}, "finish_reason": None}]})
                    parts.append(part.text)
                finish = "length" if tokens >= max_tokens else "stop"
                if stream:
                    self.event({"choices": [{"index": 0, "delta": {}, "finish_reason": finish}]})
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                    return
                body = json.dumps({"choices": [{"index": 0, "finish_reason": finish,
                                                "message": {"role": "assistant", "content": "".join(parts)}}]}).encode()
                started = True
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                # The app closed the stream (a reply that started repeating itself): stop generating.
                pass
            except Exception:
                try:
                    if not started:
                        self.send_error(500)
                    elif stream:
                        self.event({"error": {"message": "The model failed while answering"}})
                except OSError:
                    pass

        def event(self, payload):
            self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
            self.wfile.flush()

        def log_message(self, *_):
            pass

    class Server(HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(15)
            return connection, address

    # The OS assigns an unused port. Only this app knows the per-launch secret.
    with Server(("127.0.0.1", 0), Handler) as server:
        print(f"ARCHIVE_MODEL_PORT {server.server_port}", flush=True)
        server.timeout = 0.25
        while not parent_gone.is_set():
            server.handle_request()
    stopped.set()


if __name__ == "__main__":
    if sys.argv[1] == "download":
        download()
    elif sys.argv[1] == "serve":
        serve(os.environ.pop("ARCHIVE_MODEL_SECRET"))

"""A stand-in for luoke-core's task layer, for trying luoke-search's command line end to end without a hub.

HTTP/1.1 on a Unix socket of its own (never luoke-core's), answering as luoke-core V1 §2 does for the task luoke-search.embed:
GET /tasks, POST /tasks/luoke-search.embed/v1/embed, /warmup, /accessory/resident, /accessory/exiting. Its vectors are made
up (the same text always gets the same unit vector), so rankings mean nothing: it's for the plumbing, not for evals.

    python3 -I scripts/fake_hub.py --socket /tmp/lsfake.sock --mode-file .dev/fake-hub-mode

The mode file holds a word or two, read on every request, so a test can change it while this runs:
  available    vectors for every text request (the default when the file is missing or empty); text only
  media        as available, and pictures and sound too, as `inputs` (luoke-core's multimodal draft, 4d1f5f6 /
               c80cf7b): GET /tasks gives image_batch, audio_batch and the rest; "media busy" combines
  unsupported  the task isn't offered on this Mac (as in beta1): 404 unsupported
  busy         background requests refused: 503 busy, reason interactive, retry_after 5
  cooldown     as luoke-core's balanced mode paces itself: after each background embed, the next half second's
               background requests get 503 busy, reason power_cooldown, retry_after 1 and the exact retry_after_ms
  downloading  the model is downloading: GET /tasks says so, embed answers 404 task_unavailable
Logs one line per request on stderr: method, path, priority, how many texts, pictures and recordings. Never them.
"""

import argparse
import base64
import binascii
import hashlib
import http.server
import json
import math
import os
import random
import signal
import socketserver
import sys
import time

DIMS = 768
TASK = "luoke-search.embed"
BUDGETS = [70, 140, 280, 560, 1120]
MEDIA_PARAMS = {"image_batch": 8, "audio_batch": 2, "image_budgets": BUDGETS, "max_image_bytes": 4_000_000,
                "max_audio_bytes": 1_100_000, "max_audio_secs": 30}


def vector(key):
    rng = random.Random(hashlib.sha256(key if isinstance(key, bytes) else key.encode("utf-8")).digest())
    values = [rng.gauss(0, 1) for _ in range(DIMS)]
    norm = math.sqrt(sum(v * v for v in values))
    return [round(v / norm, 5) for v in values]


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def address_string(self):
        return "uds"

    def log_message(self, fmt, *args):
        pass

    def modes(self):
        try:
            with open(self.server.mode_file, encoding="utf-8") as f:
                return set(f.read().split()) or {"available"}
        except OSError:
            return {"available"}

    def mode(self):
        """The word that decides the task's state: the first of unsupported, downloading, busy; else available."""
        modes = self.modes()
        return next((m for m in ("unsupported", "downloading", "busy") if m in modes), "available")

    def answer(self, status, body, retry_after=None):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Luoke-Contract", "1")
        self.send_header("X-Luoke-Tasks-Version", "fake-" + "-".join(sorted(self.modes())))
        if retry_after:
            self.send_header("Retry-After", str(int(retry_after)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def refuse(self, status, code, message, retry_after=None, reason=None, retry_after_ms=None):
        body = {"code": code, "message": message, "retry_after": retry_after}
        if reason:
            body["reason"] = reason
        if retry_after_ms is not None:
            body["retry_after_ms"] = retry_after_ms
        self.answer(status, body, retry_after)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def route(self, method):
        mode = self.mode()
        accessory = self.headers.get("X-Luoke-Accessory") or ""
        priority = self.headers.get("X-Luoke-Priority") or "-"
        media = "media" in self.modes()
        body = self.body() if method != "GET" else {}
        texts = body.get("texts") or []
        inputs = body.get("inputs") if isinstance(body.get("inputs"), list) else []
        kinds = [next((k for k in ("text", "image", "audio") if isinstance(i, dict) and k in i), "?") for i in inputs]
        print(f"[fake hub] {' '.join(sorted(self.modes()))} {method} {self.path} {accessory} priority={priority} "
              f"texts={len(texts) + kinds.count('text')} images={kinds.count('image')} audio={kinds.count('audio')}",
              file=sys.stderr, flush=True)
        if not accessory.startswith("luoke-search/"):
            return self.refuse(403, "unknown_accessory", "missing X-Luoke-Accessory")
        if method == "GET" and self.path == "/tasks":
            status = {"available": "available", "unsupported": "unsupported", "busy": "available",
                      "downloading": "downloading"}.get(mode, "available")
            task = {"kind": "embed", "main": True, "status": status,
                    "reason": {"unsupported": "本档没有这个任务用的模型", "downloading": "正在下载"}.get(mode),
                    "progress": 0.4 if mode == "downloading" else None, "slow": None,
                    "combo": "fake-embeddinggemma-2", "vector_space": None if mode == "unsupported" else self.server.space,
                    "params": {"batch": self.server.batch, "max_tokens": 2048, "max_chars": 32000,
                               **(MEDIA_PARAMS if media else {})}}
            return self.answer(200, {"contract": 1, "hub_version": "fake", "tier": "32",
                                     "tasks_version": "fake-" + "-".join(sorted(self.modes())),
                                     "background": {"state": "running", "reasons": []}, "tasks": {TASK: task}})
        if method == "POST" and self.path == f"/tasks/{TASK}/v1/embed":
            if mode == "unsupported":
                return self.refuse(404, "unsupported", "本档没有这个任务用的模型")
            if mode == "downloading":
                return self.refuse(404, "task_unavailable", "正在下载")
            if mode == "busy" and priority != "user-waiting":
                return self.refuse(503, "busy", "后台请求现在不接：interactive", 5, "interactive")
            background = priority != "user-waiting"
            if "cooldown" in self.modes() and background:
                left = self.server.cooldown_until - time.time()
                if left > 0:
                    return self.refuse(503, "busy", "后台请求现在不接：power_cooldown", 1, "power_cooldown",
                                       retry_after_ms=int(left * 1000))
                self.server.cooldown_until = time.time() + 0.5
            if "inputs" in body:
                return self.embed_inputs(body, inputs, kinds, media)
            if len(texts) > self.server.batch:
                return self.refuse(400, "invalid_request", f"文本数 {len(texts)} 超过批大小 {self.server.batch}")
            return self.answer(200, {"vectors": [vector(t) for t in texts], "dims": DIMS,
                                     "model": "fake-embeddinggemma-2", "vector_space": self.server.space, "ms": 1})
        if method == "POST" and self.path == "/warmup":
            return self.answer(200, {"accepted": mode != "unsupported", "lease_id": "fake", "expires_in": 120})
        if method in ("PUT", "POST") and self.path in ("/accessory/resident", "/accessory/exiting"):
            return self.answer(200, {})
        return self.refuse(404, "task_unavailable", f"no {method} {self.path}")


    def embed_inputs(self, body, inputs, kinds, media):
        """`inputs` as the multimodal draft has it: a whole request that breaks the rules is refused; a picture or a
        recording that can't be read gets a null vector and its reason, one of luoke-core's four codes (37e0aae):
        image_unreadable, audio_unreadable, audio_too_long, embed_failed."""
        if not media:
            return self.refuse(400, "invalid_request", "要 texts（非空字符串列表）")   # as a text-only hub answers
        if "texts" in body or not inputs or "?" in kinds:
            return self.refuse(400, "invalid_request", "inputs 要是非空列表，每条一个 text、image 或 audio，不和 texts 同给")
        for kind, limit in (("text", self.server.batch), ("image", MEDIA_PARAMS["image_batch"]),
                            ("audio", MEDIA_PARAMS["audio_batch"])):
            if kinds.count(kind) > limit:
                return self.refuse(400, "invalid_request", f"{kind} {kinds.count(kind)} 条，超过 {limit}")
        vectors, errors = [], []
        for item in inputs:
            key, error = self.input_key(item)
            vectors.append(None if error else vector(key))
            errors.append(error)
        if any(isinstance(e, tuple) for e in errors):   # a rule broken: the whole request
            code, message = next(e for e in errors if isinstance(e, tuple))
            return self.refuse(413 if code == "input_too_long" else 400, code, message)
        return self.answer(200, {"vectors": vectors, "errors": errors, "dims": DIMS, "model": "fake-embeddinggemma-2",
                                 "vector_space": self.server.space, "ms": 1})

    @staticmethod
    def input_key(item):
        """(what the fake vector is made from, None) or (None, the item's reason, or (code, message) for the request)."""
        if "text" in item:
            return item["text"], None
        kind = "image" if "image" in item else "audio"
        try:
            data = base64.b64decode(item[kind], validate=True)
        except (binascii.Error, TypeError, ValueError):
            return None, ("invalid_request", f"{kind} 不是 base64")
        if len(data) > MEDIA_PARAMS[f"max_{kind}_bytes"]:
            return None, ("input_too_long", f"{kind} {len(data)} 字节，超过 {MEDIA_PARAMS[f'max_{kind}_bytes']}")
        if kind == "image":
            if item.get("budget") not in BUDGETS:
                return None, ("invalid_request", f"budget 只能是 {BUDGETS}")
            if not (data.startswith(b"\x89PNG") or data.startswith(b"\xff\xd8")):
                return None, "image_unreadable"
            return b"image %d " % item["budget"] + data, None
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE" or data[22:24] != b"\x01\x00" \
                or data[24:28] != (16000).to_bytes(4, "little") or data[34:36] != b"\x10\x00":
            return None, "audio_unreadable"
        if (len(data) - 44) / 32000 > MEDIA_PARAMS["max_audio_secs"] + 0.05:
            return None, "audio_too_long"
        return b"audio " + data, None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", required=True)
    parser.add_argument("--mode-file", required=True)
    parser.add_argument("--space", default="embeddinggemma-2/1")
    parser.add_argument("--batch", type=int, default=32)
    args = parser.parse_args()
    if os.path.exists(args.socket):
        sys.exit(f"{args.socket} exists already: not taking it over")
    server = Server(args.socket, Handler)
    server.mode_file, server.space, server.batch = args.mode_file, args.space, args.batch
    server.cooldown_until = 0.0
    print(f"[fake hub] listening on {args.socket} (pid {os.getpid()})", file=sys.stderr, flush=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))   # so `finally` removes the socket on kill
    try:
        server.serve_forever()
    finally:
        os.unlink(args.socket)


if __name__ == "__main__":
    main()

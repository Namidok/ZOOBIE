"""Local neural TTS for Companion, using Kokoro (ONNX). Listens on 127.0.0.1 only.

POST /tts  {"text": "...", "voice": "bf_emma", "speed": 1.0}  ->  audio/wav
GET  /health                                                  ->  {"ok": true, "voices": [...]}

Started by the Companion app; run by hand with:
  <venv>/bin/python kokoro_server.py <model-dir> [port]
"""

import io
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import soundfile as sf
from kokoro_onnx import Kokoro

MODEL_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765

kokoro = Kokoro(str(MODEL_DIR / "kokoro-v1.0.onnx"), str(MODEL_DIR / "voices-v1.0.bin"))
VOICES = sorted(kokoro.get_voices())


def language_for(voice: str) -> str:
    # Voice ids start with a/b for American/British English.
    return "en-gb" if voice.startswith("b") else "en-us"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        self._send(200, "application/json", json.dumps({"ok": True, "voices": VOICES}).encode())

    def do_POST(self):
        if self.path != "/tts":
            self.send_error(404)
            return
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            text = str(body["text"]).strip()
            voice = body.get("voice") or "bf_emma"
            if voice not in VOICES:
                voice = "bf_emma"
            speed = float(body.get("speed") or 1.0)
            samples, rate = kokoro.create(text, voice=voice, speed=speed, lang=language_for(voice))
            buffer = io.BytesIO()
            sf.write(buffer, samples, rate, format="WAV", subtype="PCM_16")
            self._send(200, "audio/wav", buffer.getvalue())
        except Exception as error:  # report, don't crash the server
            self._send(500, "text/plain", str(error).encode())

    def _send(self, code, content_type, payload):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):  # keep stdout quiet
        pass


def exit_with_parent():
    """Quit when the app that started us goes away (we get re-parented to launchd), so a
    force-quit or crash never leaves a ~300 MB voice model running in the background."""
    parent = os.getppid()
    while True:
        time.sleep(2)
        if os.getppid() != parent:
            os._exit(0)


if __name__ == "__main__":
    threading.Thread(target=exit_with_parent, daemon=True).start()
    kokoro.create("Ready.", voice="bf_emma", speed=1.0, lang="en-gb")  # warm up the model
    print(f"kokoro ready on {PORT}", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

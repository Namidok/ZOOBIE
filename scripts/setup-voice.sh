#!/bin/zsh
# One-time setup for Companion's neural voice (Kokoro, runs fully on-device).
# Installs a Python venv and the ~340 MB model into ~/Library/Application Support/Companion/voice.
set -euo pipefail

dir="$HOME/Library/Application Support/Companion/voice"
release="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
mkdir -p "$dir"

if ! command -v uv >/dev/null; then
  echo "uv is required: brew install uv" >&2
  exit 1
fi

if [[ ! -x "$dir/venv/bin/python" ]]; then
  uv venv --python 3.12 "$dir/venv"
fi
uv pip install --python "$dir/venv/bin/python" --quiet kokoro-onnx soundfile

for file in kokoro-v1.0.onnx voices-v1.0.bin; do
  if [[ ! -s "$dir/$file" ]]; then
    echo "Downloading $file…"
    curl -fL --progress-bar -o "$dir/$file.part" "$release/$file"
    mv "$dir/$file.part" "$dir/$file"
  fi
done

echo "Voice ready in $dir — restart Companion to use it."

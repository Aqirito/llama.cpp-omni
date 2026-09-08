#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
DEMO_DIR="${COMNI_DEMO_DIR:-${1:-}}"
MODEL_DIR="${COMNI_MODEL_DIR:-$HOME/.comni/models/MiniCPM-o-4_5-gguf}"
SERVER_PATH="${COMNI_SERVER_PATH:-$REPO_ROOT/build/bin/llama-omni-server}"
PYTHON_PATH="${COMNI_PYTHON_PATH:-$(command -v python || command -v python3 || true)}"

if [ -z "$DEMO_DIR" ]; then
    echo "usage: $0 /path/to/MiniCPM-o-Demo" >&2
    echo "or set COMNI_DEMO_DIR" >&2
    exit 2
fi

if [ ! -d "$MODEL_DIR" ]; then
    echo "model directory not found: $MODEL_DIR" >&2
    exit 2
fi
if [ ! -x "$SERVER_PATH" ]; then
    echo "llama-omni-server not found: $SERVER_PATH" >&2
    exit 2
fi
if [ ! -f "$DEMO_DIR/gateway.py" ] || [ ! -f "$DEMO_DIR/worker.py" ]; then
    echo "invalid MiniCPM-o-Demo directory: $DEMO_DIR" >&2
    exit 2
fi
if [ -z "$PYTHON_PATH" ] || [ ! -x "$PYTHON_PATH" ]; then
    echo "Python executable not found" >&2
    exit 2
fi

cd "$ROOT_DIR"
COMNI_MODEL_DIR="$MODEL_DIR" \
COMNI_SERVER_PATH="$SERVER_PATH" \
COMNI_DEMO_DIR="$DEMO_DIR" \
COMNI_PYTHON_PATH="$PYTHON_PATH" \
swift run -c release ComniProbe --web-e2e

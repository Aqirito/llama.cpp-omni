# Comni 2.0

Native macOS manager for the local `llama.cpp-omni` Web experience.

The current product milestone prioritizes the complete MiniCPM-o-Demo Web UI. Comni starts
and monitors the local backend, worker, and gateway, then opens the verified browser app.
Native Chat/Live experiments remain in the source tree for later migration.

The implementation has four modules:

- `ComniDomain`: model capabilities, model bundles, and live session events.
- `ComniRuntime`: model discovery, engine supervision, backend protocol codec, and WebSocket client.
- `ComniMedia`: macOS camera and microphone authorization boundary.
- `ComniApp`: SwiftUI service manager and configuration UI.

## Requirements

- macOS 14 or newer
- Xcode 26 or newer
- Swift 6.2 or newer
- Python with the MiniCPM-o-Demo Gateway/Worker dependencies
- Node/npm only when `static/mobile` has not been built yet

## Build and test

```sh
cd apps/comni
swift test
swift build -c release
```

Build a local ad-hoc signed app bundle:

```sh
./scripts/build-app.sh
open dist/Comni.app
```

Build the inference backend from the repository root:

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target llama-omni-server -j
```

Run the automated Web regression suite:

```sh
./scripts/test-web-e2e.sh /path/to/MiniCPM-o-Demo
```

It starts and stops the complete stack, verifies Mobile assets, streaming Chat, Chat TTS,
and an Omni PCM + JPEG input, then checks that all services shut down.

## Current status

Implemented:

- MiniCPM-o model bundle discovery without modifying model directories.
- Owned `llama-omni-server`, Worker, and Gateway process supervision.
- Per-component health and lifecycle state.
- Automatic allocation and validation of four loopback ports.
- Dynamic Worker registration with the Gateway.
- Automatic `frontend/mobile` build when `static/mobile` is missing.
- Persistent local paths for model, Demo, server, and Python.
- Runtime log aggregation under `~/Library/Logs/Comni/`.
- Start, stop, open Web, and show logs actions.
- Menu bar background controls; closing the manager window keeps Comni running.
- Ordered service shutdown when quitting the app.
- Verified Gateway streaming Chat and Omni audio/JPEG input.

Next:

- Package a managed Python runtime for standalone distribution.
- Bundle the compiled Mobile assets so release users do not need Node/npm.
- Add opt-in launch-at-login behavior.
- Add model download and update management.
- Gradually migrate selected Web workflows into native views.

## Runtime packaging

Python is a runtime dependency today because `gateway.py` and `worker.py` run for every
session. A standalone Comni release should bundle a managed Python runtime and its pinned
dependencies.

npm is only a build-time dependency. Release packaging should compile `frontend/mobile`
once and include `static/mobile` in the app, so end users do not need Node or npm.

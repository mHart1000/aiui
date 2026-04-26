# AIUI - AI Chat Interface

Full-feature, local-first AI chat app interfacing with Llama.cpp with the option to connect to cloud models. Features enhanced reasoning & memory recall with offline speech-to-text.

## Features

- 💬 Real-time AI chat with various models
- 🤖 Designed for local models (llama.cpp)
- 🎤 Offline speech-to-text (Whisper)
- 🔊 Offline text-to-speech (Kokoro)
- 🧮 Offline embedding
- 🏗️ Optional scaffolding (user-toggle)
- 🎭 Optional personalization
- 🔍 Robust RAG system
- 💾 Conversation history
- 📄 Document upload
- 🔒 Privacy-focused (all inference happens locally by default, zero telemetry)
- ☁️ Option to connect to cloud models with API keys


---
## Multi-pc setup:

### To access app from another device on LAN:
- Microphone access requires HTTPS or localhost
- Use SSH tunnel: 
```bash
ssh -L 9100:localhost:9100 user@server-ip
```
- Then access via `http://localhost:9100`

### Llama.cpp tunnel setup

If you are hosting llama.cpp on a separate Windows/WSL2 machine, follow these steps to bridge the connection to the Rails app.

**1. Start the LLM Server (Remote Machine)**

On the machine with the GPU (WSL2), run the `llama.cpp` server (adjust flags as needed):

```bash
./build/bin/llama-server \
  -m "$MODEL_DIR/$MODEL_NAME" \
  --host 0.0.0.0 \
  --port 8080 \
  -ngl 99 \
  --flash-attn on \
  -c 32768 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0
```

Run a second llama.cpp instance for the embedding model required by the RAG system:

```bash
./build/bin/llama-server \
  -m "$MODEL_DIR/$MODEL_NAME" \
  --port 8090 \
  --host 0.0.0.0 \
  --embeddings \
  --pooling last \
  --ctx-size 8192 \
  --batch-size 512 \
  --ubatch-size 512 \
  -ngl 99 \
  --no-mmap
```

**2. Establish SSH Tunnel (App Machine)**

Run this on the machine hosting the Rails app to securely bridge the WSL2 port (8080) to your local environment:

```bash
ssh -f -N -L 8080:127.0.0.1:8080 WINDOWS_USER@IP
```

And this to connect to the embedder:
```bash
ssh -f -N -L 8080:127.0.0.1:8080 WINDOWS_USER@IP
```
Test the connection from the app machine:
```bash
curl http://localhost:8080/v1/models

```

**3. Environment Configuration**

Point the application to the local end of the SSH tunnel. No API key is required if the tunnel is active.

```bash
LLAMA_API_URL: http://localhost:8080/v1

```

## TTS setup:
Start Kokoro engine:
```bash
docker run -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpuLLAMA_API_URL: http://localhost:8080/v1

```

## STT setup (Whisper):

STT runs server-side via `whisper.cpp`'s persistent HTTP server (`whisper-server`). Audio is captured in the browser via `MediaRecorder` and chunked on pause (VAD), each chunk POSTed to `/api/stt/transcribe`, which forwards to `whisper-server`. Keeping the model resident in the daemon (~half-second per short chunk) is what makes the streaming-feel UX viable — shelling out to `whisper-cli` per chunk paid the model-load cost every time and was 3-5x slower.

Build whisper.cpp once, outside the repo:

```bash
sudo apt install cmake ffmpeg   # cmake to build, ffmpeg used by whisper-server's --convert
mkdir -p ~/whisper && cd ~/whisper
git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git .
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
bash ./models/download-ggml-model.sh base.en   # or small.en for slightly better accuracy
```

Start the server (keep it running alongside the Rails app):

```bash
~/whisper/build/bin/whisper-server \
  -m ~/whisper/models/ggml-base.en.bin \
  --host 127.0.0.1 --port 8878 \
  --convert --no-gpu -nt
```

Then in the app's `.env`:

```
WHISPER_SERVER_URL=http://127.0.0.1:8878
```

(Defaults to that URL if unset.)

Model choice — `base.en` (~142 MB) is the recommended default: ~0.7 s per chunk on a desktop CPU (3700X-class), which keeps the chunk-on-pause streaming UX feeling responsive. Whisper has a fixed ~30 s encoder pass that dominates per-request cost regardless of clip length, so smaller models pay off here even though their decode is already fast. `small.en` (~465 MB) bumps that fixed cost to ~2.3 s per chunk; only worth it if real-world accuracy needs the upgrade. `--no-gpu` keeps Whisper off the GPU so it doesn't fight llama.cpp for VRAM.

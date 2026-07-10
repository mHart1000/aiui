# AIUI - AI Chat Interface

Full-feature, local-first AI chat app interfacing with Llama.cpp with the option to connect to cloud models. Features enhanced reasoning & memory recall with offline speech-to-text.

## Features

- 💬 Real-time AI chat with various models
- 🤖 Designed for local models (llama.cpp)
- 🎤 Offline speech-to-text (Whisper.cpp)
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
ssh -f -N -L 8090:127.0.0.1:8090 WINDOWS_USER@IP
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
The TTS engine is selected with `TTS_ADAPTER` in `.env` (`kokoro`, `qwen3`, or `chatterbox`; default `kokoro`). Restart the backend after switching.

### Kokoro (local CPU)
Start Kokoro engine:
```bash
docker run -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu

```

### Qwen3 TTS (remote GPU, via SSH tunnel)

Served on the GPU machine (like llama.cpp) via [faster-qwen3-tts](https://github.com/andimarafioti/faster-qwen3-tts) — CUDA-graph inference that runs Qwen3-TTS faster than realtime on the 3090 (RTF ≈ 0.32; [spec](docs/faster-qwen3-tts-spec.md)). Its `openai_server.py` only *clones* voices (OpenAI `/v1/audio/speech` + `/health`, no voices endpoint), so we register one reference clip. One-time setup on the remote machine (WSL2):

```bash
sudo apt install -y sox        # for playing/inspecting wavs
git clone https://github.com/andimarafioti/faster-qwen3-tts
cd faster-qwen3-tts
python3 -m venv .venv          # python 3.10+
source .venv/bin/activate
pip install -U pip && pip install -e ".[demo]"
```

Render a reference clip from a built-in CustomVoice speaker (CLI-only — the HTTP server has no speaker mode), keeping `--text` as its transcript:

```bash
faster-qwen3-tts custom --model Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice \
  --speaker aiden \
  --text "Some clean, natural paragraph about ten seconds long when spoken aloud." \
  --output ref_aiden.wav
```

Register it in `voices.json` (the adapter sends `voice: "aiden"`, matching `QWEN3_TTS_VOICES`):

```json
{ "aiden": { "ref_audio": "ref_aiden.wav", "ref_text": "Some clean, natural paragraph about ten seconds long when spoken aloud.", "language": "English" } }
```

Start the server — 0.6B is the fast clone model; weights download and the CUDA graph captures once on first run:

```bash
source .venv/bin/activate
python examples/openai_server.py --model Qwen/Qwen3-TTS-12Hz-0.6B-Base --voices voices.json --port 8881
```

Tunnel and verify from the app machine:

```bash
ssh -f -N -L 8881:127.0.0.1:8881 WINDOWS_USER@IP
curl http://localhost:8881/health   # -> {"status":"ok","model_loaded":true}
```

Then in `.env`:
```bash
TTS_ADAPTER=qwen3
QWEN3_TTS_URL=http://localhost:8881
QWEN3_TTS_VOICES=aiden   # comma-separated; must match voices.json keys
```

**Adding custom voices** — clone any clean ~5–15s WAV (mono/24 kHz;
```bash
ffmpeg -i reference-clip.mp4 \
  -vn \
  -ac 1 \
  -ar 24000 \
  reference-clip.wav
```

1. Add an entry to `voices.json` on the GPU box: `"kerry": { "ref_audio": "kerry.wav", "ref_text": "<exact transcript of the clip>", "language": "English" }`, and restart the server.
2. Append the name to `QWEN3_TTS_VOICES` environment variable. Names must match the `voices.json` keys.


### Chatterbox (remote GPU, via SSH tunnel)

Served via [Chatterbox-TTS-Server](https://github.com/devnen/Chatterbox-TTS-Server) (OpenAI-compatible `/v1/audio/speech`). One-time setup on the remote machine (WSL2):

```bash
sudo apt install -y ffmpeg    # required for mp3 encoding
git clone https://github.com/devnen/Chatterbox-TTS-Server.git
cd Chatterbox-TTS-Server
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements-nvidia.txt
pip install --no-deps git+https://github.com/devnen/chatterbox-v2.git@master s3tokenizer==0.3.0 onnx==1.16.0
# onnx needs protobuf 4.x (skipped by --no-deps); perth needs pkg_resources (removed in setuptools 81)
pip install "protobuf>=4.25,<5" "setuptools<81"
```

Start the server (defaults to `0.0.0.0:8004`, configurable in its `config.yaml`; model downloads on first run):

```bash
python server.py
```

Bridge the port from the app machine and test:

```bash
ssh -f -N -L 8004:127.0.0.1:8004 WINDOWS_USER@IP
curl http://localhost:8004/v1/audio/voices
```

Then in `.env`:
```bash
TTS_ADAPTER=chatterbox
CHATTERBOX_TTS_URL=http://localhost:8004
```

## STT setup (Whisper):
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
  --convert --no-gpu -nt -sns
```

`-sns` (suppress non-speech tokens) 
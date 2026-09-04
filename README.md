# AIUI - AI Chat Interface

AIUI is a full-featured, local-first AI chat application. It connects to llama.cpp. You can also connect it to cloud models.

## Features

- 💬 Real-time AI chat with different models
- 🤖 Support for local models (llama.cpp)
- 🎤 Offline speech-to-text (Whisper.cpp)
- 🔊 Offline text-to-speech (Kokoro)
- 🧮 Offline embedding
- 🏗️ Optional scaffolding that the user can enable or disable
- 🎭 Optional personalization
- 🔍 RAG system
- 💾 Conversation history
- 📄 Document upload
- 🖼️ Image attachments for models that support vision
- 🔒 Privacy focus: inference is local by default and there is no telemetry
- ☁️ Connection to cloud models with API keys

---

## Multi-PC setup

### Access the application from another device on the LAN

- Microphone access requires HTTPS or localhost.
- Use an SSH tunnel:

```bash
ssh -L 9100:localhost:9100 user@server-ip
```

- Then go to `http://localhost:9100`.

### llama.cpp tunnel setup

If you host llama.cpp on a separate Windows/WSL2 machine, use this procedure to connect it to the Rails application.

**1. Start the LLM server (remote machine)**

On the GPU machine (WSL2), start the llama.cpp server. Adjust the options as necessary.

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

Start a second llama.cpp instance for the embedding model that the RAG system requires.

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

**2. Start the SSH tunnel (application machine)**

On the machine that hosts the Rails application, run this command to connect WSL2 port 8080 to your local environment:

```bash
ssh -f -N -L 8080:127.0.0.1:8080 WINDOWS_USER@IP
```

Run this command to connect the embedder:

```bash
ssh -f -N -L 8090:127.0.0.1:8090 WINDOWS_USER@IP
```

Test the connection from the application machine:

```bash
curl http://localhost:8080/v1/models
```

**3. Configure the environment**

Set the application to use the local end of the SSH tunnel. No API key is required when the tunnel is active.

```bash
LLAMA_API_URL: http://localhost:8080/v1
```

## Image attachments

Server-side image downscaling requires libvips:

```bash
sudo apt install libvips42
```

The application reads the `multimodal` capability of the active model from the llama.cpp `/v1/models` response. If this response is not available, image selection stays enabled.

---

## TTS setup

Select the TTS engine with `TTS_ADAPTER` in `.env`. The available values are `kokoro`, `qwen3`, and `chatterbox`. The default value is `kokoro`. Restart the backend after you change this value.

### Kokoro (local CPU)

Start the Kokoro engine:

```bash
docker run -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu
```

### Qwen3 TTS (remote GPU, through an SSH tunnel)

Use [faster-qwen3-tts](https://github.com/andimarafioti/faster-qwen3-tts) on the GPU machine, as with llama.cpp. It uses CUDA-graph inference and runs Qwen3-TTS faster than real time on the 3090. The measured RTF is approximately 0.42 on the live 0.6B streaming path. See the [specification](docs/faster-qwen3-tts-spec.md) and [latency tuning](docs/qwen3-latency-optimization-spec.md).

Its `openai_server.py` only clones voices. It supports OpenAI `/v1/audio/speech` and `/health`, but no voices endpoint. Register one reference clip. Do this one time on the remote machine (WSL2):

```bash
sudo apt install -y sox        # Use this to play or inspect WAV files.
git clone https://github.com/andimarafioti/faster-qwen3-tts
cd faster-qwen3-tts
python3 -m venv .venv          # Python 3.10 or later.
source .venv/bin/activate
pip install -U pip && pip install -e ".[demo]"
```

Create a reference clip from a built-in CustomVoice speaker. Use the CLI because the HTTP server has no speaker mode. Keep the `--text` value as its transcript.

```bash
faster-qwen3-tts custom --model Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice \
  --speaker aiden \
  --text "Some clean, natural paragraph about ten seconds long when spoken aloud." \
  --output ref_aiden.wav
```

Register the clip in `voices.json`. The adapter sends `voice: "aiden"`, which must match `QWEN3_TTS_VOICES`.

```json
{ "aiden": { "ref_audio": "ref_aiden.wav", "ref_text": "Some clean, natural paragraph about ten seconds long when spoken aloud.", "language": "English", "chunk_size": 4 } }
```

The `chunk_size` value for each voice sets the time to first audio. `N/12` is the number of seconds of audio for each flush. The default value, `12`, is approximately 520 ms. A value of `4` is approximately 297 ms. See [latency tuning](docs/qwen3-latency-optimization-spec.md).

Start the server. The 0.6B model is the fast clone model. The weights download and the CUDA graph captures one time during the first run:

```bash
source .venv/bin/activate
python examples/openai_server.py --model Qwen/Qwen3-TTS-12Hz-0.6B-Base --voices voices.json --port 8881
```

Start the tunnel and verify it from the application machine:

```bash
ssh -f -N -L 8881:127.0.0.1:8881 WINDOWS_USER@IP
curl http://localhost:8881/health   # -> {"status":"ok","model_loaded":true}
```

Then set these values in `.env`:

```bash
TTS_ADAPTER=qwen3
QWEN3_TTS_URL=http://localhost:8881
QWEN3_TTS_VOICES=aiden   # Comma-separated. Must match the voices.json keys.
```

**Add custom voices** — Clone a clean WAV file of approximately 5 to 15 seconds. The file must be mono and 24 kHz:

```bash
ffmpeg -i reference-clip.mp4 \
  -vn \
  -ac 1 \
  -ar 24000 \
  reference-clip.wav
```

1. Add an entry to `voices.json` on the GPU machine: `"kerry": { "ref_audio": "kerry.wav", "ref_text": "<exact transcript of the clip>", "language": "English", "chunk_size": 4 }`. Then restart the server.
2. Add the name to the `QWEN3_TTS_VOICES` environment variable. The names must match the `voices.json` keys.

### Chatterbox (remote GPU, through an SSH tunnel)

Use [Chatterbox-TTS-Server](https://github.com/devnen/Chatterbox-TTS-Server). It provides an OpenAI-compatible `/v1/audio/speech` endpoint. Do this one time on the remote machine (WSL2):

```bash
sudo apt install -y ffmpeg    # Required for MP3 encoding.
git clone https://github.com/devnen/Chatterbox-TTS-Server.git
cd Chatterbox-TTS-Server
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements-nvidia.txt
pip install --no-deps git+https://github.com/devnen/chatterbox-v2.git@master s3tokenizer==0.3.0 onnx==1.16.0
# onnx requires protobuf 4.x. The --no-deps option skips it. perth requires pkg_resources, which setuptools 81 removed.
pip install "protobuf>=4.25,<5" "setuptools<81"
```

Start the server. Its default address is `0.0.0.0:8004`. You can configure the address in `config.yaml`. The model downloads during the first run:

```bash
python server.py
```

Connect the port from the application machine and test it:

```bash
ssh -f -N -L 8004:127.0.0.1:8004 WINDOWS_USER@IP
curl http://localhost:8004/v1/audio/voices
```

Then set these values in `.env`:

```bash
TTS_ADAPTER=chatterbox
CHATTERBOX_TTS_URL=http://localhost:8004
```

## STT setup (Whisper)

Build whisper.cpp one time outside the repository:

```bash
sudo apt install cmake ffmpeg   # Use cmake to build. whisper-server uses ffmpeg with --convert.
mkdir -p ~/whisper && cd ~/whisper
git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git .
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
bash ./models/download-ggml-model.sh base.en   # Or use small.en for slightly better accuracy.
```

Start the server. Keep it running with the Rails application:

```bash
~/whisper/build/bin/whisper-server \
  -m ~/whisper/models/ggml-base.en.bin \
  --host 127.0.0.1 --port 8878 \
  --convert --no-gpu -nt -sns
```

`-sns` suppresses non-speech tokens.

# AIUI - AI Chat Interface

AI chat UI interfacing with OpenAI, Gemini, & Llamaa.cpp. Features enhanced reasoning & memory recall with offline speech-to-text.


```

### STT Setup

```bash
cd aiui-client

# Download Vosk speech recognition model
mkdir -p public/vosk-models
cd public/vosk-models
wget https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip
# Model stays as .zip - Vosk extracts it in the browser

# Start dev server (default: port 9100)
cd ../..
npm run dev
# or: quasar dev
```

**From another device on LAN:**
- Microphone access requires HTTPS or localhost
- Use SSH tunnel: `ssh -L 9100:localhost:9100 user@server-ip`
- Then access via `http://localhost:9100`

## Features

- 💬 Real-time AI chat with various models
- 🤖 Support for local models (llama.cpp)
- 🎤 Offline voice-to-text (Vosk)
- 💾 Conversation history
- 🔒 Privacy-focused (speech processing happens locally)


---

## Llama.cpp tunnel setup

If you are hosting llama.cpp on a separate Windows/WSL2 machine, follow these steps to bridge the connection to the Rails app.

### 1. Start the LLM Server (Remote Machine)

On the machine with the GPU (WSL2), run the `llama.cpp` server:

```bash
./build/bin/llama-server \
  -m "./path/to/model.gguf" \
  --host 0.0.0.0 \
  --port 8080 \
  -ngl 99 \
  -c 8192

```

### 2. Establish SSH Tunnel (App Machine)

Run this on the machine hosting the Rails app to securely bridge the WSL2 port (8080) to your local environment:

```bash
ssh -f -N -L 8080:$(ssh WINDOWS_USER@IP  "wsl hostname -I" | tr -d '[:space:]'):8080 WINDOWS_USER@IP 

```

Test the connection from the app machine:
```bash
curl http://localhost:8080/v1/models

```

### 3. Environment Configuration

Point the application to the local end of the SSH tunnel. No API key is required if the tunnel is active.

```bash
LLAMA_API_URL: http://localhost:8080/v1

```

# AIUI - AI Chat Interface

A full-stack AI chat application with offline voice-to-text support.

## Setup

### 1. Backend Setup

```bash
# Install dependencies
bundle install

# Setup database
rails db:create db:migrate

# Configure environment
cp .env.example .env
# Edit .env and add your OpenAI API key

# Start Rails server (default: port 3000)
rails server
```

### 2. Frontend Setup

```bash
cd aiui-client

# Install dependencies
npm install

# Optional: Configure environment
cp .env.example .env
# Edit .env if you want to customize default model or Vosk URL

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

### 3. Access the App

**Local development:**
- Open `http://localhost:9100`

**From another device on LAN:**
- Microphone access requires HTTPS or localhost
- Use SSH tunnel: `ssh -L 9100:localhost:9100 user@server-ip`
- Then access via `http://localhost:9100`

## Features

- 💬 Real-time AI chat with multiple AI models
- 🤖 Support for local models (llama.cpp)
- 🎤 Offline voice-to-text (Vosk)
- 💾 Conversation history
- 🔒 Privacy-focused (speech processing happens locally)

Got it. Let's strip the specific specs and keep it strictly to the "How-To" for any dev cloning the repo.

---

## Llama.cpp tunnel setup

If you are hosting the LLM on a separate Windows/WSL2 machine with a GPU, follow these steps to bridge the connection to the Rails app.

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

*Replace `<USER>` and `<REMOTE_IP>` with your Windows credentials/IP.*

### 3. Environment Configuration

Point the application to the local end of the SSH tunnel. No API key is required if the tunnel is active.

| Variable | Value |
| --- | --- |
| `LLAMA_API_URL` | `http://localhost:8080/v1` |

### 4. Verification

Test the connection from the app machine:

```bash
curl http://localhost:8080/v1/models

```

---

**Would you like me to help you wrap that one-liner into a small `bin/setup_tunnel` script for the repo?**

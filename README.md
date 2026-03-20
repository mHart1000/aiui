# AIUI - AI Chat Interface

Full-feature, local-first AI chat app interfacing with Llama.cpp with the option to connect to cloud models. Features enhanced reasoning & memory recall with offline speech-to-text.

## Features

- 💬 Real-time AI chat with various models
- 🤖 Designed for local models (llama.cpp)
-  �️ Optional scaffolding (user-toggle)
- �Offline voice-to-text (Vosk)
- 💾 Conversation history
- 🔒 Privacy-focused (when used with llama.cpp, all inference happens locally, with zero telemetry)
- ☁️ Use of cloud models is optional


---
## Multi-pc setup:

### To access app from another device on LAN:
- Microphone access requires HTTPS or localhost
- Use SSH tunnel: `ssh -L 9100:localhost:9100 user@server-ip`
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

**2. Establish SSH Tunnel (App Machine)**

Run this on the machine hosting the Rails app to securely bridge the WSL2 port (8080) to your local environment:

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

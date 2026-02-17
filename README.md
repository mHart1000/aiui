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

<template>
  <div class="voice-chat-input">
    <div class="input-wrapper">
      <q-input
        ref="inputField"
        filled
        autogrow
        :model-value="modelValue"
        @update:model-value="handleInput"
        @keydown.enter.exact.prevent="handleSend"
        placeholder="Listening…"
        type="textarea"
        :input-style="inputStyle"
      />

      <div class="button-overlay" :class="{ 'overlay-centered': !expanded }">
        <div class="left-buttons">
          <q-btn
            v-if="showNewChat"
            icon="add"
            color="secondary"
            round
            flat
            @click="$emit('new-chat')"
          >
            <q-tooltip>New chat</q-tooltip>
          </q-btn>
          <div class="status-text text-caption text-grey-7">{{ statusText }}</div>
        </div>

        <div class="right-buttons">
          <q-btn
            round
            flat
            :icon="micIcon"
            :color="isRecording ? 'negative' : 'primary'"
            :loading="showSpinner"
            :disable="isLoading || showSpinner"
            @click="toggleMic"
          >
            <q-tooltip>{{ micTooltip }}</q-tooltip>
          </q-btn>

          <q-btn
            :icon="isStreaming ? 'stop' : 'send'"
            :color="isStreaming ? 'negative' : 'primary'"
            round
            flat
            @click="handleSend"
          >
            <q-tooltip>{{ sendTooltip }}</q-tooltip>
          </q-btn>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import { api } from 'boot/axios'

const PREFERRED_MIME_TYPES = [
  'audio/webm;codecs=opus',
  'audio/webm',
  'audio/ogg;codecs=opus',
  'audio/ogg',
  'audio/mp4'
]

function pickMimeType () {
  if (typeof MediaRecorder === 'undefined') return null
  for (const type of PREFERRED_MIME_TYPES) {
    if (MediaRecorder.isTypeSupported(type)) return type
  }
  return null
}

function extForMimeType (mime) {
  if (!mime) return '.bin'
  if (mime.includes('webm')) return '.webm'
  if (mime.includes('ogg')) return '.ogg'
  if (mime.includes('mp4')) return '.mp4'
  return '.bin'
}

export default {
  name: 'VoiceChatInput',

  props: {
    modelValue: {
      type: String,
      required: true
    },
    isStreaming: {
      type: Boolean,
      default: false
    },
    expanded: {
      type: Boolean,
      default: true
    },
    showNewChat: {
      type: Boolean,
      default: false
    },
    endOfUtteranceMs: {
      type: Number,
      default: 2500
    },
    silenceRmsThreshold: {
      type: Number,
      default: 0.01
    },
    chunkSilenceMs: {
      type: Number,
      default: 300
    },
    minChunkSpeechMs: {
      type: Number,
      default: 250
    },
    inactivityTimeoutMs: {
      type: Number,
      default: 15000
    }
  },
  emits: ['update:modelValue', 'error', 'status', 'send-message', 'new-chat', 'stop'],
  data () {
    return {
      isLoading: false,
      isRecording: false,
      isTranscribing: false,

      mediaStream: null,
      mediaRecorder: null,
      recordedMimeType: null,

      audioContext: null,
      analyserNode: null,
      sourceNode: null,
      silenceIntervalId: null,
      inactivityTimer: null,

      // Per-chunk speech tracking (reset on every chunk boundary)
      lastSpeechAt: 0,
      speechOnsetAt: 0,
      hasSpeechInCurrentChunk: false,

      // Per-turn speech tracking (persists across chunk boundaries; reset on
      // startRecording). Used by the end-of-utterance auto-submit check.
      hasSpokenThisTurn: false,
      lastSpeechAtTurn: 0,
      autoSubmitFired: false,

      transcribePipeline: Promise.resolve(),
      pendingTranscriptions: 0
    }
  },
  computed: {
    micIcon () {
      return this.isRecording ? 'stop' : 'mic'
    },
    sendTooltip () {
      return this.isStreaming ? 'Stop generating' : 'Send message'
    },
    inputStyle () {
      return this.expanded
        ? { minHeight: '120px', paddingBottom: '45px' }
        : { minHeight: '0', paddingLeft: '52px', paddingRight: '100px' }
    },
    showSpinner () {
      return this.isTranscribing && !this.isRecording
    },
    micTooltip () {
      if (this.isRecording) return 'Pause listening'
      if (this.showSpinner) return 'Transcribing…'
      if (this.isLoading) return 'Initializing…'
      return 'Resume listening'
    },
    statusText () {
      if (this.isLoading) return 'Initializing…'
      if (this.isRecording) {
        return this.pendingTranscriptions > 0 ? 'Listening (transcribing…)' : 'Listening…'
      }
      if (this.isTranscribing) return 'Transcribing…'
      return 'Mic off'
    }
  },
  watch: {
    expanded () {
      this.$nextTick(() => {
        const el = this.$refs.inputField?.getNativeElement?.()
        if (!el) return
        // autogrow caches a fixed height; re-measure so the new min-height applies
        el.style.height = '1px'
        el.style.height = el.scrollHeight + 'px'
      })
    }
  },
  beforeUnmount () {
    this.teardownCapture()
  },
  methods: {
    handleSend () {
      if (this.isStreaming) {
        this.$emit('stop')
        return
      }
      if (this.isRecording) {
        // Manual send while listening: stop the mic, then submit after the
        // pipeline drains. Reuse the auto-submit path so behavior is uniform.
        this.tryAutoSubmit({ requireText: false })
        return
      }
      this.$emit('send-message')
    },

    handleInput (value) {
      this.$emit('update:modelValue', value)
    },

    async toggleMic () {
      if (this.isRecording) {
        this.stopRecording()
      } else {
        try {
          await this.startRecording()
        } catch (e) {
          this.$emit('error', e)
        }
      }
      this.$nextTick(() => {
        this.$refs.inputField?.focus()
      })
    },

    async startRecording () {
      if (this.isLoading || this.isRecording || this.isTranscribing) return

      this.isLoading = true
      this.$emit('status', { state: 'requesting_mic' })

      try {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
          throw new Error('Microphone access not available. Please use HTTPS or localhost.')
        }

        const mimeType = pickMimeType()
        if (!mimeType) {
          throw new Error('MediaRecorder is not supported in this browser.')
        }

        this.mediaStream = await navigator.mediaDevices.getUserMedia({
          audio: {
            echoCancellation: true,
            noiseSuppression: true,
            channelCount: 1
          }
        })

        this.recordedMimeType = mimeType
        this.transcribePipeline = Promise.resolve()
        this.pendingTranscriptions = 0

        // Reset per-turn state so each fresh recording session starts clean.
        this.hasSpokenThisTurn = false
        this.lastSpeechAtTurn = 0
        this.autoSubmitFired = false

        this.startChunk()
        this.setupSilenceDetection()

        this.isRecording = true
        this.startInactivityTimer()
        this.$emit('status', { state: 'recording' })
      } catch (e) {
        this.teardownCapture()
        throw e
      } finally {
        this.isLoading = false
      }
    },

    startChunk () {
      this.hasSpeechInCurrentChunk = false
      this.speechOnsetAt = 0
      this.lastSpeechAt = 0

      const chunks = []
      const recorder = new MediaRecorder(this.mediaStream, { mimeType: this.recordedMimeType })
      recorder.addEventListener('dataavailable', (event) => {
        if (event.data && event.data.size > 0) chunks.push(event.data)
      })
      recorder._aiuiChunks = chunks
      recorder.start()
      this.mediaRecorder = recorder
    },

    boundary () {
      const recorder = this.mediaRecorder
      const chunks = recorder._aiuiChunks
      const mime = this.recordedMimeType
      const speechMs = this.lastSpeechAt - this.speechOnsetAt
      const hadSpeech = this.hasSpeechInCurrentChunk && speechMs >= this.minChunkSpeechMs

      this.mediaRecorder = null

      recorder.addEventListener('stop', () => {
        if (hadSpeech && chunks.length) {
          const blob = new Blob(chunks, { type: mime })
          this.queueTranscription(blob, mime)
        }
      }, { once: true })

      try { recorder.stop() } catch { /* ignore */ }

      if (this.isRecording && this.mediaStream) {
        this.startChunk()
      }
    },

    queueTranscription (blob, mime) {
      this.pendingTranscriptions += 1
      this.isTranscribing = true

      this.transcribePipeline = this.transcribePipeline
        .then(() => this.postTranscribe(blob, mime))
        .then((text) => {
          if (text) this.insertAtCursor(text)
        })
        .catch((err) => {
          this.$emit('error', err)
        })
        .finally(() => {
          this.pendingTranscriptions = Math.max(0, this.pendingTranscriptions - 1)
          if (this.pendingTranscriptions === 0) this.isTranscribing = false
        })
    },

    async postTranscribe (blob, mime) {
      const form = new FormData()
      form.append('audio', blob, `recording${extForMimeType(mime)}`)

      const response = await api.post('/api/stt/transcribe', form, {
        headers: { 'Content-Type': 'multipart/form-data' }
      })

      const raw = (response.data && response.data.text) || ''
      const cleaned = raw
        .replace(/\([^)]*\)/g, '')
        .replace(/\[[^\]]*\]/g, '')
        .replace(/\*[^*]*\*/g, '')
        .replace(/\s+/g, ' ')
        .trim()
      return cleaned
    },

    stopRecording () {
      if (!this.isRecording) return
      this.isRecording = false
      this.$emit('status', { state: 'stopped' })

      this.clearInactivityTimer()
      this.stopSilenceDetection()

      const recorder = this.mediaRecorder
      const chunks = recorder ? recorder._aiuiChunks : null
      const mime = this.recordedMimeType
      const hadSpeech = this.hasSpeechInCurrentChunk &&
        (this.lastSpeechAt - this.speechOnsetAt) >= this.minChunkSpeechMs

      this.mediaRecorder = null

      if (recorder) {
        recorder.addEventListener('stop', () => {
          if (hadSpeech && chunks && chunks.length) {
            const blob = new Blob(chunks, { type: mime })
            this.queueTranscription(blob, mime)
          }
        }, { once: true })
        try {
          if (recorder.state !== 'inactive') recorder.stop()
        } catch { /* ignore */ }
      }

      this.transcribePipeline.finally(() => {
        if (this.mediaStream) {
          try { this.mediaStream.getTracks().forEach(t => t.stop()) } catch { /* ignore */ }
          this.mediaStream = null
        }
      })
    },

    tryAutoSubmit (options = {}) {
      // requireText defaults to true (the VAD-driven path). The manual-send
      // path passes false because the user explicitly chose to submit.
      const { requireText = true } = options

      if (!this.isRecording || this.autoSubmitFired) return
      this.autoSubmitFired = true

      this.isRecording = false
      this.$emit('status', { state: 'auto-submitting' })
      this.clearInactivityTimer()
      this.stopSilenceDetection()

      const recorder = this.mediaRecorder
      const chunks = recorder ? recorder._aiuiChunks : null
      const mime = this.recordedMimeType
      const hadSpeech = this.hasSpeechInCurrentChunk &&
        (this.lastSpeechAt - this.speechOnsetAt) >= this.minChunkSpeechMs

      this.mediaRecorder = null

      // Attach mic-release and send-emit AFTER the final chunk has been queued
      // onto transcribePipeline (which happens inside the recorder's 'stop'
      // event handler below).
      const finalize = () => {
        this.transcribePipeline.finally(() => {
          if (this.mediaStream) {
            try { this.mediaStream.getTracks().forEach(t => t.stop()) } catch { /* ignore */ }
            this.mediaStream = null
          }
          const text = (this.modelValue || '').trim()
          if (text || !requireText) {
            this.$emit('send-message')
          }
        })
      }

      if (recorder) {
        recorder.addEventListener('stop', () => {
          if (hadSpeech && chunks && chunks.length) {
            const blob = new Blob(chunks, { type: mime })
            this.queueTranscription(blob, mime)
          }
          finalize()
        }, { once: true })
        try {
          if (recorder.state !== 'inactive') recorder.stop()
          else finalize()
        } catch {
          finalize()
        }
      } else {
        finalize()
      }
    },

    insertAtCursor (text) {
      const current = this.modelValue || ''
      const inputEl = this.$refs.inputField?.getNativeElement?.()

      const start = typeof inputEl?.selectionStart === 'number' ? inputEl.selectionStart : current.length
      const end = typeof inputEl?.selectionEnd === 'number' ? inputEl.selectionEnd : current.length

      const before = current.slice(0, start)
      const after = current.slice(end)

      let insert = text
      const needsLeadingSpace = before && !before.endsWith(' ') && !insert.startsWith(' ')
      const needsTrailingSpace = after && !after.startsWith(' ') && !insert.endsWith(' ')
      if (needsLeadingSpace) insert = ' ' + insert
      if (needsTrailingSpace) insert = insert + ' '

      const merged = before + insert + after
      this.$emit('update:modelValue', merged)

      if (inputEl && inputEl.setSelectionRange) {
        const cursorPos = start + insert.length
        this.$nextTick(() => {
          inputEl.setSelectionRange(cursorPos, cursorPos)
          inputEl.focus()
        })
      }
    },

    async setupSilenceDetection () {
      if (!this.mediaStream) return
      try {
        this.audioContext = new (window.AudioContext || window.webkitAudioContext)()
        if (this.audioContext.state === 'suspended') {
          await this.audioContext.resume()
        }
        this.sourceNode = this.audioContext.createMediaStreamSource(this.mediaStream)
        this.analyserNode = this.audioContext.createAnalyser()
        this.analyserNode.fftSize = 2048
        this.sourceNode.connect(this.analyserNode)

        const buffer = new Float32Array(this.analyserNode.fftSize)
        const tick = () => {
          if (!this.isRecording || !this.analyserNode) return
          this.analyserNode.getFloatTimeDomainData(buffer)
          let sumSquares = 0
          for (let i = 0; i < buffer.length; i++) sumSquares += buffer[i] * buffer[i]
          const rms = Math.sqrt(sumSquares / buffer.length)
          const now = performance.now()

          if (rms > this.silenceRmsThreshold) {
            if (!this.hasSpeechInCurrentChunk) {
              this.hasSpeechInCurrentChunk = true
              this.speechOnsetAt = now
            }
            this.lastSpeechAt = now
            this.hasSpokenThisTurn = true
            this.lastSpeechAtTurn = now
            this.startInactivityTimer()
            return
          }

          // Existing chunk-on-pause boundary for incremental transcription.
          if (
            this.hasSpeechInCurrentChunk &&
            this.lastSpeechAt &&
            (now - this.lastSpeechAt) >= this.chunkSilenceMs &&
            (this.lastSpeechAt - this.speechOnsetAt) >= this.minChunkSpeechMs &&
            this.mediaRecorder && this.mediaRecorder.state === 'recording'
          ) {
            this.boundary()
          }

          // End-of-utterance auto-submit: fires once per turn when the user
          // has spoken at some point this turn AND has been silent long enough
          // AND no transcriptions are pending AND we have content to submit.
          if (
            !this.autoSubmitFired &&
            this.hasSpokenThisTurn &&
            this.lastSpeechAtTurn &&
            (now - this.lastSpeechAtTurn) >= this.endOfUtteranceMs &&
            this.pendingTranscriptions === 0 &&
            (this.modelValue || '').trim() !== ''
          ) {
            this.tryAutoSubmit()
          }
        }
        // setInterval rather than rAF — rAF is throttled when there's no
        // visible rendering activity (silent user), which would defer
        // boundary/auto-submit detection until they move or speak.
        this.silenceIntervalId = setInterval(tick, 100)
      } catch (e) {
        console.warn('Silence detection setup failed:', e)
      }
    },

    stopSilenceDetection () {
      if (this.silenceIntervalId) {
        clearInterval(this.silenceIntervalId)
        this.silenceIntervalId = null
      }
      try { if (this.sourceNode) this.sourceNode.disconnect() } catch { /* ignore */ }
      try { if (this.analyserNode) this.analyserNode.disconnect() } catch { /* ignore */ }
      try { if (this.audioContext) this.audioContext.close() } catch { /* ignore */ }
      this.sourceNode = null
      this.analyserNode = null
      this.audioContext = null
    },

    teardownCapture () {
      this.clearInactivityTimer()
      this.stopSilenceDetection()

      try {
        if (this.mediaRecorder && this.mediaRecorder.state !== 'inactive') {
          this.mediaRecorder.stop()
        }
      } catch { /* ignore */ }

      try {
        if (this.mediaStream) this.mediaStream.getTracks().forEach(t => t.stop())
      } catch { /* ignore */ }

      this.mediaRecorder = null
      this.mediaStream = null
    },

    startInactivityTimer () {
      this.clearInactivityTimer()
      // 0 (or less) means the timeout is disabled — the mic stays on until the
      // user pauses long enough to auto-submit, or stops it manually.
      if (!this.inactivityTimeoutMs || this.inactivityTimeoutMs <= 0) return
      this.inactivityTimer = setTimeout(() => {
        if (this.isRecording) this.stopRecording()
      }, this.inactivityTimeoutMs)
    },

    clearInactivityTimer () {
      if (this.inactivityTimer) {
        clearTimeout(this.inactivityTimer)
        this.inactivityTimer = null
      }
    }
  }
}
</script>

<style scoped>
.input-wrapper {
  position: relative;
  margin-bottom: 16px;
}

.button-overlay {
  position: absolute;
  bottom: 8px;
  left: 12px;
  right: 12px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  pointer-events: none;
}

.button-overlay.overlay-centered {
  top: 0;
  bottom: 0;
}

.left-buttons,
.right-buttons {
  display: flex;
  gap: 4px;
  align-items: center;
  pointer-events: auto;
}

.status-text {
  margin-left: 4px;
  opacity: 0.75;
  font-style: italic;
}
</style>

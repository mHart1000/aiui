<template>
  <div class="stt-input">
    <div class="input-wrapper">
      <q-input
        ref="inputField"
        filled
        autogrow
        :model-value="modelValue"
        @update:model-value="handleInput"
        @keydown.enter.exact.prevent="handleSend"
        placeholder="Send a message..."
        type="textarea"
        :input-style="{ minHeight: '120px', paddingBottom: '45px' }"
      />

      <div class="button-overlay">
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
        </div>

        <div class="right-buttons">
          <q-btn
            round
            flat
            :icon="micIcon"
            :color="isRecording ? 'negative' : 'primary'"
            :loading="showSpinner"
            :disable="isLoading || showSpinner"
            @click="toggle"
          >
            <q-tooltip>{{ micTooltip }}</q-tooltip>
          </q-btn>

          <q-btn
            icon="send"
            color="primary"
            round
            flat
            @click="handleSend"
          >
            <q-tooltip>Send message</q-tooltip>
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
  name: 'SpeechToTextInput',

  props: {
    modelValue: {
      type: String,
      required: true
    },
    showNewChat: {
      type: Boolean,
      default: false
    },
    inactivityTimeoutMs: {
      type: Number,
      default: 15000
    },
    silenceRmsThreshold: {
      type: Number,
      default: 0.01
    },
    chunkSilenceMs: {
      type: Number,
      default: 1000
    },
    minChunkSpeechMs: {
      type: Number,
      default: 250
    }
  },
  emits: ['update:modelValue', 'error', 'status', 'send-message', 'new-chat'],
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

      lastSpeechAt: 0,
      speechOnsetAt: 0,
      hasSpeechInCurrentChunk: false,
      transcribePipeline: Promise.resolve(),
      pendingTranscriptions: 0
    }
  },
  computed: {
    micIcon () {
      return this.isRecording ? 'stop' : 'mic'
    },
    showSpinner () {
      return this.isTranscribing && !this.isRecording
    },
    micTooltip () {
      if (this.isRecording) return 'Stop recording'
      if (this.showSpinner) return 'Transcribing…'
      if (this.isLoading) return 'Initializing…'
      return 'Start recording'
    }
  },
  beforeUnmount () {
    this.teardownCapture()
  },
  methods: {
    handleSend () {
      if (this.isRecording) {
        // Trigger stop+transcribe, then let the user send after the text lands
        this.stopRecording()
        return
      }
      this.$emit('send-message')
    },

    handleInput (value) {
      this.$emit('update:modelValue', value)
    },

    async toggle () {
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

        this.startChunk()
        this.setupSilenceDetection()
        this.startInactivityTimer()

        this.isRecording = true
        this.playBeep('start')
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

      const text = ((response.data && response.data.text) || '').trim()
      return text
    },

    stopRecording () {
      if (!this.isRecording) return
      this.isRecording = false
      this.playBeep('stop')
      this.$emit('status', { state: 'stopped' })

      if (this.inactivityTimer) {
        clearTimeout(this.inactivityTimer)
        this.inactivityTimer = null
      }
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

      // Release the mic stream once all pending transcriptions settle
      this.transcribePipeline.finally(() => {
        if (this.mediaStream) {
          try { this.mediaStream.getTracks().forEach(t => t.stop()) } catch { /* ignore */ }
          this.mediaStream = null
        }
      })
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
            this.startInactivityTimer()
          } else if (
            this.hasSpeechInCurrentChunk &&
            this.lastSpeechAt &&
            (now - this.lastSpeechAt) >= this.chunkSilenceMs &&
            (this.lastSpeechAt - this.speechOnsetAt) >= this.minChunkSpeechMs &&
            this.mediaRecorder && this.mediaRecorder.state === 'recording'
          ) {
            this.boundary()
          }
        }
        // setInterval rather than rAF — rAF is throttled when there's no
        // visible rendering activity (e.g. user sitting silent), which would
        // defer boundary detection until they move/speak again.
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

      if (this.inactivityTimer) {
        clearTimeout(this.inactivityTimer)
        this.inactivityTimer = null
      }
    },

    startInactivityTimer () {
      if (this.inactivityTimer) clearTimeout(this.inactivityTimer)
      this.inactivityTimer = setTimeout(() => {
        if (this.isRecording) this.stopRecording()
      }, this.inactivityTimeoutMs)
    },

    playBeep (mode = 'start') {
      try {
        const audioCtx = new (window.AudioContext || window.webkitAudioContext)()
        const now = audioCtx.currentTime

        const osc1 = audioCtx.createOscillator()
        const osc2 = audioCtx.createOscillator()
        const gainNode = audioCtx.createGain()
        const filter = audioCtx.createBiquadFilter()
        filter.type = 'lowpass'
        filter.Q.value = 6

        osc1.connect(gainNode)
        osc2.connect(gainNode)
        gainNode.connect(filter)
        filter.connect(audioCtx.destination)

        osc1.type = 'triangle'
        osc2.type = 'triangle'
        osc2.detune.value = 18

        if (mode === 'start') {
          osc1.frequency.setValueAtTime(100, now)
          osc1.frequency.linearRampToValueAtTime(150, now + 0.08)
          osc2.frequency.setValueAtTime(130, now)
          osc2.frequency.linearRampToValueAtTime(200, now + 0.08)
          filter.frequency.setValueAtTime(250, now)
          filter.frequency.linearRampToValueAtTime(1050, now + 0.08)
        } else {
          osc1.frequency.setValueAtTime(150, now)
          osc1.frequency.linearRampToValueAtTime(90, now + 0.2)
          osc2.frequency.setValueAtTime(200, now)
          osc2.frequency.linearRampToValueAtTime(130, now + 0.2)
          filter.frequency.setValueAtTime(1050, now)
          filter.frequency.linearRampToValueAtTime(190, now + 0.2)
        }

        gainNode.gain.setValueAtTime(0, now)
        gainNode.gain.linearRampToValueAtTime(0.19, now + 0.04)
        gainNode.gain.linearRampToValueAtTime(0.11, now + 0.16)
        gainNode.gain.exponentialRampToValueAtTime(0.01, now + (mode === 'start' ? 0.22 : 0.28))

        const duration = mode === 'start' ? 0.22 : 0.28
        osc1.start(now); osc1.stop(now + duration)
        osc2.start(now); osc2.stop(now + duration)

        setTimeout(() => audioCtx.close(), duration * 1000 + 100)
      } catch (e) {
        console.warn('Could not play beep:', e)
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

.left-buttons,
.right-buttons {
  display: flex;
  gap: 4px;
  pointer-events: auto;
}
</style>

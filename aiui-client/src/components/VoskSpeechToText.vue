<template>
  <div class="stt-input">
    <div class="input-wrapper">
      <q-input
        ref="inputField"
        filled
        autogrow
        :model-value="modelValue"
        @update:model-value="$emit('update:modelValue', $event)"
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
            :icon="isRecording ? 'stop' : 'mic'"
            :color="isRecording ? 'negative' : 'primary'"
            :loading="isLoading"
            @click="toggle"
            :disable="isLoading"
          >
            <q-tooltip>
              {{ isRecording ? 'Stop recording' : isLoading ? 'Initializing...' : 'Start recording' }}
            </q-tooltip>
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

      <div v-if="partialText" class="partial-text">
        {{ partialText }}
      </div>
    </div>
  </div>
</template>

<script>
import * as Vosk from 'vosk-browser'

export default {
  name: 'VoskSpeechToText',

  props: {
    modelValue: {
      type: String,
      required: true
    },
    modelUrl: {
      type: String,
      required: true
    },
    sampleRate: {
      type: Number,
      default: 16000
    },
    showNewChat: {
      type: Boolean,
      default: false
    }
  },
  emits: ['update:modelValue', 'error', 'status', 'send-message', 'new-chat'],
  data () {
    return {
      isLoading: false,
      isRecording: false,
      partialText: '',

      model: null,
      recognizer: null,
      mediaStream: null,
      audioContext: null,
      sourceNode: null,

      workletNode: null,
      silenceGainNode: null,
      workletReady: false,

      baseTextAtStart: '',
      inactivityTimer: null,
      INACTIVITY_TIMEOUT: 15000 // 15 seconds
    }
  },
  mounted () {
    // Preload vosk model in background
    this.ensureModel().catch(err => {
      console.warn('Failed to preload Vosk model:', err)
    })
  },
  beforeUnmount () {
    this.stop()
  },
  methods: {
    handleSend () {
      if (this.isRecording) {
        this.stop()
      }
      this.$emit('send-message')
    },

    async toggle () {
      if (this.isRecording) {
        this.stop()
      } else {
        try {
          await this.start()
        } catch (e) {
          this.$emit('error', e)
        }
      }

      // Refocus input so enter works
      this.$nextTick(() => {
        this.$refs.inputField?.focus()
      })
    },

    async start () {
      if (this.isLoading || this.isRecording) return

      this.isLoading = true
      this.partialText = ''
      this.baseTextAtStart = this.modelValue || ''
      this.$emit('status', { state: 'loading_model' })

      try {
        // Check for microphone support
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
          throw new Error('Microphone access not available. Please use HTTPS or localhost.')
        }

        await this.ensureModel()
        this.setupRecognizer()

        this.$emit('status', { state: 'requesting_mic' })
        this.mediaStream = await navigator.mediaDevices.getUserMedia({
          video: false,
          audio: {
            echoCancellation: true,
            noiseSuppression: true,
            channelCount: 1,
            sampleRate: this.sampleRate
          }
        })

        this.$emit('status', { state: 'starting_audio' })
        this.audioContext = new AudioContext({ sampleRate: this.sampleRate })
        this.sourceNode = this.audioContext.createMediaStreamSource(this.mediaStream)

        await this.ensureWorklet()

        this.workletNode = new AudioWorkletNode(this.audioContext, 'vosk-audio-worklet', {
          numberOfInputs: 1,
          numberOfOutputs: 1,
          channelCount: 1
        })

        this.workletNode.port.onmessage = (event) => {
          if (!this.recognizer) return

          const chunk = event.data
          if (!chunk || !chunk.length) return

          try {
            const audioBuffer = this.audioContext.createBuffer(1, chunk.length, this.audioContext.sampleRate)
            audioBuffer.copyToChannel(chunk, 0)
            this.recognizer.acceptWaveform(audioBuffer)
          } catch (e) {
            this.$emit('error', e)
            this.stop()
          }
        }

        this.silenceGainNode = this.audioContext.createGain()
        this.silenceGainNode.gain.value = 0

        this.sourceNode.connect(this.workletNode)
        this.workletNode.connect(this.silenceGainNode)
        this.silenceGainNode.connect(this.audioContext.destination)

        this.isRecording = true
        this.startInactivityTimer()
        this.playBeep('start') // Start beep
        this.$emit('status', { state: 'recording' })
      } catch (e) {
        this.stop()
        this.$emit('error', e)
      } finally {
        this.isLoading = false
      }
    },

    stop () {
      this.isLoading = false
      this.isRecording = false
      this.partialText = ''
      this.$emit('status', { state: 'stopped' })

      try {
        if (this.workletNode) {
          this.workletNode.port.onmessage = null
          this.workletNode.disconnect()
        }
      } catch {
        // Ignore disconnection errors
      }

      try {
        if (this.sourceNode) this.sourceNode.disconnect()
      } catch {
        // Ignore disconnection errors
      }

      try {
        if (this.silenceGainNode) this.silenceGainNode.disconnect()
      } catch {
        // Ignore disconnection errors
      }

      try {
        if (this.audioContext) this.audioContext.close()
      } catch {
        // Ignore close errors
      }

      try {
        if (this.mediaStream) {
          this.mediaStream.getTracks().forEach(t => t.stop())
        }
      } catch {
        // Ignore stop errors
      }

      this.workletNode = null
      this.silenceGainNode = null
      this.sourceNode = null
      this.audioContext = null
      this.mediaStream = null
      this.recognizer = null
      this.workletReady = false

      if (this.inactivityTimer) {
        clearTimeout(this.inactivityTimer)
        this.inactivityTimer = null
      }
    },

    startInactivityTimer () {
      if (this.inactivityTimer) {
        clearTimeout(this.inactivityTimer)
      }
      this.inactivityTimer = setTimeout(() => {
        if (this.isRecording) {
          this.playBeep('stop')
          this.stop()
        }
      }, this.INACTIVITY_TIMEOUT)
    },

    playBeep (mode = 'start') {
      try {
        const audioCtx = new (window.AudioContext || window.webkitAudioContext)()
        const now = audioCtx.currentTime

        // Oscillators for warmth and movement
        const osc1 = audioCtx.createOscillator()
        const osc2 = audioCtx.createOscillator()
        const gainNode = audioCtx.createGain()
        const filter = audioCtx.createBiquadFilter()
        filter.type = 'lowpass'
        filter.Q.value = 6 // More resonance for hum

        // Connect: osc -> gain -> filter -> output
        osc1.connect(gainNode)
        osc2.connect(gainNode)
        gainNode.connect(filter)
        filter.connect(audioCtx.destination)

        // Waveform for warmth
        osc1.type = 'triangle'
        osc2.type = 'triangle'
        osc2.detune.value = 18 // Slight detune for hum/chorus

        // Slightly higher, humming pitch and filter sweep
        if (mode === 'start') {
          // Powering on: rising pitch, opening filter
          osc1.frequency.setValueAtTime(100, now)
          osc1.frequency.linearRampToValueAtTime(150, now + 0.08)
          osc2.frequency.setValueAtTime(130, now)
          osc2.frequency.linearRampToValueAtTime(200, now + 0.08)
          filter.frequency.setValueAtTime(250, now)
          filter.frequency.linearRampToValueAtTime(1050, now + 0.08)
        } else {
          // Powering off: falling pitch, closing filter
          osc1.frequency.setValueAtTime(150, now)
          osc1.frequency.linearRampToValueAtTime(90, now + 0.2)
          osc2.frequency.setValueAtTime(200, now)
          osc2.frequency.linearRampToValueAtTime(130, now + 0.2)
          filter.frequency.setValueAtTime(1050, now)
          filter.frequency.linearRampToValueAtTime(190, now + 0.2)
        }

        // Envelope for smoothness
        gainNode.gain.setValueAtTime(0, now)
        gainNode.gain.linearRampToValueAtTime(0.19, now + 0.04) // Attack
        gainNode.gain.linearRampToValueAtTime(0.11, now + 0.16) // Sustain
        gainNode.gain.exponentialRampToValueAtTime(0.01, now + (mode === 'start' ? 0.22 : 0.28)) // Release

        const duration = mode === 'start' ? 0.22 : 0.28
        osc1.start(now)
        osc1.stop(now + duration)
        osc2.start(now)
        osc2.stop(now + duration)

        setTimeout(() => audioCtx.close(), duration * 1000 + 100)
      } catch (e) {
        console.warn('Could not play beep:', e)
      }
    },

    async ensureWorklet () {
      if (this.workletReady) return
      if (!this.audioContext) throw new Error('AudioContext not initialized')

      await this.audioContext.audioWorklet.addModule('/vosk-audio-worklet.js')
      this.workletReady = true
    },

    async ensureModel () {
      if (this.model) return
      this.$emit('status', { state: 'downloading_model', url: this.modelUrl })
      this.model = await Vosk.createModel(this.modelUrl)
    },

    setupRecognizer () {
      if (!this.model) throw new Error('Vosk model not loaded')

      const recognizer = new this.model.KaldiRecognizer(this.sampleRate)

      recognizer.on('partialresult', (message) => {
        const partial = message && message.result && message.result.partial
        this.partialText = partial || ''

        // Reset inactivity timer on speech detection
        if (partial && this.isRecording) {
          this.startInactivityTimer()
        }
      })

      recognizer.on('result', (message) => {
        const text = message && message.result && message.result.text
        if (!text) return

        const current = (this.modelValue || '').trim()
        const merged = (current + ' ' + text).replace(/\s+/g, ' ').trim()
        this.partialText = ''
        this.$emit('update:modelValue', merged)

        // Reset inactivity timer on speech detection
        if (this.isRecording) {
          this.startInactivityTimer()
        }
      })

      this.recognizer = recognizer
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

.partial-text {
  margin-top: 8px;
  opacity: 0.8;
  font-style: italic;
  font-size: 0.9em;
}
</style>

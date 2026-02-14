<template>
  <div class="stt-input">
    <q-input
      filled
      autogrow
      :model-value="modelValue"
      @update:model-value="$emit('update:modelValue', $event)"
      placeholder="Send a message..."
      type="textarea"
      :input-style="{ minHeight: '90px' }"
    />

    <div class="controls">
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

      <span v-if="partialText" class="partial">
        {{ partialText }}
      </span>
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
    }
  },
  emits: ['update:modelValue', 'error', 'status'],
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

      baseTextAtStart: ''
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
    async toggle () {
      if (this.isRecording) {
        this.stop()
        return
      }

      try {
        await this.start()
      } catch (e) {
        this.$emit('error', e)
      }
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

        const next = (this.baseTextAtStart + ' ' + (this.partialText || '')).replace(/\s+/g, ' ').trim()
        this.$emit('update:modelValue', next)
      })

      recognizer.on('result', (message) => {
        const text = message && message.result && message.result.text
        if (!text) return

        const merged = (this.baseTextAtStart + ' ' + text).replace(/\s+/g, ' ').trim()
        this.baseTextAtStart = merged
        this.partialText = ''
        this.$emit('update:modelValue', merged)
      })

      this.recognizer = recognizer
    }
  }
}
</script>

<style scoped>
.controls {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 8px;
}
.partial {
  opacity: 0.8;
  font-style: italic;
}
</style>

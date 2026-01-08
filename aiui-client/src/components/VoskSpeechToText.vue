<template>
  <div class="stt-input">
    <textarea
      :value="modelValue"
      @input="$emit('update:modelValue', $event.target.value)"
      rows="4"
    />

    <div class="controls">
      <button type="button" @click="toggle" :disabled="isLoading">
        {{ isRecording ? 'Stop' : (isLoading ? 'Loading…' : 'Mic') }}
      </button>

      <span v-if="partialText" class="partial">
        {{ partialText }}
      </span>
    </div>
  </div>
</template>

<script>
import Vosk from 'vosk-browser'

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

      _model: null,
      _recognizer: null,
      _mediaStream: null,
      _audioContext: null,
      _sourceNode: null,

      _workletNode: null,
      _silenceGainNode: null,
      _workletReady: false,

      _baseTextAtStart: ''
    }
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
      this._baseTextAtStart = this.modelValue || ''
      this.$emit('status', { state: 'loading_model' })

      try {
        await this._ensureModel()
        this._setupRecognizer()

        this.$emit('status', { state: 'requesting_mic' })
        this._mediaStream = await navigator.mediaDevices.getUserMedia({
          video: false,
          audio: {
            echoCancellation: true,
            noiseSuppression: true,
            channelCount: 1,
            sampleRate: this.sampleRate
          }
        })

        this.$emit('status', { state: 'starting_audio' })
        this._audioContext = new AudioContext({ sampleRate: this.sampleRate })
        this._sourceNode = this._audioContext.createMediaStreamSource(this._mediaStream)

        await this._ensureWorklet()

        this._workletNode = new AudioWorkletNode(this._audioContext, 'vosk-audio-worklet', {
          numberOfInputs: 1,
          numberOfOutputs: 1,
          channelCount: 1
        })

        this._workletNode.port.onmessage = (event) => {
          if (!this._recognizer) return

          const chunk = event.data
          if (!chunk || !chunk.length) return

          try {
            const audioBuffer = this._audioContext.createBuffer(1, chunk.length, this._audioContext.sampleRate)
            audioBuffer.copyToChannel(chunk, 0)
            this._recognizer.acceptWaveform(audioBuffer)
          } catch (e) {
            this.$emit('error', e)
          }
        }

        this._silenceGainNode = this._audioContext.createGain()
        this._silenceGainNode.gain.value = 0

        this._sourceNode.connect(this._workletNode)
        this._workletNode.connect(this._silenceGainNode)
        this._silenceGainNode.connect(this._audioContext.destination)

        this.isRecording = true
        this.$emit('status', { state: 'recording' })
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
        if (this._workletNode) {
          this._workletNode.port.onmessage = null
          this._workletNode.disconnect()
        }
      } catch (e) {}

      try {
        if (this._sourceNode) this._sourceNode.disconnect()
      } catch (e) {}

      try {
        if (this._silenceGainNode) this._silenceGainNode.disconnect()
      } catch (e) {}

      try {
        if (this._audioContext) this._audioContext.close()
      } catch (e) {}

      try {
        if (this._mediaStream) {
          this._mediaStream.getTracks().forEach(t => t.stop())
        }
      } catch (e) {}

      this._workletNode = null
      this._silenceGainNode = null
      this._sourceNode = null
      this._audioContext = null
      this._mediaStream = null
      this._recognizer = null
    },

    async _ensureWorklet () {
      if (this._workletReady) return
      if (!this._audioContext) throw new Error('AudioContext not initialized')

      await this._audioContext.audioWorklet.addModule('/vosk-audio-worklet.js')
      this._workletReady = true
    },

    async _ensureModel () {
      if (this._model) return
      this.$emit('status', { state: 'downloading_model', url: this.modelUrl })
      this._model = await Vosk.createModel(this.modelUrl)
    },

    _setupRecognizer () {
      if (!this._model) throw new Error('Vosk model not loaded')

      const recognizer = new this._model.KaldiRecognizer()

      recognizer.on('partialresult', (message) => {
        const partial = message && message.result && message.result.partial
        this.partialText = partial || ''

        const next = (this._baseTextAtStart + ' ' + (this.partialText || '')).replace(/\s+/g, ' ').trim()
        this.$emit('update:modelValue', next)
      })

      recognizer.on('result', (message) => {
        const text = message && message.result && message.result.text
        if (!text) return

        const merged = (this._baseTextAtStart + ' ' + text).replace(/\s+/g, ' ').trim()
        this._baseTextAtStart = merged
        this.partialText = ''
        this.$emit('update:modelValue', merged)
      })

      this._recognizer = recognizer
    }
  }
}
</script>

<style scoped>
.stt-input textarea {
  width: 100%;
  box-sizing: border-box;
}
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


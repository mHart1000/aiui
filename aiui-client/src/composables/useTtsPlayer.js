import { ref, computed } from 'vue'
import { api } from 'boot/axios'

/**
 * Composable for Text-to-Speech playback
 *
 * Phase 3: Basic synthesis and playback of individual audio clips
 * Phase 4: Will add streaming sentence detection and queue management
 *
 * @returns {Object} TTS state and control methods
 */
export function useTtsPlayer() {
  // Reactive state
  const isPlaying = ref(false)
  const isPaused = ref(false)
  const isEnabled = ref(false)
  const isTtsAvailable = ref(false)
  const currentVoice = ref('af_heart')
  const speed = ref(1.0)
  const availableVoices = ref([])

  // Web Audio API context
  let audioContext = null
  let currentSource = null
  let pausedAt = 0
  let startedAt = 0
  let audioDuration = 0

  /**
   * Initialize Audio Context (must be called after user interaction)
   */
  function initAudioContext() {
    if (!audioContext) {
      audioContext = new (window.AudioContext || window.webkitAudioContext)()
    }
    // Resume if suspended (browser autoplay policy)
    if (audioContext.state === 'suspended') {
      audioContext.resume()
    }
    return audioContext
  }

  /**
   * Check if TTS service is available
   */
  async function checkAvailability() {
    try {
      const response = await api.get('/api/tts/status')
      isTtsAvailable.value = response.data.available

      // Also fetch available voices if TTS is available
      if (isTtsAvailable.value) {
        const voicesResponse = await api.get('/api/tts/voices')
        availableVoices.value = voicesResponse.data.voices || []
      }

      return isTtsAvailable.value
    } catch (error) {
      console.warn('TTS availability check failed:', error)
      isTtsAvailable.value = false
      return false
    }
  }

  /**
   * Synthesize text to audio buffer
   *
   * @param {string} text - Text to synthesize
   * @returns {Promise<AudioBuffer>} Decoded audio buffer
   */
  async function synthesize(text) {
    if (!text || text.trim().length === 0) {
      throw new Error('Text cannot be empty')
    }

    try {
      const response = await api.post('/api/tts/synthesize', {
        text: text.trim(),
        voice: currentVoice.value,
        speed: speed.value
      }, {
        responseType: 'arraybuffer'
      })

      // Initialize audio context if needed
      const ctx = initAudioContext()

      // Decode audio data
      const audioBuffer = await ctx.decodeAudioData(response.data)
      return audioBuffer
    } catch (error) {
      console.error('TTS synthesis failed:', error)
      throw error
    }
  }

  /**
   * Play audio buffer
   *
   * @param {AudioBuffer} audioBuffer - Audio buffer to play
   */
  function playAudioBuffer(audioBuffer) {
    // Stop any currently playing audio
    stopPlayback()

    const ctx = initAudioContext()

    // Create buffer source
    currentSource = ctx.createBufferSource()
    currentSource.buffer = audioBuffer
    currentSource.connect(ctx.destination)

    // Track playback state
    audioDuration = audioBuffer.duration
    startedAt = ctx.currentTime - pausedAt
    isPlaying.value = true
    isPaused.value = false

    // Handle playback end
    currentSource.onended = () => {
      if (isPlaying.value) {
        // Natural end, not stopped by user
        isPlaying.value = false
        isPaused.value = false
        pausedAt = 0
        startedAt = 0
        audioDuration = 0
        currentSource = null
      }
    }

    // Start playback (resume from pausedAt position)
    currentSource.start(0, pausedAt)
  }

  /**
   * Synthesize and play text
   *
   * @param {string} text - Text to speak
   * @returns {Promise<void>}
   */
  async function speak(text) {
    try {
      const audioBuffer = await synthesize(text)
      playAudioBuffer(audioBuffer)
    } catch (error) {
      console.error('Failed to speak text:', error)
      throw error
    }
  }

  /**
   * Pause current playback
   */
  function pause() {
    if (!currentSource || !isPlaying.value || isPaused.value) {
      return
    }

    const ctx = audioContext
    if (ctx) {
      // Calculate how far into the audio we are
      pausedAt = ctx.currentTime - startedAt

      // Stop the source
      try {
        currentSource.stop()
      } catch {
        // Already stopped
      }

      isPaused.value = true
      isPlaying.value = false
    }
  }

  /**
   * Resume paused playback
   * Note: Web Audio API doesn't support true pause/resume,
   * so we need to recreate the buffer and start from the paused position
   */
  function resume() {
    if (!isPaused.value || !currentSource || !currentSource.buffer) {
      return
    }

    // Re-create and play from paused position
    const buffer = currentSource.buffer
    playAudioBuffer(buffer)
  }

  /**
   * Stop playback completely
   */
  function stop() {
    stopPlayback()
  }

  /**
   * Internal: Stop current playback and clean up
   */
  function stopPlayback() {
    if (currentSource) {
      try {
        currentSource.stop()
        currentSource.disconnect()
      } catch {
        // Already stopped
      }
      currentSource = null
    }

    isPlaying.value = false
    isPaused.value = false
    pausedAt = 0
    startedAt = 0
    audioDuration = 0
  }

  /**
   * Set the voice for synthesis
   *
   * @param {string} voiceId - Voice identifier
   */
  function setVoice(voiceId) {
    currentVoice.value = voiceId
  }

  /**
   * Set playback speed
   *
   * @param {number} newSpeed - Speed multiplier (0.5 - 2.0)
   */
  function setSpeed(newSpeed) {
    speed.value = Math.max(0.5, Math.min(2.0, newSpeed))
  }

  /**
   * Toggle TTS enabled state
   *
   * @param {boolean} enabled - Whether TTS is enabled
   */
  function setEnabled(enabled) {
    isEnabled.value = enabled
    if (!enabled) {
      stopPlayback()
    }
  }

  /**
   * Get current playback position
   */
  const currentTime = computed(() => {
    if (!audioContext || !isPlaying.value) return 0
    return audioContext.currentTime - startedAt
  })

  /**
   * Get total duration
   */
  const duration = computed(() => audioDuration)

  return {
    // State
    isPlaying,
    isPaused,
    isEnabled,
    isTtsAvailable,
    currentVoice,
    speed,
    availableVoices,
    currentTime,
    duration,

    // Methods
    checkAvailability,
    speak,
    pause,
    resume,
    stop,
    setVoice,
    setSpeed,
    setEnabled
  }
}

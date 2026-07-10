import { ref } from 'vue'
import { api } from 'boot/axios'

/**
 * Composable for Text-to-Speech playback with streaming sentence support
 *
 * Supports both:
 * - Immediate playback of complete messages (sentence chunking for speed)
 * - Streaming playback as text arrives (sentence-by-sentence)
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
  const queueLength = ref(0)

  // Web Audio API context
  let audioContext = null

  // Sentence queue management
  let sentenceQueue = []
  let textBuffer = ''
  let isProcessing = false
  let currentPlaybackChain = null
  // Streaming engines: rolling batches, one stream in flight
  let serverStreaming = false
  let streamWorkerActive = false
  let streamNextStartTime = 0 // Rolling schedule clock across batches
  let streamAbort = null
  let activeSources = [] // Scheduled-ahead sources, silenced by stop()

  const PREFETCH_AHEAD = 3 // Non-streaming engines only
  const STREAM_SEGMENT_SECONDS = 0.5 // Seconds of audio per scheduled segment

  /**
   * Split text into sentences
   * Handles sentences, bullet points, and list items
   * 
   * @param {string} text - Text to split
   * @returns {Array<string>} Array of sentences
   */
  function splitIntoSentences(text) {
    if (!text || text.trim().length === 0) return []

    // Drop fenced code blocks; inline code/markdown is normalized in queueSentence
    text = text.replace(/```[\s\S]*?```/g, '')

    const sentences = []
    
    // Split on newlines first to handle bullet points and list items
    const lines = text.split('\n')
    let buffer = ''

    for (const line of lines) {
      const trimmed = line.trim()
      
      // Skip empty lines
      if (trimmed.length === 0) {
        if (buffer.trim().length > 0) {
          // Flush buffer and split any sentences in it
          sentences.push(...splitBySentencePunctuation(buffer.trim()))
          buffer = ''
        }
        continue
      }

      // Check if this is a bullet point or list item
      const isBullet = /^[*•-]\s+/.test(trimmed) || /^\d+\.\s+/.test(trimmed)
      
      if (isBullet) {
        // Flush any buffered text first
        if (buffer.trim().length > 0) {
          sentences.push(...splitBySentencePunctuation(buffer.trim()))
          buffer = ''
        }
        
        // Add bullet point as its own sentence if it's substantial
        if (!isCodeOrUrl(trimmed) && trimmed.length > 5) {
          sentences.push(trimmed)
        }
      } else {
        // Accumulate regular text
        buffer += (buffer ? ' ' : '') + trimmed
        
        // If buffer ends with sentence punctuation, flush it
        if (/[.!?]\s*$/.test(buffer)) {
          sentences.push(...splitBySentencePunctuation(buffer.trim()))
          buffer = ''
        }
      }
    }

    // Flush any remaining buffer
    if (buffer.trim().length > 0) {
      sentences.push(...splitBySentencePunctuation(buffer.trim()))
    }

    return sentences.filter(s => s.length > 0 && !isCodeOrUrl(s))
  }

  /**
   * Split text by sentence-ending punctuation
   * Helper for splitIntoSentences
   */
  function splitBySentencePunctuation(text) {
    const sentences = []
    const regex = /[^.!?]+[.!?]+/g
    let match
    let lastIndex = 0

    while ((match = regex.exec(text)) !== null) {
      sentences.push(match[0].trim())
      lastIndex = regex.lastIndex
    }

    // Catch any remaining text
    const remainder = text.slice(lastIndex).trim()
    if (remainder.length > 0) {
      sentences.push(remainder)
    }

    return sentences
  }

  /**
   * Check if text is likely code or a URL (skip TTS for these)
   */
  function isCodeOrUrl(text) {
    // Skip URLs
    if (text.match(/^https?:\/\//)) return true
    // Skip if mostly non-alphabetic (likely code)
    const alphaCount = (text.match(/[a-zA-Z]/g) || []).length
    return alphaCount < text.length * 0.3
  }

  /**
   * Convert markdown to speakable plain text (formatting stripped, inline code kept).
   * Underscores stay (snake_case); prose dashes become periods so the engine pauses.
   *
   * @param {string} text - Sentence to normalize
   * @returns {string} Plain text
   */
  function stripMarkdown(text) {
    return text
      .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1') // images -> alt text
      .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')  // links -> link text
      .replace(/`([^`]+)`/g, '$1')              // inline code -> spoken content
      .replace(/\*{1,3}([^*]+)\*{1,3}/g, '$1')  // bold/italic -> inner text
      .replace(/~~([^~]+)~~/g, '$1')            // strikethrough -> inner text
      .replace(/^\s{0,3}#{1,6}\s+/gm, '')       // heading markers
      .replace(/^\s{0,3}>\s?/gm, '')            // blockquote markers
      .replace(/^\s{0,3}[-*+•]\s+/gm, '')       // list markers
      .replace(/[`*]/g, '')                     // stray backticks/asterisks
      .replace(/\s*(?:—|--)\s*/g, '. ')         // em dash / double hyphen -> pause
      .replace(/\s+–\s+/g, '. ')                // spaced en dash -> pause (keep 10–20 ranges)
      .replace(/\s{2,}/g, ' ')
      .trim()
  }

  /**
   * Extract complete sentences from buffer
   * Used for streaming text that arrives incrementally
   */
  function extractCompleteSentences() {
    const sentences = []
    
    // First, check for complete lines (ending with newline) - could be bullet points
    const lines = textBuffer.split('\n')
    
    // Keep the last line in buffer if it doesn't end with newline
    const endsWithNewline = textBuffer.endsWith('\n')
    const bufferLines = endsWithNewline ? lines : lines.slice(0, -1)
    textBuffer = endsWithNewline ? '' : (lines[lines.length - 1] || '')
    
    // Process each complete line
    for (const line of bufferLines) {
      const trimmed = line.trim()
      if (trimmed.length === 0) continue
      
      // Check if it's a bullet point
      const isBullet = /^[*•-]\s+/.test(trimmed) || /^\d+\.\s+/.test(trimmed)
      
      if (isBullet && !isCodeOrUrl(trimmed) && trimmed.length > 5) {
        sentences.push(trimmed)
      } else {
        // For regular text, split by sentence punctuation
        sentences.push(...splitBySentencePunctuation(trimmed))
      }
    }
    
    // Also check buffer for complete sentences (ending with . ! ?)
    const regex = /[^.!?]+[.!?]+/g
    let match
    let lastMatchEnd = 0
    
    while ((match = regex.exec(textBuffer)) !== null) {
      const sentence = match[0].trim()
      if (sentence.length > 0 && !isCodeOrUrl(sentence)) {
        sentences.push(sentence)
      }
      lastMatchEnd = regex.lastIndex
    }
    
    // Keep remainder in buffer
    textBuffer = textBuffer.slice(lastMatchEnd)

    return sentences
  }

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
   * Add sentence to queue and process
   *
   * @param {string} sentence - Sentence to queue
   */
  async function queueSentence(sentence) {
    if (!sentence) return
    const spoken = stripMarkdown(sentence.trim())
    if (spoken.length === 0) return

    const queueItem = {
      text: spoken,
      status: 'pending', // pending | synthesizing | ready | playing | done
      audioBuffer: null,
      error: null
    }

    sentenceQueue.push(queueItem)
    queueLength.value = sentenceQueue.length

    // Start processing if not already
    if (serverStreaming) {
      // Defer a tick so a synchronous burst of sentences batches together
      setTimeout(runStreamWorker, 0)
    } else if (!isProcessing) {
      processQueue()
    }
  }

  /**
   * Process the sentence queue
   * Maintains prefetch pipeline and starts playback
   */
  async function processQueue() {
    if (isProcessing) return
    isProcessing = true

    try {
      // Start prefetching and playback concurrently
      const prefetchLoop = async () => {
        while (sentenceQueue.length > 0 || isPlaying.value) {
          await prefetchSentences()
          await new Promise(resolve => setTimeout(resolve, 100))
        }
      }

      const playbackLoop = async () => {
        // Wait for first sentence to be ready
        while (sentenceQueue.length > 0 && sentenceQueue[0].status !== 'ready') {
          await new Promise(resolve => setTimeout(resolve, 50))
        }
        
        if (sentenceQueue.length > 0) {
          await playQueuedSentences()
        }
      }

      // Run both loops concurrently
      await Promise.all([prefetchLoop(), playbackLoop()])
    } finally {
      isProcessing = false
      queueLength.value = 0
    }
  }

  /**
   * Prefetch audio for upcoming sentences
   */
  async function prefetchSentences() {
    const synthesizingCount = sentenceQueue.filter(item => item.status === 'synthesizing').length
    const pendingItems = sentenceQueue.filter(item => item.status === 'pending')

    const toSynthesize = Math.min(PREFETCH_AHEAD - synthesizingCount, pendingItems.length)

    // Fire without awaiting: awaiting here serializes the pipeline
    for (let i = 0; i < toSynthesize; i++) {
      synthesizeSentence(pendingItems[i])
    }
  }

  /**
   * Synthesize a single sentence
   */
  async function synthesizeSentence(queueItem) {
    queueItem.status = 'synthesizing'

    try {
      queueItem.audioBuffer = await synthesize(queueItem.text)
      queueItem.status = 'ready'
    } catch (error) {
      console.error('Failed to synthesize sentence:', error)
      queueItem.error = error
      queueItem.status = 'done' // Skip this sentence
    }
  }

  /**
   * Play queued sentences in sequence (gapless)
   */
  async function playQueuedSentences() {
    if (isPlaying.value || sentenceQueue.length === 0) return

    isPlaying.value = true
    const ctx = initAudioContext()

    let nextStartTime = ctx.currentTime

    while (sentenceQueue.length > 0 && isPlaying.value) {
      const item = sentenceQueue[0]

      // Wait for the sentence to be ready
      while (item.status !== 'ready' && item.status !== 'done' && isPlaying.value) {
        await new Promise(resolve => setTimeout(resolve, 50))
      }

      if (!isPlaying.value) break
      if (item.status === 'done') {
        // Skip failed sentences
        sentenceQueue.shift()
        queueLength.value = sentenceQueue.length
        continue
      }

      // Play the sentence
      const source = ctx.createBufferSource()
      source.buffer = item.audioBuffer
      source.connect(ctx.destination)

      // Schedule to start when previous ends (or now if first)
      const startTime = Math.max(nextStartTime, ctx.currentTime)
      source.start(startTime)
      nextStartTime = startTime + item.audioBuffer.duration

      // Track current source
      currentPlaybackChain = source

      // Wait for this sentence to finish
      await new Promise(resolve => {
        source.onended = () => {
          item.status = 'done'
          sentenceQueue.shift()
          queueLength.value = sentenceQueue.length
          resolve()
        }
      })
    }

    isPlaying.value = false
    currentPlaybackChain = null
  }

  /**
   * Check if TTS service is available
   */
  async function checkAvailability() {
    try {
      const response = await api.get('/api/tts/status')
      isTtsAvailable.value = response.data.available
      serverStreaming = !!response.data.streaming

      // Also fetch available voices if TTS is available
      if (isTtsAvailable.value) {
        const voicesResponse = await api.get('/api/tts/voices')
        availableVoices.value = voicesResponse.data.voices || []

        // Persisted voice may belong to a different TTS engine
        if (availableVoices.value.length > 0 && !availableVoices.value.includes(currentVoice.value)) {
          currentVoice.value = availableVoices.value[0]
        }
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
   * Stream worker: batches pending sentences into one /api/tts/stream request
   * and schedules arriving audio. See docs/tts-streaming-spec.md.
   */
  async function runStreamWorker() {
    if (streamWorkerActive) return
    streamWorkerActive = true
    isPlaying.value = true
    const ctx = initAudioContext()
    streamNextStartTime = Math.max(streamNextStartTime, ctx.currentTime)

    try {
      while (isPlaying.value) {
        const batch = sentenceQueue.filter(item => item.status === 'pending')

        if (batch.length > 0) {
          for (const item of batch) item.status = 'synthesizing'
          const clockBefore = streamNextStartTime
          try {
            await streamBatch(batch.map(item => item.text).join('\n'), ctx)
          } catch (error) {
            if (error.name === 'AbortError') {
              // stop() aborted us; the loop exits via isPlaying
            } else if (streamNextStartTime > clockBefore) {
              // Partial audio arrived and was scheduled; drop the batch
              console.error('TTS batch stream interrupted:', error)
            } else {
              // Nothing arrived: fall back to per-sentence synthesis
              console.warn('TTS stream failed, falling back to per-sentence synthesis:', error)
              serverStreaming = false
              for (const item of batch) item.status = 'pending'
              isPlaying.value = false
              if (!isProcessing) processQueue()
              return
            }
          }
          for (const item of batch) item.status = 'done'
          sentenceQueue = sentenceQueue.filter(item => item.status !== 'done')
          queueLength.value = sentenceQueue.length
          continue
        }

        // Nothing pending: exit once the scheduled audio has finished playing
        if (ctx.currentTime >= streamNextStartTime - 0.03) break
        await new Promise(resolve => setTimeout(resolve, 100))
      }
    } finally {
      streamWorkerActive = false
    }

    isPlaying.value = false
    // Catch sentences that arrived in the exit window
    if (serverStreaming && sentenceQueue.some(item => item.status === 'pending')) {
      runStreamWorker()
    }
  }

  /**
   * Stream one batch from /api/tts/stream (WAV header then PCM16), scheduling
   * segments on the rolling clock as they arrive.
   *
   * @param {string} text - Batch text (the server splits it internally)
   * @param {AudioContext} ctx - Audio context for scheduling
   */
  async function streamBatch(text, ctx) {
    const controller = new AbortController()
    streamAbort = controller

    try {
      const headers = { 'Content-Type': 'application/json' }
      const token = localStorage.getItem('jwt')
      if (token) headers.Authorization = `Bearer ${token}`

      const baseURL = import.meta.env.VITE_API_BASE_URL || ''
      const response = await fetch(`${baseURL}/api/tts/stream`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          text,
          voice: currentVoice.value,
          speed: speed.value
        }),
        signal: controller.signal
      })

      if (!response.ok || !response.body) {
        throw new Error(`TTS stream failed: ${response.status}`)
      }

      const reader = response.body.getReader()
      let wavFormat = null // { channels, sampleRate }
      let pending = new Uint8Array(0)

      const scheduleSegment = (byteCount) => {
        const segBytes = pending.slice(0, byteCount)
        pending = pending.slice(byteCount)

        const samples = new Int16Array(segBytes.buffer, 0, segBytes.length / 2)
        const frames = samples.length / wavFormat.channels
        const buffer = ctx.createBuffer(wavFormat.channels, frames, wavFormat.sampleRate)
        for (let ch = 0; ch < wavFormat.channels; ch++) {
          const data = buffer.getChannelData(ch)
          for (let i = 0; i < frames; i++) {
            data[i] = samples[i * wavFormat.channels + ch] / 32768
          }
        }

        const source = ctx.createBufferSource()
        source.buffer = buffer
        source.connect(ctx.destination)
        const startTime = Math.max(streamNextStartTime, ctx.currentTime)
        source.start(startTime)
        streamNextStartTime = startTime + buffer.duration
        trackSource(source)
        currentPlaybackChain = source
      }

      while (true) {
        const { done, value } = await reader.read()
        if (done) break

        const merged = new Uint8Array(pending.length + value.length)
        merged.set(pending)
        merged.set(value, pending.length)
        pending = merged

        if (!wavFormat && pending.length >= 44) {
          const view = new DataView(pending.buffer, 0, 44)
          wavFormat = {
            channels: view.getUint16(22, true),
            sampleRate: view.getUint32(24, true)
          }
          pending = pending.slice(44)
        }

        if (wavFormat) {
          const frameBytes = wavFormat.channels * 2
          const segmentBytes = Math.floor(wavFormat.sampleRate * STREAM_SEGMENT_SECONDS) * frameBytes
          while (pending.length >= segmentBytes) {
            scheduleSegment(segmentBytes)
          }
        }
      }

      // Flush the frame-aligned remainder
      if (wavFormat) {
        const frameBytes = wavFormat.channels * 2
        const flushable = pending.length - (pending.length % frameBytes)
        if (flushable > 0) scheduleSegment(flushable)
      }
    } finally {
      if (streamAbort === controller) streamAbort = null
    }
  }

  /**
   * Track a scheduled-ahead source so stop() can silence it
   */
  function trackSource(source) {
    activeSources.push(source)
    source.onended = () => {
      const i = activeSources.indexOf(source)
      if (i !== -1) activeSources.splice(i, 1)
    }
  }

  /**
   * Feed text for streaming (Phase 4)
   * Accumulates text and extracts complete sentences
   *
   * @param {string} newText - New text chunk to add
   */
  function feedText(newText) {
    if (!isEnabled.value || !newText) return

    textBuffer += newText
    const sentences = extractCompleteSentences()

    for (const sentence of sentences) {
      queueSentence(sentence)
    }
  }

  /**
   * Flush any remaining text in buffer (call when stream completes)
   */
  function flushBuffer() {
    if (textBuffer.trim().length > 0 && !isCodeOrUrl(textBuffer)) {
      queueSentence(textBuffer.trim())
      textBuffer = ''
    }
  }

  /**
   * Synthesize and play text (Phase 3 + 4 hybrid)
   * Now uses sentence chunking for faster perceived start time
   *
   * @param {string} text - Text to speak
   * @returns {Promise<void>}
   */
  async function speak(text) {
    if (!text || text.trim().length === 0) return

    try {
      // Stop any current playback
      stop()

      // Split into sentences and queue
      const sentences = splitIntoSentences(text)

      for (const sentence of sentences) {
        await queueSentence(sentence)
      }
    } catch (error) {
      console.error('Failed to speak text:', error)
      throw error
    }
  }

  /**
   * Pause current playback
   * Note: Pausing gapless playback is complex, so we just stop for now
   */
  function pause() {
    stop()
    isPaused.value = true
  }

  /**
   * Resume paused playback
   * Since we stop on pause, this is effectively a no-op
   */
  function resume() {
    isPaused.value = false
  }

  /**
   * Stop playback completely
   */
  function stop() {
    isPlaying.value = false
    isPaused.value = false

    // Abort the in-flight batch stream
    if (streamAbort) {
      try { streamAbort.abort() } catch { /* already settled */ }
      streamAbort = null
    }

    // Stop current audio and any scheduled-ahead stream segments
    if (currentPlaybackChain) {
      try {
        currentPlaybackChain.stop()
        currentPlaybackChain.disconnect()
      } catch {
        // Already stopped
      }
      currentPlaybackChain = null
    }
    for (const source of activeSources) {
      try {
        source.stop()
        source.disconnect()
      } catch {
        // Already stopped
      }
    }
    activeSources = []

    // Clear queue
    sentenceQueue = []
    textBuffer = ''
    queueLength.value = 0
    isProcessing = false
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
      stop()
    }
  }

  return {
    // State
    isPlaying,
    isPaused,
    isEnabled,
    isTtsAvailable,
    currentVoice,
    speed,
    availableVoices,
    queueLength,

    // Methods
    checkAvailability,
    speak,
    feedText,
    flushBuffer,
    pause,
    resume,
    stop,
    setVoice,
    setSpeed,
    setEnabled
  }
}

import { ref } from 'vue'

/**
 * Composable for handling streaming chat responses with two-pass reasoning.
 *
 * Manages SSE (Server-Sent Events) streaming from the backend,
 * accumulating both thinking and response phases in real-time.
 *
 * @returns {Object} Reactive state and methods for streaming chat
 */
export function useStreamingChat() {
  const thinkingText = ref('')
  const responseText = ref('')
  const stats = ref(null) // { total_tokens, tokens_per_second, generation_ms }
  const isStreaming = ref(false)
  const error = ref(null)
  const loadingPhase = ref('idle') // 'idle' | 'connecting' | 'thinking' | 'responding' | 'done'

  let activeStream = null

  const STREAM_TIMEOUT_MS = 120000 // 2 minutes of inactivity

  function requestError(payload, fallback = 'The request failed') {
    const details = payload?.error ?? payload
    const message = typeof details === 'string'
      ? details
      : details?.message || details?.content
    return new Error(message || fallback)
  }

  /**
   * Send a message and stream the response.
   *
   * @param {number} conversationId
   * @param {string} content
   * @param {string} token
   * @param {string} modelCode
   * @param {Object} options - Additional options like skipUserMessage
   * @returns {Promise<void>}
   */
  async function sendMessage(conversationId, content, token, modelCode = null, options = {}) {
    // Cancel any existing stream
    cleanup()

    // Reset state
    thinkingText.value = ''
    responseText.value = ''
    stats.value = null
    error.value = null
    isStreaming.value = true
    loadingPhase.value = 'connecting'

    const stream = {
      abortController: new AbortController(),
      reader: null,
      timeoutId: null,
      cancelled: false
    }
    activeStream = stream
    let streamStarted = false

    function resetStreamTimeout() {
      clearTimeout(stream.timeoutId)
      stream.timeoutId = setTimeout(() => {
        cleanup()
        const timeoutError = new Error('Stream timeout - no data received for 2 minutes')
        timeoutError.streamStarted = streamStarted
        error.value = timeoutError
        loadingPhase.value = 'idle'
        isStreaming.value = false
      }, STREAM_TIMEOUT_MS)
    }

    resetStreamTimeout()

    try {
      const url = `/api/conversations/${conversationId}/messages/stream`
      const requestBody = new FormData()
      requestBody.append('content', content)
      if (modelCode) requestBody.append('model_code', modelCode)
      if (options.regenerating) {
        requestBody.append('regenerating', 'true')
        if (options.regeneratingMessageId) {
          requestBody.append('message_id', options.regeneratingMessageId)
        }
      }
      options.images?.forEach(file => requestBody.append('images[]', file, file.name))

      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`
        },
        body: requestBody,
        signal: stream.abortController.signal
      })

      if (!response.ok) {
        let payload = null
        try {
          payload = await response.json()
        } catch {
          payload = null
        }
        throw requestError(payload, `Request failed (${response.status})`)
      }

      if (!response.body) {
        throw new Error('Streaming not supported in this browser')
      }

      streamStarted = true

      stream.reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      let receivedDone = false

      while (true) {
        const { done, value } = await stream.reader.read()

        if (done) {
          break
        }

        // Reset inactivity timeout on each chunk received
        resetStreamTimeout()

        // Decode chunk and add to buffer
        buffer += decoder.decode(value, { stream: true })

        // Process complete SSE messages (format: "data: {...}\n\n")
        const lines = buffer.split('\n\n')
        buffer = lines.pop() // Keep incomplete message in buffer

        for (const line of lines) {
          if (line.startsWith(':')) {
            continue
          }

          if (line.startsWith('data: ')) {
            let data
            try {
              data = JSON.parse(line.substring(6))
            } catch (parseError) {
              console.warn('Failed to parse SSE event:', line, parseError)
              continue
            }

            switch (data.type) {
                case 'thinking':
                  if (loadingPhase.value === 'connecting') {
                    loadingPhase.value = 'thinking'
                  }
                  thinkingText.value += data.content
                  break

                case 'phase_change':
                  loadingPhase.value = data.phase || 'responding'
                  break

                case 'response':
                  if (loadingPhase.value !== 'responding') {
                    loadingPhase.value = 'responding'
                  }
                  responseText.value += data.content
                  break

                case 'stats':
                  stats.value = {
                    total_tokens: data.total_tokens,
                    tokens_per_second: data.tokens_per_second,
                    generation_ms: data.generation_ms
                  }
                  break

                case 'done':
                  receivedDone = true
                  isStreaming.value = false
                  loadingPhase.value = 'done'
                  clearTimeout(stream.timeoutId)
                  break

                case 'error':
                  throw requestError(data)
            }
          }
        }
      }

      if (stream.cancelled) return

      if (!receivedDone) {
        throw new Error('The response stream ended before it was saved.')
      }

      // Stream completed successfully after the server persisted the response.
      isStreaming.value = false
      loadingPhase.value = 'done'
      clearTimeout(stream.timeoutId)

    } catch (err) {
      const isCurrent = activeStream === stream
      if (isCurrent) clearTimeout(stream.timeoutId)
      if (err.name === 'AbortError' || stream.cancelled) {
        // User stop, voice escape, or timeout cleanup — keep partial text;
        // don't surface an error or let ChatPage splice the message.
        if (isCurrent) {
          isStreaming.value = false
          if (!error.value) loadingPhase.value = 'done' // preserve a timeout error
        }
      } else if (isCurrent) {
        err.streamStarted = streamStarted
        error.value = err
        loadingPhase.value = 'idle'
        isStreaming.value = false
      }
    } finally {
      if (activeStream === stream) activeStream = null
    }
  }

  function dismissError() {
    error.value = null
  }

  function cleanup() {
    if (!activeStream) return

    activeStream.cancelled = true
    if (activeStream.reader) {
      activeStream.reader.cancel().catch(err => {
        console.warn('Error canceling reader:', err)
      })
    }

    activeStream.abortController.abort()

    clearTimeout(activeStream.timeoutId)
  }

  // Stop streaming on user request and keep the partial response without an error.
  function stop() {
    cleanup()
    isStreaming.value = false
    loadingPhase.value = 'done'
  }

  return {
    // Reactive state
    thinkingText,
    responseText,
    stats,
    isStreaming,
    error,
    loadingPhase,

    // Methods
    sendMessage,
    dismissError,
    cleanup,
    stop
  }
}

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

  let currentAbortController = null
  let currentReader = null
  let streamTimeoutId = null

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

    currentAbortController = new AbortController()
    let streamStarted = false

    function resetStreamTimeout() {
      clearTimeout(streamTimeoutId)
      streamTimeoutId = setTimeout(() => {
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
        signal: currentAbortController.signal
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

      currentReader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      let receivedDone = false

      while (true) {
        const { done, value } = await currentReader.read()

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
                  clearTimeout(streamTimeoutId)
                  break

                case 'error':
                  throw requestError(data)
            }
          }
        }
      }

      if (!receivedDone) {
        throw new Error('The response stream ended before it was saved.')
      }

      // Stream completed successfully after the server persisted the response.
      isStreaming.value = false
      loadingPhase.value = 'done'
      clearTimeout(streamTimeoutId)

    } catch (err) {
      clearTimeout(streamTimeoutId)
      if (err.name === 'AbortError') {
        // User stop, voice escape, or timeout cleanup — keep partial text;
        // don't surface an error or let ChatPage splice the message.
        isStreaming.value = false
        if (!error.value) loadingPhase.value = 'done' // preserve a timeout error
      } else {
        err.streamStarted = streamStarted
        error.value = err
        loadingPhase.value = 'idle'
        isStreaming.value = false
      }
    }
  }

  function dismissError() {
    error.value = null
  }

  function cleanup() {
    if (currentReader) {
      currentReader.cancel().catch(err => {
        console.warn('Error canceling reader:', err)
      })
      currentReader = null
    }

    if (currentAbortController) {
      currentAbortController.abort()
      currentAbortController = null
    }

    if (streamTimeoutId) {
      clearTimeout(streamTimeoutId)
      streamTimeoutId = null
    }
  }

  // Stop streaming on user request: abort the connection and settle state so the
  // partial response is kept (no error). Distinct from cleanup(), which is a pure
  // teardown used on unmount and before starting a new stream.
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

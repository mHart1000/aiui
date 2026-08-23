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

    function resetStreamTimeout() {
      clearTimeout(streamTimeoutId)
      streamTimeoutId = setTimeout(() => {
        cleanup()
        error.value = new Error('Stream timeout - no data received for 2 minutes')
        isStreaming.value = false
      }, STREAM_TIMEOUT_MS)
    }

    resetStreamTimeout()

    try {
      const url = `/api/conversations/${conversationId}/messages/stream`
      const images = options.images || []
      const useMultipart = images.length > 0
      const requestBody = useMultipart ? new FormData() : { content }
      if (useMultipart) requestBody.append('content', content)

      const setField = (key, value) => {
        if (useMultipart) requestBody.append(key, String(value))
        else requestBody[key] = value
      }

      if (modelCode) setField('model_code', modelCode)
      if (options.regenerating) {
        setField('regenerating', true)
        if (options.regeneratingMessageId) setField('message_id', options.regeneratingMessageId)
      }
      if (useMultipart) images.forEach(image => requestBody.append('images[]', image.file, image.file.name))

      const headers = { 'Authorization': `Bearer ${token}` }
      if (!useMultipart) headers['Content-Type'] = 'application/json'

      const response = await fetch(url, {
        method: 'POST',
        headers,
        body: useMultipart ? requestBody : JSON.stringify(requestBody),
        signal: currentAbortController.signal
      })

      if (!response.ok) {
        const payload = await response.json().catch(() => null)
        const requestError = new Error(payload?.error?.message || `Request failed with status ${response.status}`)
        requestError.code = payload?.error?.code
        requestError.status = response.status
        throw requestError
      }

      if (!response.body) {
        throw new Error('Streaming not supported in this browser')
      }

      currentReader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      let sawDone = false

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
                if (loadingPhase.value === 'connecting') loadingPhase.value = 'thinking'
                thinkingText.value += data.content
                break

              case 'phase_change':
                loadingPhase.value = data.phase || 'responding'
                break

              case 'response':
                if (loadingPhase.value !== 'responding') loadingPhase.value = 'responding'
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
                sawDone = true
                isStreaming.value = false
                loadingPhase.value = 'done'
                clearTimeout(streamTimeoutId)
                break

              case 'error':
                throw new Error(data.content)
            }
          }
        }
      }

      if (!sawDone) throw new Error('The response stream ended before completion.')

      // Stream completed successfully
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

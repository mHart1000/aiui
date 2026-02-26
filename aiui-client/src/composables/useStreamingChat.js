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
  const isStreaming = ref(false)
  const error = ref(null)
  const loadingPhase = ref('idle') // 'idle' | 'connecting' | 'thinking' | 'responding' | 'done'
  const lastRequest = ref(null) // Store for retry

  let currentAbortController = null
  let currentReader = null
  let streamTimeoutId = null

  const STREAM_TIMEOUT_MS = 120000 // 2 minutes

  /**
   * Send a message and stream the response.
   *
   * @param {number} conversationId
   * @param {string} content
   * @param {string} token
   * @param {string} modelCode
   * @returns {Promise<void>}
   */
  async function sendMessage(conversationId, content, token, modelCode = null) {
    // Store request for potential retry
    lastRequest.value = { conversationId, content, token, modelCode }

    // Cancel any existing stream
    cleanup()

    // Reset state
    thinkingText.value = ''
    responseText.value = ''
    error.value = null
    isStreaming.value = true
    loadingPhase.value = 'connecting'

    currentAbortController = new AbortController()

    streamTimeoutId = setTimeout(() => {
      cleanup()
      error.value = new Error('Stream timeout - response took too long')
      isStreaming.value = false
    }, STREAM_TIMEOUT_MS)

    try {
      const url = `/api/conversations/${conversationId}/messages/stream`
      const requestBody = { content }
      if (modelCode) {
        requestBody.model_code = modelCode
      }

      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(requestBody),
        signal: currentAbortController.signal
      })

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }

      if (!response.body) {
        throw new Error('Streaming not supported in this browser')
      }

      currentReader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''

      while (true) {
        const { done, value } = await currentReader.read()

        if (done) {
          break
        }

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
            try {
              const data = JSON.parse(line.substring(6))

              switch (data.type) {
                case 'thinking':
                  if (loadingPhase.value === 'connecting') {
                    loadingPhase.value = 'thinking'
                  }
                  thinkingText.value += data.content
                  break

                case 'response':
                  if (loadingPhase.value !== 'responding') {
                    loadingPhase.value = 'responding'
                  }
                  responseText.value += data.content
                  break

                case 'done':
                  isStreaming.value = false
                  loadingPhase.value = 'done'
                  clearTimeout(streamTimeoutId)
                  break

                case 'error':
                  throw new Error(data.content)
              }
            } catch (parseError) {
              console.warn('Failed to parse SSE event:', line, parseError)
            }
          }
        }
      }

      // Stream completed successfully
      isStreaming.value = false
      loadingPhase.value = 'done'
      clearTimeout(streamTimeoutId)

    } catch (err) {
      error.value = err
      loadingPhase.value = 'idle'
    }
  }

  async function retryLastMessage() {
    if (lastRequest.value) {
      const { conversationId, content, token, modelCode } = lastRequest.value
      await sendMessage(conversationId, content, token, modelCode)
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

  return {
    // Reactive state
    thinkingText,
    responseText,
    isStreaming,
    error,
    loadingPhase,

    // Methods
    sendMessage,
    retryLastMessage,
    dismissError,
    cleanup
  }
}

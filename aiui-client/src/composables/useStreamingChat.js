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

  // Track current stream for cancellation
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
    // Cancel any existing stream
    cleanup()

    // Reset state
    thinkingText.value = ''
    responseText.value = ''
    error.value = null
    isStreaming.value = true

    currentAbortController = new AbortController()

    streamTimeoutId = setTimeout(() => {
      cleanup()
      error.value = 'Stream timeout - response took too long'
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
          // SSE comments (heartbeat) start with ":"
          if (line.startsWith(':')) {
            continue
          }

          // SSE data events start with "data: "
          if (line.startsWith('data: ')) {
            try {
              const data = JSON.parse(line.substring(6))

              switch (data.type) {
                case 'thinking':
                  thinkingText.value += data.content
                  break

                case 'response':
                  responseText.value += data.content
                  break

                case 'done':
                  isStreaming.value = false
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
      clearTimeout(streamTimeoutId)

    } catch (err) {
      // Handle different error types
      if (err.name === 'AbortError') {
        // Stream was intentionally cancelled
        console.log('Stream cancelled')
      } else if (err.name === 'NetworkError' || err.message.includes('network')) {
        error.value = 'Connection lost. Please check your network and try again.'
      } else {
        error.value = err.message
      }

      isStreaming.value = false
      clearTimeout(streamTimeoutId)

      // Re-throw if not a user-initiated abort
      if (err.name !== 'AbortError') {
        console.error('Streaming error:', err)
      }
    }
  }

  /**
   * Cleanup function to cancel active streams and clear timeouts.
   * Should be called on component unmount or before starting a new stream.
   */
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

    // Methods
    sendMessage,
    cleanup
  }
}

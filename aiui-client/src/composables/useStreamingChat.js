import { ref } from 'vue'

export function useStreamingChat() {
  const thinkingText = ref('')
  const responseText = ref('')
  const stats = ref(null)
  const isStreaming = ref(false)
  const error = ref(null)
  const loadingPhase = ref('idle')
  const wasStopped = ref(false)

  let currentAbortController = null
  let currentReader = null
  let streamTimeoutId = null

  const STREAM_TIMEOUT_MS = 120000

  function requestError(payload, fallback) {
    const details = payload?.error ?? payload
    return new Error(
      typeof details === 'string' ? details : details?.message || details?.content || fallback
    )
  }

  async function sendMessage(conversationId, content, token, modelCode = null, options = {}) {
    cleanup()

    thinkingText.value = ''
    responseText.value = ''
    stats.value = null
    error.value = null
    wasStopped.value = false
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
      const requestBody = new FormData()
      requestBody.append('content', content)
      if (modelCode) requestBody.append('model_code', modelCode)
      if (options.regenerating) {
        requestBody.append('regenerating', 'true')
        if (options.regeneratingMessageId) requestBody.append('message_id', options.regeneratingMessageId)
      }
      options.images?.forEach(file => requestBody.append('images[]', file, file.name))

      const response = await fetch(`/api/conversations/${conversationId}/messages/stream`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
        body: requestBody,
        signal: currentAbortController.signal
      })

      if (!response.ok) {
        const payload = await response.json().catch(() => null)
        throw requestError(payload, `Request failed (${response.status})`)
      }
      if (!response.body) throw new Error('Streaming not supported in this browser')

      streamStarted = true
      currentReader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''

      while (true) {
        const { done, value } = await currentReader.read()
        if (done) break

        resetStreamTimeout()
        buffer += decoder.decode(value, { stream: true })
        const events = buffer.split('\n\n')
        buffer = events.pop()

        for (const event of events) {
          if (event.startsWith(':') || !event.startsWith('data: ')) continue

          let data
          try {
            data = JSON.parse(event.substring(6))
          } catch (parseError) {
            console.warn('Failed to parse SSE event:', event, parseError)
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
              isStreaming.value = false
              loadingPhase.value = 'done'
              clearTimeout(streamTimeoutId)
              break
            case 'error':
              throw requestError(data, 'Generation failed')
          }
        }
      }

      isStreaming.value = false
      loadingPhase.value = 'done'
      clearTimeout(streamTimeoutId)
    } catch (err) {
      clearTimeout(streamTimeoutId)
      if (err.name === 'AbortError' || wasStopped.value) {
        isStreaming.value = false
        if (!error.value) loadingPhase.value = 'done'
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
    currentReader?.cancel().catch(err => console.warn('Error canceling reader:', err))
    currentReader = null
    currentAbortController?.abort()
    currentAbortController = null
    clearTimeout(streamTimeoutId)
    streamTimeoutId = null
  }

  function stop() {
    wasStopped.value = true
    cleanup()
    isStreaming.value = false
    loadingPhase.value = 'done'
  }

  return {
    thinkingText,
    responseText,
    stats,
    isStreaming,
    error,
    loadingPhase,
    wasStopped,
    sendMessage,
    dismissError,
    cleanup,
    stop
  }
}

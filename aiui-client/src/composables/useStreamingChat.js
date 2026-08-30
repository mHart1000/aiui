import { ref } from 'vue'

export function useStreamingChat() {
  const thinkingText = ref('')
  const responseText = ref('')
  const stats = ref(null)
  const isStreaming = ref(false)
  const error = ref(null)
  const loadingPhase = ref('idle')

  let abortController = null
  let reader = null
  let activeTimeoutId = null
  let requestSequence = 0
  let stoppedRequest = null

  const STREAM_TIMEOUT_MS = 120000

  function currentRequest (request) {
    return request === requestSequence
  }

  function clearStream () {
    clearTimeout(activeTimeoutId)
    activeTimeoutId = null
    reader = null
    abortController = null
  }

  function cleanup () {
    reader?.cancel().catch(err => console.warn('Error canceling reader:', err))
    abortController?.abort()
    clearTimeout(activeTimeoutId)
    activeTimeoutId = null
  }

  function requestError (payload, fallback) {
    const details = payload?.error ?? payload
    const message = typeof details === 'string' ? details : details?.message || details?.content
    return new Error(message || fallback)
  }

  async function sendMessage (conversationId, content, token, modelCode = null, options = {}) {
    cleanup()
    const request = ++requestSequence
    stoppedRequest = null
    thinkingText.value = ''
    responseText.value = ''
    stats.value = null
    error.value = null
    isStreaming.value = true
    loadingPhase.value = 'connecting'
    const controller = new AbortController()
    abortController = controller
    let streamStarted = false
    let timeoutId = null

    const resetStreamTimeout = () => {
      clearTimeout(timeoutId)
      timeoutId = setTimeout(() => {
        if (!currentRequest(request)) return
        error.value = new Error('Stream timeout - no data received for 2 minutes')
        loadingPhase.value = 'idle'
        isStreaming.value = false
        cleanup()
      }, STREAM_TIMEOUT_MS)
      if (currentRequest(request)) activeTimeoutId = timeoutId
    }

    resetStreamTimeout()

    try {
      const body = new FormData()
      body.append('content', content)
      if (modelCode) body.append('model_code', modelCode)
      if (options.regenerating) {
        body.append('regenerating', 'true')
        if (options.regeneratingMessageId) body.append('message_id', options.regeneratingMessageId)
      }
      options.images?.forEach(file => body.append('images[]', file, file.name))

      const response = await fetch(`/api/conversations/${conversationId}/messages/stream`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
        body,
        signal: controller.signal
      })

      if (!response.ok) {
        const payload = await response.json().catch(() => null)
        throw requestError(payload, `Request failed (${response.status})`)
      }
      if (!response.body) throw new Error('Streaming not supported in this browser')

      streamStarted = true
      const streamReader = response.body.getReader()
      reader = streamReader
      const decoder = new TextDecoder()
      let buffer = ''

      while (true) {
        const { done, value } = await streamReader.read()
        if (done) break
        if (!currentRequest(request)) return { outcome: 'superseded' }
        resetStreamTimeout()
        buffer += decoder.decode(value, { stream: true })
        const events = buffer.split('\n\n')
        buffer = events.pop()

        for (const event of events) {
          if (!event.startsWith('data: ')) continue

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
              break
            case 'error':
              throw requestError(data, 'Generation failed')
          }
        }
      }

      if (!currentRequest(request)) return { outcome: 'superseded' }
      if (stoppedRequest === request) return { outcome: 'stopped' }
      if (error.value) return { outcome: streamStarted ? 'failed_after_start' : 'failed_before_start' }
      isStreaming.value = false
      loadingPhase.value = 'done'
      return { outcome: 'completed' }
    } catch (err) {
      if (!currentRequest(request)) return { outcome: 'superseded' }
      if (stoppedRequest === request) return { outcome: 'stopped' }

      error.value ||= err
      loadingPhase.value = 'idle'
      isStreaming.value = false
      return { outcome: streamStarted ? 'failed_after_start' : 'failed_before_start' }
    } finally {
      clearTimeout(timeoutId)
      if (currentRequest(request)) clearStream()
    }
  }

  function dismissError () {
    error.value = null
  }

  function stop () {
    stoppedRequest = requestSequence
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
    sendMessage,
    dismissError,
    cleanup,
    stop
  }
}

<template>
  <q-page class="column">
    <div class="row q-ma-md q-gutter-md items-center">
      <q-select
        v-model="modelCode"
        :options="modelOptions"
        label="Model"
        emit-value
        map-options
        dense
        style="max-width: 380px"
      />
      <q-input
        v-if="isLlamaModel"
        v-model.number="llamaContextWindow"
        type="number"
        label="Context window"
        dense
        debounce="500"
        :min="1"
        style="max-width: 140px"
        @update:model-value="updateContextWindow"
      />
      <q-select
        v-model="personaSelection"
        :options="personaOptions"
        label="Persona"
        emit-value
        map-options
        dense
        style="min-width: 220px"
        @update:model-value="updatePersonaSelection"
      />
      <q-toggle
        v-model="useScaffolding"
        label="Scaffolding"
        @update:model-value="updateScaffoldingPreference"
        color="primary"
      />
      <q-toggle
        v-model="ragEnabled"
        label="Personal Context"
        @update:model-value="updateRagEnabled"
        color="primary"
      />
      <TtsControls
        :is-enabled="ttsPlayer.isEnabled.value"
        :is-playing="ttsPlayer.isPlaying.value"
        :is-paused="ttsPlayer.isPaused.value"
        :is-tts-available="ttsPlayer.isTtsAvailable.value"
        :current-voice="ttsPlayer.currentVoice.value"
        :speed="ttsPlayer.speed.value"
        :available-voices="ttsPlayer.availableVoices.value"
        @update:enabled="handleTtsEnabledChange"
        @update:voice="handleTtsVoiceChange"
        @update:speed="handleTtsSpeedChange"
        @pause="ttsPlayer.pause()"
        @resume="ttsPlayer.resume()"
        @stop="ttsPlayer.stop()"
      />
      <q-toggle
        v-model="voiceChatMode"
        label="Voice mode"
        color="primary"
      />
      <q-input
        v-if="voiceChatMode"
        v-model.number="endOfUtteranceMs"
        type="number"
        label="Pause (ms)"
        dense
        :min="500"
        style="max-width: 110px"
      />
    </div>

    <q-banner v-if="streamingChat.error.value" class="bg-negative text-white q-mx-md">
      <template v-slot:avatar>
        <q-icon name="error" color="white" />
      </template>
      <div class="text-body2">{{ streamingChat.error.value?.message || streamingChat.error.value }}</div>
      <template v-slot:action>
        <q-btn flat dense label="Retry" @click="handleRetry" color="white" />
        <q-btn flat dense label="Dismiss" @click="streamingChat.dismissError()" color="white" />
      </template>
    </q-banner>

    <div v-if="!hasMessages" class="new-chat-welcome column items-center q-pa-xl">
      <q-icon name="chat" size="80px" color="primary" class="q-mb-md" />
      <p class="text-subtitle1 text-grey-7 text-center" style="max-width: 500px">
        Ask me anything. I'm here to help.
      </p>
    </div>

    <div v-else ref="chatWindow" class="chat-window q-pa-md">
      <div v-for="(msg, i) in displayMessages" :key="msg.id || i" class="q-mb-md">
        <q-expansion-item
          v-if="msg.role === 'assistant' && (msg.thinking || isActivelyStreaming(i))"
          icon="psychology"
          v-model="expandedThinking[i]"
          header-class="thinking-header"
          class="q-mb-sm"
        >
          <q-card class="thinking-content">
            <q-card-section>
              <div v-if="!msg.thinking && isActivelyStreaming(i) && streamingChat.loadingPhase.value === 'connecting'" class="text-caption text-grey-6">
                <q-spinner color="grey-6" size="16px" class="q-mr-sm" />
                Connecting to AI...
              </div>
               <pre v-else-if="isActivelyStreaming(i)" class="thinking-raw">{{ msg.thinking }}</pre>
              <div v-else v-html="formatMessage(msg.thinking || '')" @click="handleMessageContentClick"></div>
              <q-spinner v-if="isActivelyStreaming(i) && streamingChat.loadingPhase.value === 'thinking'" color="primary" size="20px" class="q-mt-sm" />
              <div v-else-if="isActivelyStreaming(i) && streamingChat.loadingPhase.value === 'responding'" class="text-caption text-grey-6 q-mt-sm">
                Planning complete
              </div>
            </q-card-section>
          </q-card>
        </q-expansion-item>

        <div :class="msg.role" class="bubble q-pa-sm q-rounded-borders">
          <div v-if="!msg.content && isActivelyStreaming(i) && streamingChat.loadingPhase.value === 'connecting'" class="loading-placeholder">
            <div class="typing-indicator">
              <span class="dot"></span>
              <span class="dot"></span>
              <span class="dot"></span>
            </div>
          </div>
          <div v-else-if="msg.role === 'user' && editingMessageIndex === i">
            <q-input
              v-model="editingContent"
              type="textarea"
              autogrow
              dense
              class="edit-message"
              :disable="isSavingEdit"
              @keydown.ctrl.enter="saveEdit"
              @keydown.meta.enter="saveEdit"
              @keydown.esc="cancelEdit"
            />
            <div class="row q-mt-sm q-gutter-sm">
              <q-btn
                size="sm"
                color="primary"
                label="Save"
                :loading="isSavingEdit"
                @click="saveEdit"
              />
              <q-btn
                size="sm"
                flat
                label="Cancel"
                :disable="isSavingEdit"
                @click="cancelEdit"
              />
            </div>
          </div>
          <div v-else v-html="formatMessage(msg.content)" @click="handleMessageContentClick" />
          <q-spinner v-if="isActivelyStreaming(i) && msg.content" color="primary" size="20px" class="q-mt-sm" />

          <div class="message-footer" v-if="msg.role === 'assistant' || (msg.role === 'user' && !isActivelyStreaming(i) && editingMessageIndex !== i)">
            <template v-if="msg.role === 'assistant'">
              <q-btn
                flat
                dense
                round
                size="sm"
                icon="content_copy"
                class="copy-btn"
                @click="copyToClipboard(msg.content)"
              >
                <q-tooltip>Copy response</q-tooltip>
              </q-btn>
              <q-btn
                flat
                dense
                round
                size="sm"
                icon="autorenew"
                class="copy-btn"
                @click="regenerateMessage(displayMessages[i - 1]?.content, i)"
              >
                <q-tooltip>Regenerate response</q-tooltip>
              </q-btn>
              <q-btn
                v-if="ttsPlayer.isTtsAvailable.value"
                flat
                dense
                round
                size="sm"
                icon="volume_up"
                class="copy-btn"
                @click="readAloud(msg.content)"
                :disable="!msg.content || msg.content.trim().length === 0"
              >
                <q-tooltip>Read aloud</q-tooltip>
              </q-btn>
              <span v-if="msg.tokens_per_second" class="message-stats">
                {{ formatStats(msg) }}
              </span>
            </template>
            <template v-else-if="msg.role === 'user'">
              <q-btn
                flat
                dense
                round
                size="sm"
                icon="content_copy"
                class="copy-btn"
                @click="copyToClipboard(msg.content)"
              >
                <q-tooltip>Copy Message</q-tooltip>
              </q-btn>
              <q-btn
                flat
                dense
                round
                size="sm"
                icon="edit"
                class="edit-btn"
                @click="startEdit(i, msg)"
                :disable="streamingChat.isStreaming.value"
              >
                <q-tooltip>Edit message</q-tooltip>
              </q-btn>
            </template>
          </div>
        </div>
      </div>
    </div>

    <div class="input-bar q-pa-md row items-end input-centered">
      <SpeechToTextInput
        v-if="!voiceChatMode"
        v-model="input"
        :show-new-chat="hasMessages"
        @error="handleSttError"
        @status="handleSttStatus"
        @send-message="sendMessage"
        @new-chat="newChat"
        class="col message-input"
      />
      <VoiceChatInput
        v-else
        ref="voice"
        v-model="input"
        :show-new-chat="hasMessages"
        :end-of-utterance-ms="endOfUtteranceMs"
        @error="handleSttError"
        @status="handleSttStatus"
        @send-message="sendMessage"
        @new-chat="newChat"
        class="col message-input"
      />
    </div>

    <div v-if="isLlamaModel" class="context-usage q-mb-md">
      <q-circular-progress
        :value="contextUsageRatio * 100"
        size="32px"
        :thickness="0.2"
        color="#ffffd0"
        track-color="grey-3"
        show-value
        class="text-caption"
      >
        {{ Math.round(contextUsageRatio * 100) }}%
      </q-circular-progress>
      <div class="text-caption text-grey-7">
        {{ lastContextTokens.toLocaleString() }} / {{ llamaContextWindow.toLocaleString() }} tokens
      </div>
    </div>
  </q-page>
</template>

<script>
import { api } from 'boot/axios'
import { Marked } from 'marked'
import hljs from 'highlight.js'
import 'highlight.js/styles/base16/ashes.css' // highlightjs.org/examples
import SpeechToTextInput from 'components/SpeechToTextInput.vue'
import VoiceChatInput from 'components/VoiceChatInput.vue'
import TtsControls from 'components/TtsControls.vue'

const marked = new Marked({
  renderer: {
    code(token) {
      const rawLanguage = (token.lang || '').trim().toLowerCase()
      const language = hljs.getLanguage(rawLanguage) ? rawLanguage : 'plaintext'
      const label = rawLanguage || 'text'
      const code = token.text || ''
      const highlighted = hljs.highlight(code, { language }).value
      const encodedCode = encodeURIComponent(code)

      return `<div class="code-block-wrap"><div class="code-block-header"><span class="code-lang-label">${label}</span><button class="code-copy-btn" type="button" data-code="${encodedCode}" aria-label="Copy code" title="Copy code"><span class="material-icons notranslate" aria-hidden="true">content_copy</span></button></div><pre><code class="hljs language-${language}">${highlighted}</code></pre></div>`
    }
  }
})
import { useStreamingChat } from 'src/composables/useStreamingChat'
import { useTtsPlayer } from 'src/composables/useTtsPlayer'
import { onBeforeUnmount, onMounted} from 'vue'

const DEFAULT_MODEL_ID = import.meta.env.VITE_DEFAULT_MODEL_ID || null

export default {
  name: 'ChatPage',
  components: {
    SpeechToTextInput,
    VoiceChatInput,
    TtsControls
  },
  setup() {
    const streamingChat = useStreamingChat()
    const ttsPlayer = useTtsPlayer()

    onMounted(async () => {
      await ttsPlayer.checkAvailability()
    })

    onBeforeUnmount(() => {
      streamingChat.cleanup()
      ttsPlayer.stop()
    })

    return {
      streamingChat,
      ttsPlayer
    }
  },
  data: () => ({
    input: '',
    messages: [],
    conversationId: null,
    models: [],
    modelCode: null,
    streamingMessageIndex: null,
    expandedThinking: {},
    useScaffolding: true,
    usePersona: true,
    personaId: 'persona1',
    personas: [],
    ragEnabled: false,
    llamaContextWindow: 8192,
    editingMessageIndex: null,
    editingContent: '',
    isSavingEdit: false,
    voiceChatMode: false,
    endOfUtteranceMs: 2500
  }),
  async mounted() {
    const modelsRes = await api.get('/api/models')
    this.models = modelsRes.data.models
    if (!this.modelCode && this.models.length > 0) {
      this.modelCode = DEFAULT_MODEL_ID || String(this.models[0].id)
    }

    const userRes = await api.get('/api/user')
    this.useScaffolding = userRes.data.use_scaffolding
    this.usePersona = userRes.data.use_persona
    this.personaId = userRes.data.persona_id
    this.personas = userRes.data.personas || []
    this.llamaContextWindow = userRes.data.llama_context_window || 8192

    this.ttsPlayer.setEnabled(userRes.data.tts_enabled || false)
    this.ttsPlayer.setVoice(userRes.data.tts_voice || 'af_heart')
    this.ttsPlayer.setSpeed(userRes.data.tts_speed || 1.0)

    window.addEventListener('keydown', this.handleVoiceEscape)
  },
  beforeUnmount() {
    window.removeEventListener('keydown', this.handleVoiceEscape)
  },
  watch: {
    '$route.params.id': {
      immediate: true,
      async handler(newId) {
        if (newId) {
          this.conversationId = newId
          await this.loadConversation()
        } else {
          this.conversationId = null
          this.messages = []
          this.input = ''
          this.modelCode = DEFAULT_MODEL_ID
        }
      }
    },
    // Auto-scroll when messages change
    messages: {
      handler() {
        this.$nextTick(() => this.scrollToBottom())
      },
      deep: true
    },
    'streamingChat.thinkingText.value'(newThinking) {
      if (this.streamingMessageIndex !== null) {
        if (newThinking && !this.expandedThinking[this.streamingMessageIndex]) {
          this.expandedThinking[this.streamingMessageIndex] = true
        }
      }
    },
    'streamingChat.loadingPhase.value'(newPhase) {
      if (newPhase === 'responding' && this.streamingMessageIndex !== null) {
        const index = this.streamingMessageIndex
        setTimeout(() => {
          this.expandedThinking[index] = false
        }, 600)
      }
    },
    'streamingChat.responseText.value'(newText, oldText) {
      if (this.ttsPlayer.isEnabled.value && newText) {
        const newChunk = newText.slice(oldText?.length || 0)
        if (newChunk) {
          this.ttsPlayer.feedText(newChunk)
        }
      }
    },
    'streamingChat.isStreaming.value'(isStreaming) {
      // When streaming ends, flush any remaining buffered text
      if (!isStreaming && this.ttsPlayer.isEnabled.value) {
        this.ttsPlayer.flushBuffer()
      }
    },
    voiceShouldListen(newVal, oldVal) {
      if (newVal && !oldVal) {
        // Defer to next tick so the v-else VoiceChatInput is mounted and
        // $refs.voice is available (e.g. on initial toggle of voice mode).
        this.$nextTick(() => {
          this.$refs.voice?.startRecording().catch((err) => {
            this.$q?.notify?.({
              type: 'negative',
              message: `Mic error: ${err?.message || err}`,
              timeout: 3000
            })
          })
        })
      } else if (!newVal && oldVal) {
        this.$refs.voice?.stopRecording()
      }
    }
  },
  computed: {
    hasMessages() {
      return this.messages.length > 0
    },
    modelOptions() {
      return this.models.map(m => ({
        label: String(m.id),
        value: String(m.id)
      }))
    },
    personaOptions() {
      return [
        { label: 'Off', value: 'off' },
        ...this.personas.map(p => ({ label: p.name, value: p.id }))
      ]
    },
    personaSelection: {
      get() {
        return this.usePersona ? this.personaId : 'off'
      },
      set(value) {
        if (value === 'off') {
          this.usePersona = false
        } else {
          this.usePersona = true
          this.personaId = value
        }
      }
    },
    displayMessages() {
      return this.messages.map((msg, index) => {
        if (index === this.streamingMessageIndex && this.streamingChat.isStreaming.value) {
          return {
            ...msg,
            thinking: this.streamingChat.thinkingText.value,
            content: this.streamingChat.responseText.value
          }
        }
        return msg
      })
    },
    isLlamaModel() {
      const code = (this.modelCode || '').toLowerCase()
      return code.includes('llama') || code.includes('local') || code.endsWith('.gguf')
    },
    lastContextTokens() {
      for (let i = this.messages.length - 1; i >= 0; i--) {
        const msg = this.messages[i]
        if (msg.role === 'assistant' && msg.total_tokens) {
          return msg.total_tokens
        }
      }
      return 0
    },
    contextUsageRatio() {
      if (!this.llamaContextWindow) return 0
      return Math.min(1, Math.max(0, this.lastContextTokens / this.llamaContextWindow))
    },
    assistantBusy() {
      return this.streamingChat.isStreaming.value || this.ttsPlayer.isPlaying.value
    },
    voiceShouldListen() {
      return this.voiceChatMode && !this.assistantBusy && this.editingMessageIndex === null
    }
  },
  methods: {
    handleSttError(error) {
      console.error('Speech recognition error:', error)
      this.$q?.notify?.({
        type: 'negative',
        message: `Mic error: ${error.message || error}`,
        timeout: 3000
      })
    },
    handleSttStatus(status) {
      console.log('Speech status:', status)
    },
    handleRetry() {
      this.streamingChat.retryLastMessage()
    },
    handleVoiceEscape(event) {
      if (event.key !== 'Escape') return
      if (!this.voiceChatMode) return
      if (this.editingMessageIndex !== null) return
      if (!this.streamingChat.isStreaming.value && !this.ttsPlayer.isPlaying.value) return

      event.preventDefault()
      this.streamingChat.cleanup()
      this.ttsPlayer.stop()
      this.$nextTick(() => {
        this.$refs.voice?.startRecording().catch((err) => {
          this.$q?.notify?.({
            type: 'negative',
            message: `Mic error: ${err?.message || err}`,
            timeout: 3000
          })
        })
      })
    },
    getLoadingText() {
      const phase = this.streamingChat.loadingPhase.value
      switch (phase) {
        case 'connecting':
          return 'Connecting...'
        case 'thinking':
          return 'Analyzing your request...'
        case 'responding':
          return 'Generating response...'
        default:
          return 'Processing...'
      }
    },
    newChat() {
      if (this.$route.params.id) {
        this.$router.push('/chat')
      } else {
        this.conversationId = null
        this.messages = []
        this.input = ''
        this.modelCode = DEFAULT_MODEL_ID
      }
    },
    async loadConversation() {
      try {
        const res = await api.get(`/api/conversations/${this.conversationId}`)
        this.messages = res.data.messages
        this.modelCode = res.data.model_code || DEFAULT_MODEL_ID
        this.ragEnabled = res.data.rag_enabled || false
      } catch (err) {
        console.error('Error loading conversation', err)
      }
    },
    async updateRagEnabled(value) {
      if (!this.conversationId) return  // toggle is remembered locally; applied on first send
      try {
        await api.patch(`/api/conversations/${this.conversationId}`, {
          conversation: { rag_enabled: value }
        })
      } catch (err) {
        console.error('Error updating RAG setting:', err)
        this.ragEnabled = !value
        this.$q.notify({
          type: 'negative',
          message: 'Failed to update Personal Context setting',
          position: 'top',
          timeout: 2000
        })
      }
    },
    async sendMessage() {
      const text = this.input.trim()
      const model = this.modelCode

      if (!text) return

      // Stop any current TTS playback
      if (this.ttsPlayer.isEnabled.value) {
        this.ttsPlayer.stop()
      }

      const isNew = !this.conversationId

      if (isNew) {
        const convRes = await api.post('/api/conversations')
        this.conversationId = convRes.data.id
        if (this.ragEnabled) {
          await api.patch(`/api/conversations/${this.conversationId}`, {
            conversation: { rag_enabled: true }
          })
        }
      }

      // Add user message immediately (optimistic UI)
      this.messages.push({
        role: 'user',
        content: text
      })
      this.input = ''

      // Add placeholder for incoming stream
      this.streamingMessageIndex = this.messages.length
      this.messages.push({
        role: 'assistant',
        content: '',
        thinking: ''
      })

      const token = localStorage.getItem('jwt')

      // Stream the response (composable handles state, computed merges into display)
      await this.streamingChat.sendMessage(
        this.conversationId,
        text,
        token,
        model
      )

      // Update placeholder message with final content from composable
      const streamedMessage = this.messages[this.streamingMessageIndex]
      streamedMessage.thinking = this.streamingChat.thinkingText.value
      streamedMessage.content = this.streamingChat.responseText.value
      const finalStats = this.streamingChat.stats.value
      if (finalStats) {
        streamedMessage.total_tokens = finalStats.total_tokens
        streamedMessage.tokens_per_second = finalStats.tokens_per_second
        streamedMessage.generation_ms = finalStats.generation_ms
      }

      if (this.streamingChat.error.value) {
        // Remove the failed placeholder message
        this.messages.splice(this.streamingMessageIndex, 1)
      }

      this.streamingMessageIndex = null

      if (isNew && this.$route.params.id !== String(this.conversationId)) {
        this.$router.replace(`/chat/${this.conversationId}`)
      }
    },
    scrollToBottom() {
      const el = this.$refs.chatWindow
      if (el) el.scrollTop = el.scrollHeight
    },
    isActivelyStreaming(index) {
      return index === this.streamingMessageIndex && this.streamingChat.isStreaming.value
    },
    formatMessage(text) {
      return marked.parse(text)
    },

    async copyTextWithFallback(text, successMessage) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(text)
      } else {
        const textArea = document.createElement('textarea')
        textArea.value = text
        textArea.style.position = 'fixed'
        textArea.style.left = '-999999px'
        document.body.appendChild(textArea)
        textArea.select()
        document.execCommand('copy')
        document.body.removeChild(textArea)
      }

      this.$q.notify({
        type: 'positive',
        message: successMessage,
        position: 'top',
        timeout: 2000
      })
    },

    async handleMessageContentClick(event) {
      const button = event.target.closest('.code-copy-btn')

      if (!button) return

      const encodedCode = button.getAttribute('data-code')
      const code = decodeURIComponent(encodedCode || '')

      await this.copyTextWithFallback(code, 'Copied to clipboard')

      const originalHtml = button.innerHTML
      button.innerHTML = '<span class="material-icons notranslate" aria-hidden="true">check</span>'
      button.disabled = true

      setTimeout(() => {
        button.innerHTML = originalHtml
        button.disabled = false
      }, 1200)
    },

    async copyToClipboard(text, toastMessage = 'Copied to clipboard') {
      await this.copyTextWithFallback(text, toastMessage)
    },

    formatStats(msg) {
      const total = msg.total_tokens != null ? msg.total_tokens.toLocaleString() : '?'
      const tps = msg.tokens_per_second != null ? msg.tokens_per_second.toFixed(1) : '?'
      return `${total} tokens · ${tps} tok/s`
    },

    async updateScaffoldingPreference(value) {
      try {
        await api.patch('/api/user', {
          user: { use_scaffolding: value }
        })
      } catch (err) {
        console.error('Error updating scaffolding preference:', err)
        this.useScaffolding = !value
        this.$q.notify({
          type: 'negative',
          message: 'Failed to update preference',
          position: 'top',
          timeout: 2000
        })
      }
    },

    async updateContextWindow(value) {
      const intValue = Number.parseInt(value, 10)
      if (!Number.isFinite(intValue) || intValue <= 0) return
      try {
        await api.patch('/api/user', {
          user: { llama_context_window: intValue }
        })
        this.llamaContextWindow = intValue
      } catch (err) {
        console.error('Error updating context window:', err)
        this.$q.notify({
          type: 'negative',
          message: 'Failed to update context window',
          position: 'top',
          timeout: 2000
        })
      }
    },

    async updatePersonaSelection(value) {
      const prevUsePersona = value === 'off' ? true : this.usePersona
      const prevPersonaId = this.personaId
      const payload = value === 'off'
        ? { use_persona: false }
        : { use_persona: true, persona_id: value }
      try {
        await api.patch('/api/user', { user: payload })
      } catch (err) {
        console.error('Error updating persona preference:', err)
        this.usePersona = prevUsePersona
        this.personaId = prevPersonaId
        this.$q.notify({
          type: 'negative',
          message: 'Failed to update preference',
          position: 'top',
          timeout: 2000
        })
      }
    },

    async handleTtsEnabledChange(value) {
      this.ttsPlayer.setEnabled(value)
      await this.updateTtsPreference({ tts_enabled: value })
    },

    async handleTtsVoiceChange(value) {
      this.ttsPlayer.setVoice(value)
      await this.updateTtsPreference({ tts_voice: value })
    },

    async handleTtsSpeedChange(value) {
      this.ttsPlayer.setSpeed(value)
      await this.updateTtsPreference({ tts_speed: value })
    },

    async updateTtsPreference(prefs) {
      try {
        await api.patch('/api/user', {
          user: prefs
        })
      } catch (err) {
        console.error('Error updating TTS preference:', err)
        this.$q.notify({
          type: 'negative',
          message: 'Failed to update TTS preference',
          position: 'top',
          timeout: 2000
        })
      }
    },

    async readAloud(text) {
      if (!text || text.trim().length === 0) return

      try {
        await this.ttsPlayer.speak(text)
      } catch (err) {
        console.error('Error reading aloud:', err)
        this.$q.notify({
          type: 'negative',
          message: 'Failed to read aloud',
          position: 'top',
          timeout: 2000
        })
      }
    },

    startEdit(index, message) {
      this.editingMessageIndex = index
      this.editingContent = message.content
    },

    cancelEdit() {
      this.editingMessageIndex = null
      this.editingContent = ''
    },

    async saveEdit() {
      if (!this.editingContent.trim() || this.isSavingEdit) return

      const messageIndex = this.editingMessageIndex
      let message = this.messages[messageIndex]

      if (!message.id) {
        await this.loadConversation()
        message = this.messages[messageIndex]
      }

      this.isSavingEdit = true

      try {
        await api.patch(
          `/api/conversations/${this.conversationId}/messages/${message.id}`,
          { content: this.editingContent }
        )

        message.content = this.editingContent

        // Remove all messages after the edited one
        this.messages = this.messages.slice(0, messageIndex + 1)

        await this.regenerateFromMessage(this.editingContent)

        this.editingMessageIndex = null
        this.editingContent = ''

      } catch (err) {
        console.error('Error updating message:', err)
        this.$q.notify({
          type: 'negative',
          message: 'Failed to update message',
          position: 'top',
          timeout: 2000
        })
      } finally {
        this.isSavingEdit = false
      }
    },

    async regenerateMessage(message, messageIndex) {
      if (!message) return
      this.messages = this.messages.slice(0, messageIndex)
      this.regenerateFromMessage(message)
    },
    async regenerateFromMessage(userMessageContent) {
      // Add placeholder for incoming stream
      this.streamingMessageIndex = this.messages.length
      this.messages.push({
        role: 'assistant',
        content: '',
        thinking: ''
      })

      const token = localStorage.getItem('jwt')

      // Stream the new response
      await this.streamingChat.sendMessage(
        this.conversationId,
        userMessageContent,
        token,
        this.modelCode,
        { regenerating: true }
      )

      // Update placeholder with final content
      const streamedMessage = this.messages[this.streamingMessageIndex]
      streamedMessage.thinking = this.streamingChat.thinkingText.value
      streamedMessage.content = this.streamingChat.responseText.value

      if (this.streamingChat.error.value) {
        this.messages.splice(this.streamingMessageIndex, 1)
      }

      this.streamingMessageIndex = null
    }
  }
}
</script>

<style scoped>
.chat-window {
  flex: 1;
  overflow-y: auto;
}
.bubble {
  color: var(--text);
  max-width: 60%;
  line-height: 1.5;
  border-radius: 5px;
  position: relative;
}
.message-footer {
  display: flex;
  align-items: center;
  justify-content: flex-start;
  margin-top: 8px;
  padding-top: 4px;
}
.message-stats {
  margin-left: 8px;
  font-size: 0.75rem;
  opacity: 0.55;
  white-space: nowrap;
}
.copy-btn {
  opacity: 0.6;
  transition: opacity 0.2s;
}
.copy-btn:hover {
  opacity: 1;
}
.edit-btn {
  opacity: 0.6;
  transition: opacity 0.2s;
}
.edit-btn:hover {
  opacity: 1;
}
.user {
  background: var(--bubble-user);
  color: var(--text-user);
  margin: 40px 5px 40px auto;
  justify-content: start;
  align-items: center;
  padding: 15px 25px;
}
p {
  margin: 0 !important;
  margin-bottom: 0 !important;
}
.thinking-header {
  background-color: #f5f5f5;
  border-left: 3px solid #2196F3;
  font-size: 0.9em;
  opacity: 0.8;
}
.thinking-content {
  background-color: #201d12;
  font-family: monospace;
  font-size: 0.85em;
  color: #c7c7c7;
  border-radius: 3px;
}
.thinking-content code {
  background-color: #2a271a !important;
}
.thinking-raw {
  white-space: pre-wrap;
  font-family: monospace;
  font-size: 0.85em;
  color: #c7c7c7;
  margin: 0;
}
.assistant {
  box-shadow: 0 1px 3px rgba(0,0,0,0.05);
  margin: 40px auto;
  max-width: 900px;
}
.input-bar {
  border-top: 1px solid var(--border);
}
.input-centered {
  border-top: none;
  justify-content: center;
}
.message-input {
  max-width: 900px;
}
.context-usage {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 0 16px;
}
.message-input :deep(.q-field__control) {
  border-radius: 15px;
}
.message-input :deep(.q-field__control textarea) {
  font-size: 16px;
}
.message-input :deep(.q-field__control:after) {
  display: none;
}
.message-input :deep(.q-field__control:before) {
  display: none;
}
.new-chat-welcome {
  text-align: center;
}
.assistant :deep(.code-block-wrap) {
  margin: 10px 0;
}
.assistant :deep(.code-block-header) {
  align-items: center;
  display: flex;
  font-family: monospace;
  font-size: 0.75em;
  justify-content: space-between;
  margin-bottom: -8px;
  padding: 0 5px;
}
.assistant :deep(.code-lang-label) {
  opacity: 0.75;
  text-transform: lowercase;
}
.assistant :deep(.code-copy-btn) {
  background: none;
  border: none;
  color: inherit;
  cursor: pointer;
  display: inline-flex;
  font: inherit;
  line-height: 1;
  opacity: 0.8;
  padding: 0;
}
.assistant :deep(.code-copy-btn .material-icons) {
  font-size: 1em;
}
.assistant :deep(.code-copy-btn:disabled) {
  cursor: default;
  opacity: 0.6;
}
.assistant pre {
  background: var(--bubble-ai);
  padding: 8px 10px;
  border-radius: 6px;
  overflow-x: auto;
  font-family: monospace;
  font-size: 0.9em;
}
.assistant :deep(.code-block-wrap pre) {
  scrollbar-width: thin;
  scrollbar-color: var(--border) var(--bubble-ai);
}
.assistant :deep(.code-block-wrap pre::-webkit-scrollbar) {
  height: 10px;
  width: 10px;
}
.assistant :deep(.code-block-wrap pre::-webkit-scrollbar-track) {
  background: var(--bubble-ai);
}
.assistant :deep(.code-block-wrap pre::-webkit-scrollbar-thumb) {
  background: var(--border);
  border: 2px solid var(--bubble-ai);
  border-radius: 999px;
}
.assistant code {
  background: #f6f8fa;
  padding: 2px 4px;
  border-radius: 4px;
}
.loading-placeholder {
  min-height: 40px;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: flex-start;
}
.typing-indicator {
  display: flex;
  align-items: center;
  gap: 6px;
}
.typing-indicator .dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background-color: #1976d2;
  opacity: 0.4;
  animation: pulse 1.4s infinite ease-in-out;
}
.typing-indicator .dot:nth-child(1) {
  animation-delay: 0s;
}
.typing-indicator .dot:nth-child(2) {
  animation-delay: 0.2s;
}
.typing-indicator .dot:nth-child(3) {
  animation-delay: 0.4s;
}
.edit-message {
  background-color: #555550;
  color: #1c1c1c !important;
  border-radius: 5px;
  padding: 10px;
}
@keyframes pulse {
  0%, 60%, 100% {
    opacity: 0.4;
    transform: scale(1);
  }
  30% {
    opacity: 1;
    transform: scale(1.2);
  }
}
</style>

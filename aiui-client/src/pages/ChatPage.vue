<template>
  <q-page class="column chat-page">
    <div
      class="row q-ma-none q-gutter-md items-center toolbar-wrap"
      :class="{ 'toolbar-collapsed': !toolbarExpanded }"
      @mouseenter="toolbarHovered = true"
      @mouseleave="toolbarHovered = false"
    >
      <q-select
        v-model="modelCode"
        :options="modelOptions"
        label="Model"
        emit-value
        map-options
        dense
        style="max-width: 380px"
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
        label="Context"
        @update:model-value="updateRagEnabled"
        color="primary"
      />
      <TtsControls
        :show="voiceChatMode"
        :is-playing="ttsPlayer.isPlaying.value"
        :is-paused="ttsPlayer.isPaused.value"
        :current-voice="ttsPlayer.currentVoice.value"
        :speed="ttsPlayer.speed.value"
        :available-voices="ttsPlayer.availableVoices.value"
        @update:voice="handleTtsVoiceChange"
        @update:speed="handleTtsSpeedChange"
        @pause="ttsPlayer.pause()"
        @resume="ttsPlayer.resume()"
        @stop="ttsPlayer.stop()"
      />
      <div v-if="voiceChatMode" class="row items-center q-gutter-sm" style="min-width: 220px">
        <span class="text-caption text-grey-7">Pause</span>
        <q-slider
          v-model="endOfUtteranceMs"
          :min="1000"
          :max="10000"
          :step="500"
          color="primary"
          style="width: 160px"
        />
        <span class="text-caption text-grey-7" style="min-width: 34px">
          {{ (endOfUtteranceMs / 1000).toFixed(1) + 's' }}
        </span>
      </div>
      <div v-if="voiceChatMode" class="row items-center q-gutter-sm" style="min-width: 220px">
        <span class="text-caption text-grey-7">Timeout</span>
        <q-slider
          v-model="inactivityTimeoutSec"
          :min="5"
          :max="65"
          :step="5"
          color="primary"
          style="width: 160px"
        />
        <span class="text-caption text-grey-7" style="min-width: 34px">
          {{ inactivityTimeoutSec > 60 ? 'Off' : inactivityTimeoutSec + 's' }}
        </span>
      </div>
      <div v-if="isLlamaModel && hasMessages" class="context-usage">
        <q-circular-progress
          :value="contextUsageRatio * 100"
          size="32px"
          :thickness="0.2"
          color="primary"
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
      <video
        src="/media/15089605_960_540_24fps.mp4"
        autoplay
        loop
        muted
        playsinline
        class="q-mb-md welcome-video"
        @loadedmetadata="$event.target.playbackRate = 3"
      />
      <p class="text-subtitle1 text-grey-7 text-center" style="max-width: 500px">
        Ask me anything. I'm here to help.
      </p>
    </div>

    <div v-else ref="chatWindow" class="chat-window q-pa-md" @scroll.passive="onChatScroll">
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
          <div v-else-if="msg.failed && !msg.content" class="failed-message text-negative">
            <q-icon name="error_outline" size="18px" class="q-mr-xs" />
            Failed to generate a response.
          </div>
          <div v-else v-html="msg.role === 'user' ? formatUserMessage(msg.content) : formatMessage(msg.content)" @click="handleMessageContentClick" />
          <q-spinner v-if="isActivelyStreaming(i) && msg.content" color="primary" size="20px" class="q-mt-sm" />

          <div class="message-footer" v-if="msg.role === 'assistant' || (msg.role === 'user' && !isActivelyStreaming(i) && editingMessageIndex !== i)">
            <template v-if="msg.role === 'assistant'">
              <q-btn
                v-if="msg.content"
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
                :icon="readingAloudIndex === i ? 'stop' : 'volume_up'"
                :color="readingAloudIndex === i ? 'negative' : undefined"
                class="copy-btn"
                @click="readingAloudIndex === i ? stopReadAloud() : readAloud(msg.content, i)"
                :disable="!msg.content || msg.content.trim().length === 0"
              >
                <q-tooltip>{{ readingAloudIndex === i ? 'Stop' : 'Read aloud' }}</q-tooltip>
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
              >
                <q-tooltip>Edit message</q-tooltip>
              </q-btn>
              <q-btn
                v-if="i === displayMessages.length - 1"
                flat
                dense
                round
                size="sm"
                icon="autorenew"
                class="copy-btn"
                @click="regenerateMessage(msg.content, i + 1)"
              >
                <q-tooltip>Retry</q-tooltip>
              </q-btn>
            </template>
          </div>
        </div>
      </div>
    </div>

    <div class="input-bar q-pa-none row items-end input-centered" :class="{ 'input-bar-centered': !hasMessages }">
      <SpeechToTextInput
        v-if="!voiceChatMode"
        v-model="input"
        :show-new-chat="hasMessages"
        :is-streaming="streamingChat.isStreaming.value"
        :expanded="composerExpanded"
        :context-usage="composerContextPercent"
        :context-label="composerContextLabel"
        :voice-mode="voiceChatMode"
        @error="handleSttError"
        @status="handleSttStatus"
        @send-message="sendMessage"
        @stop="stopStreaming"
        @new-chat="newChat"
        @toggle-voice-mode="toggleVoiceMode"
        class="col message-input"
      />
      <VoiceChatInput
        v-else
        ref="voice"
        v-model="input"
        :show-new-chat="hasMessages"
        :is-streaming="streamingChat.isStreaming.value"
        :expanded="composerExpanded"
        :context-usage="composerContextPercent"
        :context-label="composerContextLabel"
        :end-of-utterance-ms="endOfUtteranceMs"
        :inactivity-timeout-ms="inactivityTimeoutMs"
        :muted="!ttsPlayer.isEnabled.value"
        :tts-available="ttsPlayer.isTtsAvailable.value"
        :voice-mode="voiceChatMode"
        @error="handleSttError"
        @status="handleSttStatus"
        @send-message="sendMessage"
        @stop="stopStreaming"
        @new-chat="newChat"
        @toggle-mute="handleToggleMute"
        @toggle-voice-mode="toggleVoiceMode"
        @inactivity-timeout="handleVoiceInactivityTimeout"
        class="col message-input"
      />
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

const codeRenderer = {
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

const marked = new Marked({ renderer: codeRenderer })

// User messages reuse the same renderer but disable indented code blocks, so
// pasted prose with indented paragraphs isn't mistaken for a code block.
// Fenced ``` blocks still work — those go through the separate `fences` tokenizer.
const markedUser = new Marked({
  renderer: codeRenderer,
  tokenizer: {
    code() { return undefined }
  }
})
import { useStreamingChat } from 'src/composables/useStreamingChat'
import { useTtsPlayer } from 'src/composables/useTtsPlayer'
import { onBeforeUnmount, onMounted} from 'vue'

const DEFAULT_MODEL_ID = import.meta.env.VITE_DEFAULT_MODEL_ID || null

const COMPOSER_EXPAND_AT_PX = 16
const COMPOSER_COLLAPSE_AT_PX = 140

export default {
  name: 'ChatPage',
  components: {
    SpeechToTextInput,
    VoiceChatInput,
    TtsControls
  },
  inject: {
    refreshConversations: { default: () => () => {} }
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
    atBottom: true,
    atTop: true,
    toolbarHovered: false,
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
    readingAloudIndex: null,
    endOfUtteranceMs: 2500,
    inactivityTimeoutSec: 15,
    armTimer: null
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

    // Live context window from llama.cpp is authoritative; the stored value above is only the fallback.
    if (this.isLlamaModel) await this.fetchLlamaContext()

    // TTS output now follows voice mode (off until voice mode is enabled).
    this.ttsPlayer.setVoice(userRes.data.tts_voice || 'af_heart')
    this.ttsPlayer.setSpeed(userRes.data.tts_speed || 1.0)

    window.addEventListener('keydown', this.handleVoiceEscape)
  },
  beforeUnmount() {
    window.removeEventListener('keydown', this.handleVoiceEscape)
    this.cancelArm()
  },
  watch: {
    modelCode() {
      if (this.isLlamaModel) this.fetchLlamaContext()
    },
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
    atBottom(val) {
      // re-pin so the taller composer doesn't hide the last message
      if (val) this.$nextTick(() => this.scrollToBottom())
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
    'ttsPlayer.isPlaying.value'(playing) {
      // Revert the per-message read-aloud button once playback stops.
      if (!playing) this.readingAloudIndex = null
    },
    voiceShouldListen(newVal, oldVal) {
      if (newVal && !oldVal) {
        this.scheduleArm()
      } else if (!newVal && oldVal) {
        this.cancelArm()
        this.$refs.voice?.stopRecording()
      }
    }
  },
  computed: {
    hasMessages() {
      return this.messages.length > 0
    },
    composerExpanded() {
      if (!this.hasMessages) return true
      return this.atBottom && !this.streamingChat.isStreaming.value
    },
    toolbarExpanded() {
      if (!this.hasMessages) return true
      return this.atTop || this.toolbarHovered
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
    composerContextPercent() {
      if (!this.isLlamaModel || !this.hasMessages) return null
      return Math.round(this.contextUsageRatio * 100)
    },
    composerContextLabel() {
      if (this.composerContextPercent === null) return null
      return `${this.lastContextTokens.toLocaleString()} / ${this.llamaContextWindow.toLocaleString()}`
    },
    assistantBusy() {
      return this.streamingChat.isStreaming.value || this.ttsPlayer.isPlaying.value
    },
    voiceShouldListen() {
      return this.voiceChatMode && !this.assistantBusy && this.editingMessageIndex === null
    },
    inactivityTimeoutMs() {
      // The slider's top position (> 60 s) means "off" — pass 0 to disable.
      return this.inactivityTimeoutSec > 60 ? 0 : this.inactivityTimeoutSec * 1000
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
    // Debounce the start so a brief assistant-busy flicker can't flap the mic.
    scheduleArm() {
      this.cancelArm()
      this.armTimer = setTimeout(() => {
        this.armTimer = null
        if (!this.voiceShouldListen) return
        this.$nextTick(() => {
          this.$refs.voice?.startRecording().catch((err) => {
            this.$q?.notify?.({
              type: 'negative',
              message: `Mic error: ${err?.message || err}`,
              timeout: 3000
            })
          })
        })
      }, 300)
    },
    cancelArm() {
      if (this.armTimer) {
        clearTimeout(this.armTimer)
        this.armTimer = null
      }
    },
    handleRetry() {
      this.streamingChat.retryLastMessage()
    },
    stopStreaming() {
      // Commit whatever streamed so far before flipping isStreaming off, so the
      // visible text doesn't briefly flash to empty.
      if (this.streamingMessageIndex !== null) {
        const msg = this.messages[this.streamingMessageIndex]
        msg.thinking = this.streamingChat.thinkingText.value
        msg.content = this.streamingChat.responseText.value
      }
      this.streamingChat.stop()
    },
    handleVoiceEscape(event) {
      if (event.key !== 'Escape') return
      if (!this.voiceChatMode) return
      if (this.editingMessageIndex !== null) return
      if (!this.streamingChat.isStreaming.value && !this.ttsPlayer.isPlaying.value) return

      event.preventDefault()
      this.streamingChat.stop()
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
      const myIndex = this.messages.length
      this.streamingMessageIndex = myIndex
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
      const streamedMessage = this.messages[myIndex]
      streamedMessage.thinking = this.streamingChat.thinkingText.value
      streamedMessage.content = this.streamingChat.responseText.value
      const finalStats = this.streamingChat.stats.value
      if (finalStats) {
        streamedMessage.total_tokens = finalStats.total_tokens
        streamedMessage.tokens_per_second = finalStats.tokens_per_second
        streamedMessage.generation_ms = finalStats.generation_ms
      }

      if (this.streamingChat.error.value) {
        // Keep the placeholder for a regenerate button.
        streamedMessage.failed = true
      }

      // Only clear the shared index if a newer send hasn't taken it over.
      if (this.streamingMessageIndex === myIndex) {
        this.streamingMessageIndex = null
      }

      if (isNew && this.$route.params.id !== String(this.conversationId)) {
        this.$router.replace(`/chat/${this.conversationId}`)
      }

      this.refreshConversations()
    },
    scrollToBottom() {
      const el = this.$refs.chatWindow
      if (el) el.scrollTop = el.scrollHeight
    },
    onChatScroll() {
      const el = this.$refs.chatWindow
      if (!el) return
      this.atTop = el.scrollTop <= 8
      const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight
      if (this.atBottom && distanceFromBottom > COMPOSER_COLLAPSE_AT_PX) {
        this.atBottom = false
      } else if (!this.atBottom && distanceFromBottom <= COMPOSER_EXPAND_AT_PX) {
        this.atBottom = true
      }
    },
    isActivelyStreaming(index) {
      return index === this.streamingMessageIndex && this.streamingChat.isStreaming.value
    },
    formatMessage(text) {
      return marked.parse(text)
    },
    formatUserMessage(text) {
      return markedUser.parse(text)
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

    async fetchLlamaContext() {
      try {
        const res = await api.get('/api/models/llama_context')
        if (res.data.n_ctx) this.llamaContextWindow = res.data.n_ctx
      } catch (err) {
        console.error('Error fetching llama context window:', err)
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

    // Voice-mode button in the composer.
    toggleVoiceMode() {
      const next = !this.voiceChatMode
      this.voiceChatMode = next
      this.handleVoiceModeChange(next)
    },

    // Voice mode owns TTS output: entering it turns voice output on by default.
    async handleVoiceModeChange(value) {
      this.ttsPlayer.setEnabled(value)
      await this.updateTtsPreference({ tts_enabled: value })
    },

    // Silence timeout: leave voice mode instead of stranding the mic off in it.
    handleVoiceInactivityTimeout() {
      this.voiceChatMode = false
      this.handleVoiceModeChange(false)
    },

    // Mute button in the composer: toggle voice output without leaving voice mode.
    async handleToggleMute() {
      const enabled = !this.ttsPlayer.isEnabled.value
      this.ttsPlayer.setEnabled(enabled)
      await this.updateTtsPreference({ tts_enabled: enabled })
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

    async readAloud(text, index) {
      if (!text || text.trim().length === 0) return

      // Stop current playback; the isPlaying watcher clears the old index first.
      this.ttsPlayer.stop()
      await this.$nextTick()
      this.readingAloudIndex = index

      try {
        await this.ttsPlayer.speak(text)
      } catch (err) {
        console.error('Error reading aloud:', err)
        this.readingAloudIndex = null
        this.$q.notify({
          type: 'negative',
          message: 'Failed to read aloud',
          position: 'top',
          timeout: 2000
        })
      }
    },

    stopReadAloud() {
      this.ttsPlayer.stop()
      this.readingAloudIndex = null
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

      if (this.streamingChat.isStreaming.value) {
        this.streamingChat.stop()
      }

      const messageIndex = this.editingMessageIndex
      const newContent = this.editingContent
      let message = this.messages[messageIndex]

      if (!message.id) {
        await this.loadConversation()
        message = this.messages[messageIndex]
      }

      this.isSavingEdit = true

      try {
        await api.patch(
          `/api/conversations/${this.conversationId}/messages/${message.id}`,
          { content: newContent }
        )
      } catch (err) {
        console.error('Error updating message:', err)
        this.$q.notify({
          type: 'negative',
          message: 'Failed to update message',
          position: 'top',
          timeout: 2000
        })
        this.isSavingEdit = false
        return
      }

      message.content = newContent

      // Remove all messages after the edited one
      this.messages = this.messages.slice(0, messageIndex + 1)

      this.editingMessageIndex = null
      this.editingContent = ''
      this.isSavingEdit = false

      this.regenerateFromMessage(newContent)
    },

    async regenerateMessage(message, messageIndex) {
      if (!message) return
      this.messages = this.messages.slice(0, messageIndex)
      this.regenerateFromMessage(message)
    },
    async regenerateFromMessage(userMessageContent) {
      // Add placeholder for incoming stream
      const myIndex = this.messages.length
      this.streamingMessageIndex = myIndex
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
      const streamedMessage = this.messages[myIndex]
      streamedMessage.thinking = this.streamingChat.thinkingText.value
      streamedMessage.content = this.streamingChat.responseText.value

      if (this.streamingChat.error.value) {
        streamedMessage.failed = true
      }

      if (this.streamingMessageIndex === myIndex) {
        this.streamingMessageIndex = null
      }

      this.refreshConversations()
    }
  }
}
</script>

<style scoped>
.chat-page {
  height: 100vh;
  overflow: hidden;
}
.toolbar-wrap {
  overflow: hidden;
  transition: max-height 0.25s ease;
  max-height: 300px;
}
.toolbar-wrap.toolbar-collapsed {
  max-height: 12px;
}
.chat-window {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  scrollbar-width: thin;
  scrollbar-color: var(--border) transparent;
}
.chat-window::-webkit-scrollbar {
  width: 10px;
}
.chat-window::-webkit-scrollbar-track {
  background: transparent;
}
.chat-window::-webkit-scrollbar-thumb {
  background: var(--border);
  border-radius: 999px;
  border: 2px solid transparent;
  background-clip: padding-box;
}
.chat-window::-webkit-scrollbar-thumb:hover {
  background: var(--text-subtle);
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
.failed-message {
  display: flex;
  align-items: center;
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
.input-bar-centered {
  margin-bottom: auto;
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
  border-radius: 25px;
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
.welcome-video {
  width: 280px;
  height: auto;
  mix-blend-mode: screen;
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

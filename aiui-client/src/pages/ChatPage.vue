<template>
  <q-page class="column" :class="justify-center">
    <q-select
      v-model="modelCode"
      :options="modelOptions"
      label="Model"
      emit-value
      map-options
      class="q-ma-md"
      style="max-width: 380px"
    />

    <q-banner v-if="streamingChat.error.value" class="bg-negative text-white q-mx-md">
      <template v-slot:avatar>
        <q-icon name="error" color="white" />
      </template>
      <div class="text-body2">{{ streamingChat.error.value }}</div>
      <template v-slot:action>
        <q-btn flat dense label="Retry" @click="handleRetry" color="white" />
        <q-btn flat dense label="Dismiss" @click="streamingChat.dismissError()" color="white" />
      </template>
    </q-banner>

    <div v-if="!hasMessages" class="new-chat-welcome column items-center q-pa-xl">
      <q-icon name="chat" size="80px" color="primary" class="q-mb-md" />
      <h4 class="text-h4 q-mt-none q-mb-md">Start a New Conversation</h4>
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
              <div v-else v-html="formatMessage(msg.thinking || '')"></div>
              <q-spinner v-if="isActivelyStreaming(i) && streamingChat.thinkingText.value" color="primary" size="20px" class="q-mt-sm" />
            </q-card-section>
          </q-card>
        </q-expansion-item>

        <div :class="msg.role" class="bubble q-pa-sm q-rounded-borders">
          <div v-html="formatMessage(msg.content)" />
          <div class="message-footer" v-if="msg.role === 'assistant'">
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
          </div>
          <div v-if="!msg.content && isActivelyStreaming(i) && streamingChat.loadingPhase.value === 'connecting'" class="loading-placeholder">
            <div class="typing-indicator">
              <span class="dot"></span>
              <span class="dot"></span>
              <span class="dot"></span>
            </div>
          </div>
          <div v-else v-html="formatMessage(msg.content)" />
          <q-spinner v-if="isActivelyStreaming(i) && msg.content" color="primary" size="20px" class="q-mt-sm" />
        </div>
      </div>
    </div>

    <div class="input-bar q-pa-md row items-end input-centered">
      <q-input
        filled
        autogrow
        v-model="input"
        placeholder="Send a message..."
        class="col message-input"
        type="textarea"
        :input-style="{ minHeight: '90px' }"
        @keyup.enter.exact="sendMessage"
      />
      <q-btn icon="send" color="primary" round flat @click="sendMessage" />
      <q-btn v-if="hasMessages" icon="add" color="secondary" round flat @click="newChat" />
    </div>
  </q-page>
</template>

<script>
import { api } from 'boot/axios'
import { marked } from 'marked'
import { useStreamingChat } from 'src/composables/useStreamingChat'
import { onBeforeUnmount} from 'vue'

const DEFAULT_MODEL_ID = import.meta.env.VITE_DEFAULT_MODEL_ID || null

export default {
  name: 'ChatPage',
  setup() {
    const streamingChat = useStreamingChat()

    onBeforeUnmount(() => {
      streamingChat.cleanup()
    })

    return {
      streamingChat
    }
  },
  data: () => ({
    input: '',
    messages: [],
    conversationId: null,
    models: [],
    modelCode: null,
    streamingMessageIndex: null,
    expandedThinking: {}
  }),
  async mounted() {
    const modelsRes = await api.get('/api/models')
    this.models = modelsRes.data.models
    if (!this.modelCode && this.models.length > 0) {
      this.modelCode = DEFAULT_MODEL_ID || String(this.models[0].id)
    }
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
    displayMessages() {
      return this.messages.map((msg, index) => {
        if (index === this.streamingMessageIndex && this.streamingChat.isStreaming.value) {
          const thinking = this.streamingChat.thinkingText.value
          const content = this.streamingChat.responseText.value

          if (thinking && !this.expandedThinking[index]) {
            this.expandedThinking[index] = true
          }

          if (content && this.expandedThinking[index]) {
            this.expandedThinking[index] = false
          }

          return {
            ...msg,
            thinking,
            content
          }
        }
        return msg
      })
    }
  },
  methods: {
    handleRetry() {
      this.streamingChat.retryLastMessage()
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
      } catch (err) {
        console.error('Error loading conversation', err)
      }
    },
    async sendMessage() {
      const text = this.input.trim()
      const model = this.modelCode

      if (!text) return

      const isNew = !this.conversationId

      if (isNew) {
        const convRes = await api.post('/api/conversations')
        this.conversationId = convRes.data.id
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

    async copyToClipboard(text) {
      console.log('Copy button clicked', text)

      // Try modern clipboard API first
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(text)
        console.log('Copied successfully')
        this.$q.notify({
          type: 'positive',
          message: 'Response copied to clipboard',
          position: 'top',
          timeout: 2000
        })
      } else {
        // Fallback for older browsers or non-HTTPS
        const textArea = document.createElement('textarea')
        textArea.value = text
        textArea.style.position = 'fixed'
        textArea.style.left = '-999999px'
        document.body.appendChild(textArea)
        textArea.select()
        document.execCommand('copy')
        document.body.removeChild(textArea)

        this.$q.notify({
          type: 'positive',
          message: 'Response copied to clipboard',
          position: 'top',
          timeout: 2000
        })
      }
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
  justify-content: flex-end;
  margin-top: 8px;
  padding-top: 4px;
}
.copy-btn {
  opacity: 0.6;
  transition: opacity 0.2s;
}
.copy-btn:hover {
  opacity: 1;
}
.user {
  background: var(--bubble-user);
  color: var(--text-user);
  margin: 40px 5px 40px auto;
  display: flex;
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
}
.input-bar {
  border-top: 1px solid var(--border);
}
.input-centered {
  border-top: none;
  justify-content: center;
}
.message-input {
  max-width: 700px;
}
.message-input :deep(.q-field__control) {
  border-radius: 15px;
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
.assistant pre {
  background: var(--bubble-ai);
  padding: 8px 10px;
  border-radius: 6px;
  overflow-x: auto;
  font-family: monospace;
  font-size: 0.9em;
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

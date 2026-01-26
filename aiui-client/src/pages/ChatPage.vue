<template>
  <q-page class="column justify-end">
    <q-select
      v-model="modelCode"
      :options="modelOptions"
      label="Model"
      emit-value
      map-options
      class="q-ma-md"
      style="max-width: 380px"
    />
    <div ref="chatWindow" class="chat-window q-pa-md">
      <div v-for="(msg, i) in messages" :key="i" class="q-mb-md">
        <!-- Thinking section (only for assistant messages with thinking) -->
        <q-expansion-item
          v-if="msg.role === 'assistant' && msg.thinking"
          icon="psychology"
          label="View thinking"
          :default-opened="msg.isStreaming"
          header-class="thinking-header"
          class="q-mb-sm"
        >
          <q-card class="thinking-content">
            <q-card-section>
              <div v-html="formatMessage(msg.thinking)"></div>
              <q-spinner v-if="msg.isStreaming" color="primary" size="20px" class="q-mt-sm" />
            </q-card-section>
          </q-card>
        </q-expansion-item>

        <!-- Main message bubble -->
        <div :class="msg.role" class="bubble q-pa-sm q-rounded-borders">
          <div v-html="formatMessage(msg.content)" />
          <q-spinner v-if="msg.isStreaming && !msg.thinking" color="primary" size="20px" class="q-mt-sm" />
        </div>
      </div>
    </div>

    <div class="input-bar q-pa-md row items-end">
      <q-input
        filled
        autogrow
        v-model="input"
        placeholder="Send a message..."
        class="col"
        @keyup.enter.exact="sendMessage"
      />
      <q-btn icon="send" color="primary" round flat @click="sendMessage" />
      <q-btn icon="add" color="secondary" round flat @click="newChat" />
    </div>
  </q-page>
</template>

<script>
import { api } from 'boot/axios'
import { marked } from 'marked'
import { useStreamingChat } from 'src/composables/useStreamingChat'
import { onBeforeUnmount } from 'vue'

const DEFAULT_MODEL_ID = import.meta.env.VITE_DEFAULT_MODEL_ID || null

export default {
  name: 'ChatPage',
  setup() {
    const streamingChat = useStreamingChat()
    
    // Cleanup streaming on component unmount
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
    currentStreamingIndex: null
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
    // Watch streaming composable refs and update message in real-time
    'streamingChat.thinkingText.value': {
      handler(newThinking) {
        if (this.currentStreamingIndex !== null) {
          this.messages[this.currentStreamingIndex].thinking = newThinking
          this.scrollToBottom()
        }
      }
    },
    'streamingChat.responseText.value': {
      handler(newResponse) {
        if (this.currentStreamingIndex !== null) {
          this.messages[this.currentStreamingIndex].content = newResponse
          this.scrollToBottom()
        }
      }
    }
  },
  computed: {
    modelOptions() {
      return this.models.map(m => ({
        label: String(m.id),
        value: String(m.id)
      }))
    }
  },
  methods: {
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
        this.scrollToBottom()
      } catch (err) {
        console.error('Error loading conversation', err)
      }
    },
    async sendMessage() {
      const text = this.input.trim()
      const model = this.modelCode

      if (!text) return

      try {
        const isNew = !this.conversationId

        if (isNew) {
          const convRes = await api.post('/api/conversations')
          this.conversationId = convRes.data.id
        }

        // Add user message immediately (optimistic UI)
        this.messages.push({ role: 'user', content: text })
        this.input = ''
        this.scrollToBottom()

        // Add placeholder for assistant message with streaming state
        this.currentStreamingIndex = this.messages.length
        this.messages.push({
          role: 'assistant',
          content: '',
          thinking: '',
          isStreaming: true
        })

        // Get JWT token from localStorage
        const token = localStorage.getItem('jwt')

        // Use streaming composable (watchers will update message in real-time)
        await this.streamingChat.sendMessage(
          this.conversationId,
          text,
          token,
          model
        )

        // Mark streaming complete
        this.messages[this.currentStreamingIndex].isStreaming = false

        // Handle any errors from streaming
        if (this.streamingChat.error.value) {
          this.messages[this.currentStreamingIndex].content = `Error: ${this.streamingChat.error.value}`
        }

        // Clear streaming index
        this.currentStreamingIndex = null

        if (isNew && this.$route.params.id !== String(this.conversationId)) {
          this.$router.replace(`/chat/${this.conversationId}`)
        }
      } catch (err) {
        console.error(err)
        this.messages.push({
          role: 'assistant',
          content: 'Error contacting API.'
        })
      }

      this.scrollToBottom()
    },
    scrollToBottom() {
      this.$nextTick(() => {
        const el = this.$refs.chatWindow
        if (el) el.scrollTop = el.scrollHeight
      })
    },

    formatMessage(text) {
      return marked.parse(text)
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
.thinking-header {
  background-color: #f5f5f5;
  border-left: 3px solid #2196F3;
  font-size: 0.9em;
  opacity: 0.8;
}
.thinking-content {
  background-color: #fafafa;
  font-family: monospace;
  font-size: 0.85em;
  color: #666;
}
  background-color: #f6f8fa !important;
}
.assistant {
  /* ai bubble should blend into the background
  background: var(--bubble-ai);
  border: 1px solid var(--border); */
  box-shadow: 0 1px 3px rgba(0,0,0,0.05);
  margin: 40px auto;
}
.input-bar {
  border-top: 1px solid var(--border);
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
</style>

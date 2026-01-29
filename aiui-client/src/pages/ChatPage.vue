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
              <div v-html="formatMessage(msg.thinking || '')"></div>
              <q-spinner v-if="isActivelyStreaming(i) && streamingChat.thinkingText.value" color="primary" size="20px" class="q-mt-sm" />
            </q-card-section>
          </q-card>
        </q-expansion-item>

        <div :class="msg.role" class="bubble q-pa-sm q-rounded-borders">
          <div v-html="formatMessage(msg.content)" />
          <q-spinner v-if="isActivelyStreaming(i)" color="primary" size="20px" class="q-mt-sm" />
        </div>
      </div>
    </div>

    <div
      class="input-bar q-pa-md row items-end"
      :class="{ 'input-centered': !hasMessages }"
    >
      <q-input
        filled
        autogrow
        v-model="input"
        placeholder="Send a message..."
        class="col"
        :style="!hasMessages ? 'max-width: 700px' : ''"
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

      try {
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

        // Handle any errors from streaming
        if (this.streamingChat.error.value) {
          streamedMessage.content = `Error: ${this.streamingChat.error.value}`
        }

        // Clear streaming index
        this.streamingMessageIndex = null

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
</style>

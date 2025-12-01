<template>
  <q-page class="column justify-end">
    <div ref="chatWindow" class="chat-window q-pa-md">
      <div v-for="(msg, i) in messages" :key="i" class="q-mb-md">
        <div :class="msg.role" class="bubble q-pa-sm q-rounded-borders">
          <div v-html="formatMessage(msg.content)" />
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

export default {
  name: 'ChatPage',
  data: () => ({
    input: '',
    messages: [],
    conversationId: null
  }),
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
        }
      }
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
      }
    },
    async loadConversation() {
      try {
        const res = await api.get(`/api/conversations/${this.conversationId}`)
        this.messages = res.data.messages
        this.scrollToBottom()
      } catch (err) {
        console.error('Error loading conversation', err)
      }
    },
    async sendMessage() {
      const text = this.input.trim()
      if (!text) return

      try {
        const isNew = !this.conversationId

        if (isNew) {
          const convRes = await api.post('/api/conversations')
          this.conversationId = convRes.data.id
        }

        this.messages.push({ role: 'user', content: text })
        this.input = ''
        this.scrollToBottom()

        const res = await api.post(
          `/api/conversations/${this.conversationId}/messages`,
          { content: text }
        )
        this.messages.push({ role: 'assistant', content: res.data.reply })

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
  margin: 40px 5px 40px auto;
  display: flex;
  justify-content: start;
  align-items: center;
  padding: 15px 25px;
}
p {
  margin: 0 !important;
  margin-bottom: 0 !important;
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

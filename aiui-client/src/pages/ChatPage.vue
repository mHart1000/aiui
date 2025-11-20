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
import axios from 'axios'
import { marked } from 'marked'

export default {
  name: 'ChatPage',
  data: () => ({
    input: '',
    messages: [],
    conversationId: null
  }),
  async mounted() {
    // Automatically start a new chat when the page loads
    await this.newChat()
  },
  methods: {
    async newChat() {
      try {
        const res = await axios.post(`${import.meta.env.VITE_API_BASE_URL}/api/conversations`)
        this.conversationId = res.data.id
        this.messages = []
      } catch (err) {
        console.error('Error creating new conversation', err)
      }
    },

    async sendMessage() {
      const text = this.input.trim()
      if (!text || !this.conversationId) return

      this.messages.push({ role: 'user', content: text })
      this.input = ''
      this.scrollToBottom()

      try {
        const res = await axios.post(
          `${import.meta.env.VITE_API_BASE_URL}/api/conversations/${this.conversationId}/chats`,
          { content: text }
        )
        this.messages.push({ role: 'assistant', content: res.data.reply })
      } catch (err) {
        console.error(err)
        this.messages.push({ role: 'assistant', content: 'Error contacting API.' })
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
  max-width: 80%;
  line-height: 1.5;
}
.user {
  background: #1976d2;
  color: white;
  margin-left: auto;
}
.assistant {
  background: rgb(22, 148, 22);
  color: #ffffff;
  border: 1px solid #ddd;
  box-shadow: 0 1px 3px rgba(0,0,0,0.05);
}
.input-bar {
  border-top: 1px solid #e0e0e0;
}
.assistant pre {
  background: #f6f8fa;
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

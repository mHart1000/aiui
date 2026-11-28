import assert from 'node:assert/strict'
import { after, before, test } from 'node:test'
import { parse } from 'vue/compiler-sfc'
import { readFile } from 'node:fs/promises'
import { createServer } from 'vite'

let server
let page
const api = {}

before(async () => {
  globalThis.chatPageTestApi = api
  server = await createServer({
    configFile: false,
    server: { middlewareMode: true },
    plugins: [{
      name: 'chat-page-test',
      enforce: 'pre',
      resolveId(source) {
        if (source === 'boot/axios' || source.startsWith('components/') || source.startsWith('src/composables/')) {
          return `\0test:${source}`
        }
      },
      async load(id) {
        if (id === '\0test:boot/axios') return 'export const api = globalThis.chatPageTestApi'
        if (id.startsWith('\0test:components/')) return 'export default {}'
        if (id === '\0test:src/composables/useStreamingChat') return 'export const useStreamingChat = () => ({})'
        if (id === '\0test:src/composables/useTtsPlayer') return 'export const useTtsPlayer = () => ({})'
        if (id.endsWith('/ChatPage.vue')) {
          return parse(await readFile(id, 'utf8')).descriptor.script.content
        }
      }
    }]
  })
  page = (await server.ssrLoadModule('/src/pages/ChatPage.vue')).default
})

after(async () => {
  await server?.close()
  delete globalThis.chatPageTestApi
})

function context() {
  return {
    conversationId: 1,
    messages: [{ id: 10 }, { id: 11 }, { id: 12 }],
    deletingMessageIndex: 1,
    deleteMessageOpen: true,
    isDeletingMessage: false,
    streamingChat: { isStreaming: { value: false } },
    cancelEdit() { this.editCancelled = true },
    async refreshConversations() { this.refreshed = true }
  }
}

function pendingDelete() {
  let resolve
  let reject
  const promise = new Promise((res, rej) => { resolve = res; reject = rej })
  api.delete = (url) => {
    assert.equal(url, '/api/conversations/1/messages/11')
    return promise
  }
  return { resolve, reject }
}

test('successful delete truncates the original conversation and closes the dialog', async () => {
  const state = context()
  const request = pendingDelete()
  const result = page.methods.deleteMessage.call(state)
  state.conversationId = '1'
  request.resolve()
  await result
  assert.deepEqual(state.messages, [{ id: 10 }])
  assert.equal(state.editCancelled, true)
  assert.equal(state.deleteMessageOpen, false)
  assert.equal(state.refreshed, true)
  assert.equal(state.isDeletingMessage, false)
})

test('pending delete does not mutate another conversation after navigation', async () => {
  const state = context()
  const request = pendingDelete()
  const result = page.methods.deleteMessage.call(state)
  state.conversationId = '2'
  state.messages = [{ id: 20 }, { id: 21 }]
  request.resolve()
  await result
  assert.deepEqual(state.messages, [{ id: 20 }, { id: 21 }])
  assert.equal(state.editCancelled, undefined)
  assert.equal(state.deleteMessageOpen, false)
  assert.equal(state.refreshed, true)
  assert.equal(state.isDeletingMessage, false)
})

test('navigation closes the dialog even if a pending delete fails', async () => {
  const state = context()
  const request = pendingDelete()
  const result = page.methods.deleteMessage.call(state)
  state.clearAttachments = () => {}
  state.loadConversation = async () => {}
  await page.watch['$route.params.id'].handler.call(state, '2', '1')
  assert.equal(state.deleteMessageOpen, false)
  request.reject(new Error('delete failed'))
  await assert.rejects(result, /delete failed/)
  assert.equal(state.isDeletingMessage, false)
  assert.equal(state.refreshed, undefined)
})

test('opening a conversation from a new chat closes a stale dialog', async () => {
  const state = context()
  state.loadConversation = async () => {}
  await page.watch['$route.params.id'].handler.call(state, '2', undefined)
  assert.equal(state.deleteMessageOpen, false)
})

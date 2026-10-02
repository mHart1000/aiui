<template>
  <q-layout view="hHh LpR fFf">
    <q-drawer show-if-above bordered :width="sidebarWidth" class="bg-panel">
      <q-scroll-area
        class="drawer-scroll"
        :thumb-style="scrollThumbStyle"
        :bar-style="scrollBarStyle"
      >
        <div class="drawer-content q-pa-md column justify-between full-height">
          <div>
            <q-btn
              flat
              icon="add"
              label="New Chat"
              class="full-width q-mb-sm"
              @click="$router.push('/chat')"
            />
            <q-btn
              flat
              icon="folder"
              label="Knowledge"
              class="full-width q-mb-sm"
              @click="knowledgeOpen = true"
            />
            <q-btn
              v-if="!searchActive"
              flat
              icon="search"
              label="Search"
              class="full-width q-mb-md"
              @click="openSearch"
            />
            <q-input
              v-else
              ref="searchInput"
              v-model="searchQuery"
              dense
              outlined
              clearable
              placeholder="Search conversations"
              class="search-input q-mb-md"
              @keyup.esc="closeSearch"
              @blur="onSearchBlur"
            >
              <template #prepend>
                <q-icon name="search" />
              </template>
            </q-input>
            <q-list dense>
              <q-item
                v-for="c in filteredConversations"
                :key="c.id"
                clickable
                class="conversation-row"
                @click="$router.push(`/chat/${c.id}`)"
              >
                <q-item-section class="conversation-title" :style="{ maxWidth: titleMaxWidth }">
                  <q-item-label class="ellipsis">
                    {{ c.title }}
                  </q-item-label>
                  <q-item-label v-if="c.snippet" caption class="snippet-line">
                    <span class="snippet-side snippet-before"><bdi>{{ c.snippet.before }}</bdi></span><mark class="snippet-match">{{ c.snippet.match }}</mark><span class="snippet-side snippet-after">{{ c.snippet.after }}</span>
                  </q-item-label>
                </q-item-section>
                <q-btn
                  class="conversation-actions"
                  flat
                  round
                  dense
                  size="sm"
                  icon="more_vert"
                  :aria-label="`Actions for ${c.title}`"
                  @click.stop
                >
                  <q-menu auto-close>
                    <q-list dense style="min-width: 140px">
                      <q-item clickable @click="openRename(c)">
                        <q-item-section avatar><q-icon name="edit" /></q-item-section>
                        <q-item-section>Rename</q-item-section>
                      </q-item>
                      <q-item clickable :disable="actionConversationId === c.id" @click="duplicateConversation(c)">
                        <q-item-section avatar><q-icon name="content_copy" /></q-item-section>
                        <q-item-section>Duplicate</q-item-section>
                      </q-item>
                      <q-separator />
                      <q-item clickable class="text-negative" @click="openDelete(c)">
                        <q-item-section avatar><q-icon name="delete" /></q-item-section>
                        <q-item-section>Delete</q-item-section>
                      </q-item>
                    </q-list>
                  </q-menu>
                </q-btn>
              </q-item>
            </q-list>
          </div>
          <div class="column items-center">
            <q-btn label="Sign Out" color="primary" @click="logout" />
            <q-btn @click="toggleDark" label="Toggle Dark" />
          </div>
        </div>
      </q-scroll-area>
    </q-drawer>

    <div
      v-if="$q.screen.gt.sm"
      class="drawer-resizer"
      :style="{ left: (sidebarWidth - 6) + 'px' }"
      @mousedown="startResize"
      @dblclick="resetWidth"
    ></div>

    <q-page-container>
      <router-view />
    </q-page-container>

    <RagKnowledgeDialog v-model="knowledgeOpen" />

    <q-dialog v-model="renameOpen" @hide="renameConversation = null">
      <q-card style="min-width: 360px">
        <q-card-section class="text-h6">Rename conversation</q-card-section>
        <q-card-section>
          <q-input
            ref="renameInput"
            v-model="renameTitle"
            autofocus
            dense
            outlined
            label="Title"
            @keyup.enter="saveRename"
          />
        </q-card-section>
        <q-card-actions align="right">
          <q-btn flat label="Cancel" v-close-popup />
          <q-btn color="primary" label="Rename" :loading="savingRename" :disable="!renameTitle.trim()" @click="saveRename" />
        </q-card-actions>
      </q-card>
    </q-dialog>

    <q-dialog v-model="deleteOpen" @hide="deleteConversation = null">
      <q-card style="min-width: 360px">
        <q-card-section class="text-h6">Delete conversation?</q-card-section>
        <q-card-section>
          “{{ deleteConversation?.title }}” and all of its messages will be permanently deleted.
        </q-card-section>
        <q-card-actions align="right">
          <q-btn flat label="Cancel" v-close-popup />
          <q-btn color="negative" label="Delete" :loading="deletingConversation" @click="confirmDelete" />
        </q-card-actions>
      </q-card>
    </q-dialog>
  </q-layout>
</template>

<script>
import { Dark } from 'quasar'
import { api } from 'src/boot/axios'
import RagKnowledgeDialog from 'components/RagKnowledgeDialog.vue'

export default {
  name: 'ChatLayout',
  components: { RagKnowledgeDialog },
  provide() {
    return {
      refreshConversations: () => this.getUserConversations()
    }
  },
  data: () => ({
    conversations: [],
    knowledgeOpen: false,
    searchActive: false,
    searchQuery: '',
    searchResults: [],
    renameOpen: false,
    renameConversation: null,
    renameTitle: '',
    savingRename: false,
    deleteOpen: false,
    deleteConversation: null,
    deletingConversation: false,
    actionConversationId: null,
    sidebarWidth: 280,
    resizeOffset: 0,
    scrollThumbStyle: {
      borderRadius: '5px',
      backgroundColor: 'var(--border, #9e9e9e)',
      width: '25px',
      opacity: 0.9
    },
    scrollBarStyle: {
      right: '5px',
      borderRadius: '5px',
      backgroundColor: 'var(--border, #9e9e9e)',
      width: '15px',
      opacity: 0.45
    }
  }),
  computed: {
    titleMaxWidth () {
      return `${this.sidebarWidth - 40}px`
    },
    filteredConversations () {
      return this.searchQuery?.trim() ? this.searchResults : this.conversations
    }
  },
  watch: {
    searchQuery () {
      clearTimeout(this.searchTimer)
      this.searchTimer = setTimeout(this.runSearch, 200)
    }
  },
  mounted() {
    this.getUserConversations()
  },
  beforeUnmount() {
    clearTimeout(this.searchTimer)
    document.removeEventListener('mousemove', this.onResize)
    document.removeEventListener('mouseup', this.stopResize)
    document.body.classList.remove('drawer-resizing')
  },
  methods: {
    toggleDark() {
      Dark.toggle();
    },
    openSearch() {
      this.searchActive = true
      this.$nextTick(() => this.$refs.searchInput?.focus())
    },
    closeSearch() {
      this.searchQuery = ''
      this.searchResults = []
      this.searchActive = false
    },
    runSearch() {
      const q = this.searchQuery?.trim()
      if (!q) {
        this.searchResults = []
        return
      }
      api.get('/api/conversations/search', { params: { q } })
        .then(response => {
          if (this.searchQuery?.trim() === q) this.searchResults = response.data
        })
        .catch(error => console.error('Error searching conversations:', error))
    },
    onSearchBlur() {
      if (!this.searchQuery?.trim()) this.closeSearch()
    },
    logout() {
      localStorage.removeItem('jwt')
      this.$router.replace('/login')
    },
    getUserConversations() {
      console.log('Fetching user conversations...')
      return api.get('/api/conversations')
        .then(response => {
          this.conversations = response.data.sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at))
        })
    },
    replaceConversation(updated) {
      const replace = conversation => conversation.id === updated.id
        ? { ...conversation, ...updated }
        : conversation
      this.conversations = this.conversations.map(replace)
      this.searchResults = this.searchResults.map(replace)
    },
    removeConversation(id) {
      this.conversations = this.conversations.filter(conversation => conversation.id !== id)
      this.searchResults = this.searchResults.filter(conversation => conversation.id !== id)
    },
    openRename(conversation) {
      this.renameConversation = conversation
      this.renameTitle = conversation.title
      this.renameOpen = true
    },
    async saveRename() {
      const title = this.renameTitle.trim()
      if (!title || !this.renameConversation || this.savingRename) return

      this.savingRename = true
      try {
        const response = await api.patch(`/api/conversations/${this.renameConversation.id}`, {
          conversation: { title }
        })
        this.replaceConversation(response.data)
        this.renameOpen = false
      } finally {
        this.savingRename = false
      }
    },
    async duplicateConversation(conversation) {
      if (this.actionConversationId !== null) return

      this.actionConversationId = conversation.id
      try {
        const response = await api.post(`/api/conversations/${conversation.id}/duplicate`)
        await this.getUserConversations()
        await this.$router.push(`/chat/${response.data.id}`)
      } finally {
        this.actionConversationId = null
      }
    },
    openDelete(conversation) {
      this.deleteConversation = conversation
      this.deleteOpen = true
    },
    async confirmDelete() {
      if (!this.deleteConversation || this.deletingConversation) return

      const id = this.deleteConversation.id
      this.deletingConversation = true
      try {
        await api.delete(`/api/conversations/${id}`)
        this.removeConversation(id)
        this.deleteOpen = false
        if (String(this.$route.params.id) === String(id)) await this.$router.push('/chat')
      } finally {
        this.deletingConversation = false
      }
    },
    clampWidth(w) {
      return Math.min(500, Math.max(200, w))
    },
    startResize(e) {
      this.resizeOffset = this.sidebarWidth - e.clientX
      document.addEventListener('mousemove', this.onResize)
      document.addEventListener('mouseup', this.stopResize)
      document.body.classList.add('drawer-resizing')
    },
    onResize(e) {
      this.sidebarWidth = this.clampWidth(e.clientX + this.resizeOffset)
    },
    stopResize() {
      document.removeEventListener('mousemove', this.onResize)
      document.removeEventListener('mouseup', this.stopResize)
      document.body.classList.remove('drawer-resizing')
    },
    resetWidth() {
      this.sidebarWidth = 280
    }
  }
}
</script>
<style scoped>
.conversation-title {
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.conversation-row {
  position: relative;
  padding-right: 48px;
}
.conversation-actions {
  position: absolute;
  top: 50%;
  right: 4px;
  z-index: 1;
  opacity: 0;
  visibility: hidden;
  pointer-events: none;
  transform: translateY(-50%);
  transition: opacity 120ms ease;
}
.conversation-row:hover .conversation-actions,
.conversation-row:focus-within .conversation-actions {
  opacity: 1;
  visibility: visible;
  pointer-events: auto;
}
.drawer-content {
  min-width: 0;
  overflow-x: hidden;
}
.search-input {
  width: calc(100% - 14px);
}
/* 3-part snippet: keyword stays centered, text clips on both sides. */
.snippet-line {
  display: flex;
  align-items: baseline;
  min-width: 0;
}
.snippet-side {
  flex: 1 1 0;
  min-width: 0;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.snippet-before {
  /* clip/ellipsis on the left so the text nearest the keyword stays visible */
  direction: rtl;
  text-align: right;
}
.snippet-after {
  text-align: left;
}
.snippet-match {
  flex: 0 0 auto;
  background-color: rgba(255, 213, 79, 0.45);
  color: inherit;
  border-radius: 2px;
  padding: 0 1px;
}
.drawer-scroll {
  position: absolute;
  top: 0;
  left: 0;
  bottom: 0;
  right: 2px;
}
.drawer-resizer {
  position: absolute;
  top: 0;
  bottom: 0;
  width: 14px;
  cursor: ew-resize;
  z-index: 2001;
}
/* Only the 6px edge strip shows; the rest is an invisible, forgiving hit area. */
.drawer-resizer::before {
  content: '';
  position: absolute;
  top: 0;
  bottom: 0;
  left: 0;
  width: 6px;
  background-color: transparent;
  transition: background-color 0.15s;
}
.drawer-resizer:hover::before {
  background-color: var(--border, rgba(127, 127, 127, 0.4));
}
</style>

<style>
/*  disable drawer/page transitions so resize follows the
   cursor, and force the resize cursor + block text selection page-wide. */
body.drawer-resizing {
  cursor: ew-resize;
  user-select: none;
}
body.drawer-resizing .q-drawer,
body.drawer-resizing .q-drawer__content,
body.drawer-resizing .q-page-container {
  transition: none !important;
}
</style>

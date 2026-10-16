<template>
  <q-layout view="hHh LpR fFf">
    <q-drawer show-if-above :width="sidebarWidth" class="bg-panel">
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
              @click="newChat()"
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
            <q-btn flat icon="create_new_folder" label="New project" class="full-width q-mb-sm" @click="editProject()" />
            <q-list dense>
              <template v-for="group in conversationGroups" :key="group.key">
                <q-item v-if="group.project" class="q-px-none">
                  <q-item-section avatar>
                    <q-btn flat round dense :icon="collapsedProjects[group.project.id] ? 'chevron_right' : 'expand_more'" :aria-label="`Toggle ${group.project.name}`" @click="collapsedProjects[group.project.id] = !collapsedProjects[group.project.id]" />
                  </q-item-section>
                  <q-item-section class="ellipsis">{{ group.project.name }}</q-item-section>
                  <q-item-section side>
                    <q-btn flat round dense icon="more_vert" :aria-label="`Actions for ${group.project.name}`">
                      <q-menu auto-close>
                        <q-list dense>
                          <q-item clickable @click="newChat(group.project.id)"><q-item-section>New chat</q-item-section></q-item>
                          <q-item clickable @click="editProject(group.project)"><q-item-section>Edit project</q-item-section></q-item>
                          <q-item clickable @click="projectToDelete = group.project"><q-item-section>Delete project</q-item-section></q-item>
                        </q-list>
                      </q-menu>
                    </q-btn>
                  </q-item-section>
                </q-item>
                <q-item-label v-else-if="!searchQuery.trim() && projects.length" header>Unfiled</q-item-label>
                <template v-if="!group.project || !collapsedProjects[group.project.id]">
                  <q-item
                    v-for="c in group.conversations"
                    :key="c.id"
                    clickable
                    class="conversation-row"
                    @click="$router.push(`/chat/${c.id}`)"
                  >
                    <q-item-section class="conversation-title" :style="{ maxWidth: titleMaxWidth }">
                      <q-item-label class="ellipsis">
                        {{ c.title }}
                      </q-item-label>
                      <q-item-label v-if="searchQuery.trim()" caption>{{ projectName(c.project_id) }}</q-item-label>
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
                          <q-item clickable @click="openMove(c)">
                            <q-item-section avatar><q-icon name="drive_file_move" /></q-item-section>
                            <q-item-section>Move to project</q-item-section>
                          </q-item>
                          <q-item clickable @click="openRename(c)">
                            <q-item-section avatar><q-icon name="edit" /></q-item-section>
                            <q-item-section>Rename</q-item-section>
                          </q-item>
                          <q-item clickable :disable="actionConversationId === c.id" @click="duplicateConversation(c)">
                            <q-item-section avatar><q-icon name="content_copy" /></q-item-section>
                            <q-item-section>Duplicate</q-item-section>
                          </q-item>
                          <q-item clickable @click="openDelete(c)">
                            <q-item-section avatar><q-icon name="delete" /></q-item-section>
                            <q-item-section>Delete</q-item-section>
                          </q-item>
                        </q-list>
                      </q-menu>
                    </q-btn>
                  </q-item>
                </template>
              </template>
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
      <q-banner v-if="!$route.params.id && $route.query.project" dense class="bg-panel">
        <q-icon name="folder" class="q-mr-sm" />New chat in {{ projectName(Number($route.query.project)) }}
      </q-banner>
      <router-view />
    </q-page-container>

    <q-dialog v-model="projectEditorOpen" persistent>
      <q-card style="width: 520px; max-width: 90vw">
        <q-card-section class="text-h6">{{ editingProjectId ? 'Edit project' : 'New project' }}</q-card-section>
        <q-card-section class="q-gutter-md">
          <q-input v-model="projectDraft.name" outlined autofocus label="Project name" :maxlength="projectLimits.name" counter />
          <q-input v-model="projectDraft.description" outlined type="textarea" label="Project description" :maxlength="projectLimits.description" counter hint="Shared with every conversation in this project on subsequent turns." />
          <div v-if="projectError" class="text-negative" role="alert">{{ projectError }}</div>
        </q-card-section>
        <q-card-actions align="right">
          <q-btn flat label="Cancel" :disable="savingProject" v-close-popup />
          <q-btn color="primary" label="Save" :loading="savingProject" :disable="!projectDraft.name.trim()" @click="saveProject" />
        </q-card-actions>
      </q-card>
    </q-dialog>
    <q-dialog :model-value="!!projectToDelete" @update:model-value="value => { if (!value) projectToDelete = null }" persistent>
      <q-card style="width: 400px; max-width: 90vw">
        <q-card-section class="text-h6">Delete project?</q-card-section>
        <q-card-section>Delete “{{ projectToDelete?.name }}” and its description? Its conversations will be kept in Unfiled.</q-card-section>
        <q-card-actions align="right">
          <q-btn flat label="Cancel" :disable="savingProject" @click="projectToDelete = null" />
          <q-btn label="Delete" :loading="savingProject" @click="deleteProject" />
        </q-card-actions>
      </q-card>
    </q-dialog>
    <q-dialog v-model="moveOpen" persistent>
      <q-card style="width: 400px; max-width: 90vw">
        <q-card-section class="text-h6">Move conversation</q-card-section>
        <q-card-section>
          <q-select v-model="moveProjectId" outlined label="Project" :options="projectOptions" emit-value map-options />
          <div v-if="moveError" class="text-negative q-mt-sm" role="alert">{{ moveError }}</div>
        </q-card-section>
        <q-card-actions align="right">
          <q-btn flat label="Cancel" :disable="movingConversation" v-close-popup />
          <q-btn color="primary" label="Move" :loading="movingConversation" @click="moveConversation" />
        </q-card-actions>
      </q-card>
    </q-dialog>

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
          <q-btn label="Delete" :loading="deletingConversation" @click="confirmDelete" />
        </q-card-actions>
      </q-card>
    </q-dialog>
  </q-layout>
</template>

<script>
import { Dark } from 'quasar'
import { api } from 'src/boot/axios'
import RagKnowledgeDialog from 'components/RagKnowledgeDialog.vue'

const TITLE_REFRESH_INTERVAL_MS = 2000

export default {
  name: 'ChatLayout',
  components: { RagKnowledgeDialog },
  provide() {
    return {
      refreshConversations: (pendingTitleId) => {
        if (pendingTitleId) this.pendingTitleId = pendingTitleId
        return this.getUserConversations()
      }
    }
  },
  data: () => ({
    conversations: [],
    projects: [],
    projectLimits: {},
    collapsedProjects: {},
    projectEditorOpen: false,
    editingProjectId: null,
    projectDraft: { name: '', description: '' },
    projectError: '',
    savingProject: false,
    projectToDelete: null,
    moveOpen: false,
    movingConversation: false,
    moveTarget: null,
    moveProjectId: null,
    moveError: '',
    pendingTitleId: null,
    titleRefreshTimer: null,
    disposed: false,
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
      width: '15px',
      opacity: 0.9
    },
    scrollBarStyle: {
      right: '2px',
      borderRadius: '5px',
      backgroundColor: 'var(--border, #9e9e9e)',
      width: '12px',
      opacity: 0.45
    }
  }),
  computed: {
    projectOptions () {
      return [{ label: 'Unfiled', value: null }, ...this.projects.map(p => ({ label: p.name, value: p.id }))]
    },
    conversationGroups () {
      if (this.searchQuery.trim()) return [{ key: 'search', conversations: this.searchResults }]
      return [
        ...this.projects.map(project => ({ key: project.id, project, conversations: this.conversations.filter(c => c.project_id === project.id) })),
        { key: 'unfiled', conversations: this.conversations.filter(c => !c.project_id) }
      ]
    },
    titleMaxWidth () {
      return `${this.sidebarWidth - 40}px`
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
    this.getProjects()
  },
  beforeUnmount() {
    this.disposed = true
    clearTimeout(this.titleRefreshTimer)
    clearTimeout(this.searchTimer)
    document.removeEventListener('mousemove', this.onResize)
    document.removeEventListener('mouseup', this.stopResize)
    document.body.classList.remove('drawer-resizing')
  },
  methods: {
    async getProjects() {
      const { data } = await api.get('/api/projects')
      this.projects = data.projects
      this.projectLimits = data.limits
    },
    projectName(id) {
      return this.projects.find(p => p.id === id)?.name || 'Unfiled'
    },
    newChat(projectId = null) {
      if (projectId) this.collapsedProjects[projectId] = false
      return this.$router.push({ path: '/chat', query: projectId ? { project: projectId } : {} })
    },
    editProject(project = null) {
      this.editingProjectId = project?.id || null
      this.projectDraft = { name: project?.name || '', description: project?.description || '' }
      this.projectError = ''
      this.projectEditorOpen = true
    },
    async saveProject() {
      if (this.savingProject || !this.projectDraft.name.trim()) return
      this.savingProject = true
      this.projectError = ''
      try {
        const payload = { project: this.projectDraft }
        if (this.editingProjectId) await api.patch(`/api/projects/${this.editingProjectId}`, payload)
        else await api.post('/api/projects', payload)
        await this.getProjects()
        this.projectEditorOpen = false
      } catch (error) {
        if (error.response?.status !== 422) throw error
        console.error('Project validation failed:', error)
        this.projectError = error.response.data.errors.join(', ')
      } finally {
        this.savingProject = false
      }
    },
    async deleteProject() {
      if (this.savingProject || !this.projectToDelete) return
      this.savingProject = true
      try {
        const id = this.projectToDelete.id
        await api.delete(`/api/projects/${id}`)
        this.projectToDelete = null
        await Promise.all([this.getProjects(), this.getUserConversations()])
        this.runSearch()
        if (String(this.$route.query.project) === String(id)) await this.$router.replace({ path: this.$route.path })
      } finally {
        this.savingProject = false
      }
    },
    openMove(conversation) {
      this.moveTarget = conversation
      this.moveProjectId = conversation.project_id
      this.moveError = ''
      this.moveOpen = true
    },
    async moveConversation() {
      if (this.movingConversation || !this.moveTarget) return
      this.movingConversation = true
      this.moveError = ''
      try {
        const { data } = await api.patch(`/api/conversations/${this.moveTarget.id}`, { conversation: { project_id: this.moveProjectId } })
        this.replaceConversation(data)
        if (data.project_id) this.collapsedProjects[data.project_id] = false
        this.moveOpen = false
      } catch (error) {
        if (error.response?.status !== 422) throw error
        console.error('Conversation move validation failed:', error)
        this.moveError = error.response.data.errors.join(', ')
      } finally {
        this.movingConversation = false
      }
    },
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
      clearTimeout(this.titleRefreshTimer)
      console.log('Fetching user conversations...')
      return api.get('/api/conversations')
        .then(response => {
          this.conversations = response.data.sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at))
          const pending = this.conversations.find(c => String(c.id) === String(this.pendingTitleId))
          if (pending && (!pending.title || pending.title === 'New Chat') && !this.disposed) {
            this.titleRefreshTimer = setTimeout(() => {
              this.getUserConversations().catch(error => {
                console.error('Error refreshing conversation title:', error)
                this.$q.notify({ type: 'negative', message: 'Title refresh failed. Reload to retry.' })
              })
            }, TITLE_REFRESH_INTERVAL_MS)
          } else {
            this.pendingTitleId = null
          }
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
  display: grid;
  grid-template-columns: minmax(0, 1fr) 2px 1px;
  align-items: center;
}
.conversation-actions {
  grid-column: 2;
  justify-self: center;
  z-index: 1;
  opacity: 0;
  visibility: hidden;
  pointer-events: none;
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

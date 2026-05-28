<template>
  <q-layout view="hHh LpR fFf">
    <q-drawer show-if-above bordered :width="sidebarWidth" class="bg-panel">
      <q-scroll-area
        class="drawer-scroll"
        :thumb-style="scrollThumbStyle"
        :bar-style="scrollBarStyle"
      >
        <div class="q-pa-md column justify-between full-height">
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
              class="full-width q-mb-md"
              @click="knowledgeOpen = true"
            />
            <q-list dense>
              <q-item
                v-for="c in conversations"
                :key="c.id"
                clickable
                @click="$router.push(`/chat/${c.id}`)"
              >
                <q-item-section class="conversation-title" :style="{ maxWidth: titleMaxWidth }">
                  <q-item-label class="ellipsis">
                    {{ c.title }}
                  </q-item-label>
                </q-item-section>
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
    }
  },
  mounted() {
    this.getUserConversations()
  },
  beforeUnmount() {
    document.removeEventListener('mousemove', this.onResize)
    document.removeEventListener('mouseup', this.stopResize)
    document.body.classList.remove('drawer-resizing')
  },
  methods: {
    toggleDark() {
      Dark.toggle();
    },
    logout() {
      localStorage.removeItem('jwt')
      this.$router.replace('/login')
    },
    getUserConversations() {
      console.log('Fetching user conversations...')
      api.get('/api/conversations')
        .then(response => {
          this.conversations = response.data.sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at))
        })
        .catch(error => {
          console.error('Error fetching conversations:', error)
        });
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

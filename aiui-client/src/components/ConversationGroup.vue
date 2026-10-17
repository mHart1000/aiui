<template>
  <q-item v-if="group.project" class="q-px-none">
    <q-item-section avatar>
      <q-btn flat round dense :icon="collapsed ? 'folder' : 'folder_open'" :aria-label="`Toggle ${group.project.name}`" :aria-expanded="!collapsed" @mousedown.left="collapsed = !collapsed" @click="$event.detail === 0 && (collapsed = !collapsed)" />
    </q-item-section>
    <q-item-section>
      <button type="button" class="project-name ellipsis" :aria-expanded="!collapsed" @click="selectProject">{{ group.project.name }}</button>
    </q-item-section>
    <q-item-section side>
      <q-btn flat round dense icon="more_vert" :aria-label="`Actions for ${group.project.name}`">
        <q-menu auto-close>
          <q-list dense>
            <q-item clickable @click="$emit('new-chat', group.project.id)"><q-item-section>New chat</q-item-section></q-item>
            <q-item clickable @click="$emit('edit-project', group.project)"><q-item-section>Edit project</q-item-section></q-item>
            <q-item clickable @click="$emit('delete-project', group.project)"><q-item-section>Delete project</q-item-section></q-item>
          </q-list>
        </q-menu>
      </q-btn>
    </q-item-section>
  </q-item>
  <q-item
    v-for="c in group.conversations"
    v-show="!collapsed"
    :key="c.id"
    clickable
    class="conversation-row"
    @click="$router.push(`/chat/${c.id}`)"
  >
    <q-item-section class="conversation-title" :style="{ maxWidth: titleMaxWidth }">
      <q-item-label class="ellipsis">
        {{ c.title }}
      </q-item-label>
      <q-item-label v-if="searching && c.project_id" caption>{{ projectNames[c.project_id] }}</q-item-label>
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
          <q-item clickable @click="$emit('move', c)">
            <q-item-section avatar><q-icon name="drive_file_move" /></q-item-section>
            <q-item-section>Move to project</q-item-section>
          </q-item>
          <q-item v-if="c.project_id" clickable :disable="actionConversationId !== null" @click="$emit('remove-from-project', c)">
            <q-item-section avatar><q-icon name="folder_off" /></q-item-section>
            <q-item-section>Remove from project</q-item-section>
          </q-item>
          <q-item clickable @click="$emit('rename', c)">
            <q-item-section avatar><q-icon name="edit" /></q-item-section>
            <q-item-section>Rename</q-item-section>
          </q-item>
          <q-item clickable :disable="actionConversationId === c.id" @click="$emit('duplicate', c)">
            <q-item-section avatar><q-icon name="content_copy" /></q-item-section>
            <q-item-section>Duplicate</q-item-section>
          </q-item>
          <q-item clickable @click="$emit('delete-conversation', c)">
            <q-item-section avatar><q-icon name="delete" /></q-item-section>
            <q-item-section>Delete</q-item-section>
          </q-item>
        </q-list>
      </q-menu>
    </q-btn>
  </q-item>
</template>

<script>
export default {
  name: 'ConversationGroup',
  props: {
    group: { type: Object, required: true },
    titleMaxWidth: { type: String, required: true },
    searching: Boolean,
    projectNames: { type: Object, required: true },
    actionConversationId: { type: Number, default: null }
  },
  emits: ['new-chat', 'edit-project', 'delete-project', 'move', 'remove-from-project', 'rename', 'duplicate', 'delete-conversation'],
  data: () => ({ collapsed: false }),
  methods: {
    selectProject() {
      this.collapsed = !this.collapsed
      this.$emit('new-chat', this.group.project.id, false)
    },
    expand() {
      this.collapsed = false
    }
  }
}
</script>

<style scoped>
.project-name {
  border: 0;
  padding: 0;
  background: none;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}
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
</style>

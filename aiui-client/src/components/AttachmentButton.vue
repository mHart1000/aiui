<template>
  <div class="attachment-button">
    <q-btn icon="add" color="secondary" round flat aria-label="Attach an image or start a new chat">
      <q-tooltip>Attach or start a new chat</q-tooltip>
      <q-menu anchor="top left" self="bottom left">
        <q-list style="min-width: 240px">
          <q-item v-close-popup clickable @click="pickFiles">
            <q-item-section avatar>
              <q-icon name="attach_file" />
            </q-item-section>
            <q-item-section>Attach files</q-item-section>
          </q-item>
          <q-separator v-if="showNewChat" />

          <q-item v-if="showNewChat" v-close-popup clickable @click="$emit('new-chat')">
            <q-item-section avatar>
              <q-icon name="add_comment" />
            </q-item-section>
            <q-item-section>New chat</q-item-section>
          </q-item>
        </q-list>
      </q-menu>
    </q-btn>

    <input
      ref="attachmentInput"
      type="file"
      accept="image/png,image/jpeg,image/webp,application/pdf,.pdf"
      multiple
      class="file-input"
      @change="onFilesChosen"
    />
  </div>
</template>

<script>
export default {
  name: 'AttachmentButton',

  props: {
    showNewChat: {
      type: Boolean,
      default: false
    }
  },
  emits: ['files-selected', 'new-chat'],

  methods: {
    pickFiles () {
      this.$refs.attachmentInput.click()
    },
    onFilesChosen (event) {
      const files = Array.from(event.target.files || [])
      if (files.length) this.$emit('files-selected', files)
      // Reset so picking the same file twice still fires a change event.
      event.target.value = ''
    }
  }
}
</script>

<style scoped>
.file-input {
  display: none;
}
</style>

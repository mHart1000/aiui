<template>
  <div class="attachment-button">
    <q-btn icon="add" color="secondary" round flat>
      <q-tooltip>Attach or start a new chat</q-tooltip>
      <q-menu anchor="top left" self="bottom left">
        <q-list style="min-width: 240px">
          <q-item v-close-popup clickable :disable="!imagesSupported" @click="pickFiles">
            <q-item-section avatar>
              <q-icon name="image" />
            </q-item-section>
            <q-item-section>Attach image</q-item-section>
          </q-item>
          <q-item v-if="!imagesSupported" dense class="attach-hint">
            <q-item-section caption>
              {{ modelLabel }} can't read images
            </q-item-section>
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
      ref="fileInput"
      type="file"
      accept="image/png,image/jpeg"
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
    imagesSupported: {
      type: Boolean,
      default: true
    },
    showNewChat: {
      type: Boolean,
      default: false
    },
    modelLabel: {
      type: String,
      default: 'This model'
    }
  },
  emits: ['files-selected', 'new-chat'],

  methods: {
    pickFiles () {
      if (!this.imagesSupported) return
      this.$refs.fileInput.click()
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
.attach-hint {
  max-width: 240px;
}
</style>

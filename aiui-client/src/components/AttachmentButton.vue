<template>
  <div class="attachment-button">
    <q-btn icon="add" color="secondary" round flat>
      <q-tooltip>Attach or start a new chat</q-tooltip>
      <q-menu anchor="top left" self="bottom left">
        <q-list style="min-width: 240px">
          <q-item v-close-popup clickable :disable="imageInput === 'unsupported'" @click="pickFiles">
            <q-item-section avatar>
              <q-icon name="image" />
            </q-item-section>
            <q-item-section>Attach image</q-item-section>
          </q-item>
          <q-item v-if="imageInput !== 'supported'" dense class="attach-hint">
            <q-item-section caption>
              <template v-if="imageInput === 'unknown'">
                Image support for {{ modelLabel }} could not be verified. You can attach images, but confirmation is required when sending.
                <q-btn flat dense no-caps size="sm" label="Check again" @click.stop="$emit('refresh-capability')" />
              </template>
              <template v-else>{{ modelLabel }} can't read images</template>
            </q-item-section>
          </q-item>

          <q-separator />
          <q-item dense>
            <q-item-section>
              <q-input
                v-model.number="megapixels"
                dense
                type="number"
                label="Resize cap (MP)"
                :min="2.0736"
                :max="25"
                :step="0.1"
                suffix="MP"
                @keydown.enter.prevent="savePixelBudget"
                @blur="savePixelBudget"
              />
              <div class="text-caption text-grey-6 q-mt-xs">Applies only to later uploads.</div>
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
      accept="image/png,image/jpeg,image/webp"
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
    imageInput: {
      type: String,
      default: 'unknown'
    },
    imageMaxPixels: {
      type: Number,
      default: 6000000
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
  emits: ['files-selected', 'new-chat', 'update:image-max-pixels', 'refresh-capability'],

  data () {
    return { megapixels: this.imageMaxPixels / 1000000 }
  },

  watch: {
    imageMaxPixels (value) {
      this.megapixels = value / 1000000
    }
  },

  methods: {
    pickFiles () {
      if (this.imageInput === 'unsupported') return
      this.$refs.fileInput.click()
    },
    savePixelBudget () {
      const pixels = Math.round(Number(this.megapixels) * 1000000)
      if (!Number.isFinite(pixels) || pixels < 2073600 || pixels > 25000000) {
        this.megapixels = this.imageMaxPixels / 1000000
        this.$q.notify({
          type: 'negative',
          message: 'Image resize cap must be between 2.0736 and 25 MP',
          timeout: 2200
        })
        return
      }
      if (pixels !== this.imageMaxPixels) this.$emit('update:image-max-pixels', pixels)
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

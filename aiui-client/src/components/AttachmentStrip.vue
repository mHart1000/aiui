<template>
  <div v-if="attachments.length" class="attachment-strip">
    <div
      v-for="(attachment, index) in attachments"
      :key="attachment.url || `${attachment.filename}-${index}`"
      class="attachment-thumb"
    >
      <img
        v-if="attachment.kind === 'image'"
        :src="attachment.url"
        :alt="attachment.filename"
        class="attachment-image"
      />
      <q-icon v-else name="picture_as_pdf" size="36px" color="negative" class="pdf-icon" />

      <q-btn
        class="attachment-remove"
        icon="close"
        size="xs"
        round
        dense
        unelevated
        :aria-label="`Remove ${attachment.filename}`"
        @click="$emit('remove', index)"
      />
      <q-tooltip>{{ attachment.filename }}</q-tooltip>
    </div>
    <q-input
      v-if="hasPdfAttachments"
      :model-value="pdfTextLimit"
      type="number"
      dense
      outlined
      min="1000"
      max="48000"
      step="1000"
      label="Total PDF text limit"
      suffix="chars"
      class="pdf-text-limit"
      @update:model-value="$emit('update:pdf-text-limit', Number($event))"
    />
  </div>
</template>

<script>
export default {
  name: 'AttachmentStrip',

  props: {
    attachments: {
      type: Array,
      default: () => []
    },
    pdfTextLimit: {
      type: Number,
      default: 128000
    }
  },
  emits: ['remove', 'update:pdf-text-limit'],
  computed: {
    hasPdfAttachments () {
      return this.attachments.some(attachment => attachment.kind === 'pdf')
    }
  }
}
</script>

<style scoped>
.attachment-strip {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  padding: 8px 8px 0;
}
.attachment-thumb {
  position: relative;
  width: 64px;
  height: 64px;
  border-radius: 8px;
  overflow: hidden;
}
.attachment-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.attachment-remove {
  position: absolute;
  top: 2px;
  right: 2px;
  background: rgba(0, 0, 0, 0.55);
  color: white;
}
.pdf-icon {
  width: 100%;
  height: 100%;
  display: grid;
  place-items: center;
  background: #f5f5f5;
}
.pdf-text-limit {
  width: 180px;
  align-self: center;
}
</style>

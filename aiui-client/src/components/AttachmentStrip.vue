<template>
  <div v-if="attachments.length" class="attachment-strip">
    <div
      v-for="(attachment, index) in attachments"
      :key="attachment.signedId || attachment.url"
      class="attachment-thumb"
    >
      <img :src="attachment.url" :alt="attachment.filename" class="attachment-image" />

      <div v-if="attachment.uploading" class="attachment-overlay">
        <q-spinner size="20px" color="white" />
      </div>
      <div v-else-if="attachment.failed" class="attachment-overlay">
        <q-icon name="error_outline" size="20px" color="negative" />
        <q-tooltip>{{ attachment.error || 'Upload failed' }}</q-tooltip>
      </div>

      <q-btn
        class="attachment-remove"
        icon="close"
        size="xs"
        round
        dense
        unelevated
        @click="$emit('remove', index)"
      />
      <q-tooltip>{{ attachment.filename }}</q-tooltip>
    </div>
  </div>
</template>

<script>
export default {
  name: 'AttachmentStrip',

  props: {
    attachments: {
      type: Array,
      default: () => []
    }
  },
  emits: ['remove']
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
.attachment-overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.45);
}
.attachment-remove {
  position: absolute;
  top: 2px;
  right: 2px;
  background: rgba(0, 0, 0, 0.55);
  color: white;
}
</style>

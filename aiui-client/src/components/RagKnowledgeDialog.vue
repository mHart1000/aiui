<template>
  <q-dialog :model-value="modelValue" @update:model-value="$emit('update:modelValue', $event)">
    <q-card style="min-width: 520px; max-width: 720px">
      <q-card-section class="row items-center q-pb-none">
        <div class="text-h6">Knowledge</div>
        <q-space />
        <q-btn icon="close" flat round dense v-close-popup />
      </q-card-section>

      <q-card-section>
        <p class="text-caption text-grey-7 q-mb-sm">
          Upload documents for the assistant to draw on. PDF, DOCX, TXT, MD, JSON.
          Turn on "Personal Context" in a chat to use them.
        </p>

        <div class="row items-center q-gutter-sm q-mb-md">
          <input
            ref="fileInput"
            type="file"
            multiple
            accept=".pdf,.txt,.md,.docx,.json"
            style="display: none"
            @change="onFileChosen"
          />
          <q-btn
            color="primary"
            icon="upload_file"
            label="Upload"
            :loading="uploading"
            @click="$refs.fileInput.click()"
          />
          <q-btn flat icon="refresh" label="Refresh" @click="fetchDocuments" :loading="loading" />
        </div>

        <q-banner v-if="error" class="bg-negative text-white q-mb-md">
          {{ error }}
        </q-banner>

        <q-list bordered separator v-if="documents.length">
          <q-item v-for="doc in documents" :key="doc.id">
            <q-item-section>
              <q-item-label class="ellipsis" :title="doc.original_filename">
                {{ doc.original_filename || doc.title }}
              </q-item-label>
              <q-item-label caption>
                {{ doc.file_format?.toUpperCase() }} ·
                {{ doc.chunk_count }} chunks ·
                <span :class="statusClass(doc.status)">{{ doc.status }}</span>
                <span v-if="doc.error_message" class="text-negative q-ml-sm" :title="doc.error_message">
                  ({{ doc.error_message }})
                </span>
              </q-item-label>
            </q-item-section>
            <q-item-section side>
              <q-btn
                flat
                dense
                round
                icon="delete"
                color="negative"
                @click="deleteDocument(doc)"
              />
            </q-item-section>
          </q-item>
        </q-list>
        <div v-else-if="!loading" class="text-grey-6 text-body2 q-py-md text-center">
          No documents uploaded yet.
        </div>
      </q-card-section>
    </q-card>
  </q-dialog>
</template>

<script>
import { api } from 'boot/axios'

export default {
  name: 'RagKnowledgeDialog',
  props: {
    modelValue: { type: Boolean, default: false }
  },
  emits: ['update:modelValue'],
  data: () => ({
    documents: [],
    loading: false,
    uploading: false,
    error: null,
    pollTimer: null
  }),
  watch: {
    modelValue(open) {
      if (open) {
        this.fetchDocuments()
        this.startPollingIfNeeded()
      } else {
        this.stopPolling()
      }
    }
  },
  beforeUnmount() {
    this.stopPolling()
  },
  methods: {
    statusClass(status) {
      return {
        pending: 'text-grey-6',
        processing: 'text-warning',
        ready: 'text-positive',
        failed: 'text-negative'
      }[status] || ''
    },
    async fetchDocuments() {
      this.loading = true
      this.error = null
      try {
        const res = await api.get('/api/rag_documents')
        this.documents = res.data
        this.startPollingIfNeeded()
      } catch (err) {
        this.error = err.response?.data?.error || 'Failed to load documents'
      } finally {
        this.loading = false
      }
    },
    startPollingIfNeeded() {
      const hasInFlight = this.documents.some(d => d.status === 'pending' || d.status === 'processing')
      if (hasInFlight && !this.pollTimer) {
        this.pollTimer = setInterval(() => this.fetchDocuments(), 3000)
      } else if (!hasInFlight) {
        this.stopPolling()
      }
    },
    stopPolling() {
      if (this.pollTimer) {
        clearInterval(this.pollTimer)
        this.pollTimer = null
      }
    },
    async onFileChosen(event) {
      const files = Array.from(event.target.files || [])
      if (!files.length) return
      this.uploading = true
      this.error = null
      const failures = []
      try {
        for (const file of files) {
          try {
            const formData = new FormData()
            formData.append('file', file)
            await api.post('/api/rag_documents', formData, {
              headers: { 'Content-Type': 'multipart/form-data' }
            })
          } catch (err) {
            failures.push(`${file.name}: ${err.response?.data?.error || 'upload failed'}`)
          }
        }
        event.target.value = ''
        if (failures.length) {
          this.error = failures.join('; ')
        }
        await this.fetchDocuments()
      } finally {
        this.uploading = false
      }
    },
    async deleteDocument(doc) {
      try {
        await api.delete(`/api/rag_documents/${doc.id}`)
        this.documents = this.documents.filter(d => d.id !== doc.id)
      } catch (err) {
        this.error = err.response?.data?.error || 'Delete failed'
      }
    }
  }
}
</script>

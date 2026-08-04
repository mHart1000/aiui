<template>
  <q-dialog :model-value="modelValue" @update:model-value="$emit('update:modelValue', $event)">
    <q-card style="min-width: 560px; max-width: 760px">
      <q-card-section class="row items-center q-pb-none">
        <div class="text-h6">{{ editing ? editorTitle : 'Skills' }}</div>
        <q-space />
        <q-btn icon="close" flat round dense v-close-popup />
      </q-card-section>

      <q-card-section>
        <q-banner v-if="error" class="bg-negative text-white q-mb-md">
          {{ error }}
        </q-banner>

        <div v-if="editing">
          <q-input v-model="form.name" label="Name" dense outlined class="q-mb-sm" />
          <q-input
            v-model="form.description"
            label="Description"
            hint="What this skill is for. Shown in the list."
            dense
            outlined
            class="q-mb-md"
          />
          <q-input v-model="form.body" label="Instructions" type="textarea" rows="12" dense outlined />
          <div class="row justify-end q-gutter-sm q-mt-md">
            <q-btn flat label="Cancel" @click="cancelEdit" />
            <q-btn color="primary" label="Save" :loading="saving" @click="saveSkill" />
          </div>
        </div>

        <template v-else>
          <p class="text-caption text-grey-7 q-mb-sm">
            Instruction modules that layer on top of your persona. Checked skills apply to this chat.
          </p>

          <q-list bordered separator v-if="skills.length">
            <q-item v-for="skill in skills" :key="skill.id">
              <q-item-section side top>
                <q-checkbox
                  :model-value="activeIds.includes(skill.id)"
                  @update:model-value="toggle(skill.id, $event)"
                />
              </q-item-section>
              <q-item-section>
                <q-item-label>{{ skill.name }}</q-item-label>
                <q-item-label caption>{{ skill.description }}</q-item-label>
              </q-item-section>
              <q-item-section side>
                <div class="row no-wrap">
                  <q-btn flat dense round icon="edit" @click="startEdit(skill)" />
                  <q-btn flat dense round icon="delete" color="negative" @click="deleteSkill(skill)" />
                </div>
              </q-item-section>
            </q-item>
          </q-list>
          <div v-else-if="!loading" class="text-grey-6 text-body2 q-py-md text-center">
            No skills yet.
          </div>

          <div class="row items-center q-gutter-sm q-mt-md">
            <q-btn color="primary" icon="add" label="New Skill" @click="startCreate" />
            <q-space />
            <q-btn
              flat
              label="Save as my defaults"
              :loading="savingDefaults"
              @click="saveDefaults"
            />
          </div>
        </template>
      </q-card-section>
    </q-card>
  </q-dialog>
</template>

<script>
import { api } from 'boot/axios'

export default {
  name: 'SkillsDialog',
  props: {
    modelValue: { type: Boolean, default: false },
    activeIds: { type: Array, default: () => [] }
  },
  emits: ['update:modelValue', 'update:activeIds'],
  data: () => ({
    skills: [],
    loading: false,
    saving: false,
    savingDefaults: false,
    error: null,
    editing: null,
    form: { name: '', description: '', body: '' }
  }),
  computed: {
    editorTitle() {
      return this.editing?.id ? 'Edit Skill' : 'New Skill'
    }
  },
  watch: {
    modelValue(open) {
      if (open) {
        this.cancelEdit()
        this.fetchSkills()
      }
    }
  },
  methods: {
    errorFrom(err, fallback) {
      return err.response?.data?.errors?.join(', ') || fallback
    },
    async fetchSkills() {
      this.loading = true
      this.error = null
      try {
        const res = await api.get('/api/skills')
        this.skills = res.data
      } catch (err) {
        this.error = this.errorFrom(err, 'Failed to load skills')
      } finally {
        this.loading = false
      }
    },
    toggle(id, checked) {
      const next = checked
        ? [...this.activeIds, id]
        : this.activeIds.filter(x => x !== id)
      this.$emit('update:activeIds', next)
    },
    startCreate() {
      this.editing = { id: null }
      this.form = { name: '', description: '', body: '' }
    },
    startEdit(skill) {
      this.editing = skill
      this.form = { name: skill.name, description: skill.description || '', body: skill.body }
    },
    cancelEdit() {
      this.editing = null
      this.error = null
    },
    async saveSkill() {
      this.saving = true
      this.error = null
      try {
        if (this.editing.id) {
          await api.patch(`/api/skills/${this.editing.id}`, { skill: this.form })
        } else {
          await api.post('/api/skills', { skill: this.form })
        }
        this.editing = null
        await this.fetchSkills()
      } catch (err) {
        this.error = this.errorFrom(err, 'Save failed')
      } finally {
        this.saving = false
      }
    },
    async deleteSkill(skill) {
      this.error = null
      try {
        await api.delete(`/api/skills/${skill.id}`)
        this.skills = this.skills.filter(s => s.id !== skill.id)
        if (this.activeIds.includes(skill.id)) {
          this.$emit('update:activeIds', this.activeIds.filter(x => x !== skill.id))
        }
      } catch (err) {
        this.error = this.errorFrom(err, 'Delete failed')
      }
    },
    // Writes the current checkbox state onto the skills themselves, so new chats inherit it.
    async saveDefaults() {
      this.savingDefaults = true
      this.error = null
      try {
        const changed = this.skills.filter(s => s.enabled_by_default !== this.activeIds.includes(s.id))
        for (const skill of changed) {
          await api.patch(`/api/skills/${skill.id}`, {
            skill: { enabled_by_default: this.activeIds.includes(skill.id) }
          })
        }
        await api.patch('/api/user', { user: { use_skills: true } })
        await this.fetchSkills()
        this.$q.notify({ type: 'positive', message: 'Defaults saved', position: 'top', timeout: 1500 })
      } catch (err) {
        this.error = this.errorFrom(err, 'Failed to save defaults')
      } finally {
        this.savingDefaults = false
      }
    }
  }
}
</script>

<template>
  <q-layout view="hHh lpR fFf">
    <q-drawer show-if-above bordered width="260">
      <div class="q-pa-md column justify-between full-height">
        <div>
          <q-btn flat icon="add" label="New Chat" class="full-width q-mb-md" />
          <q-list dense>
            <q-item v-for="c in conversations" :key="c.id" clickable>
              <q-item-section>{{ c.title }}</q-item-section>
            </q-item>
          </q-list>
        </div>
        <div class="column items-center">
          <q-btn label="Sign Out" color="primary" @click="logout" />
          <div class="text-caption text-grey">Model: GPT-5<br>Budget: $10.00</div>
          <q-btn @click="toggleDark" label="Toggle Dark" />
        </div>
      </div>
    </q-drawer>

    <q-page-container>
      <router-view />
    </q-page-container>
  </q-layout>
</template>

<script>
import { Dark } from 'quasar';
export default {
  name: 'ChatLayout',
  data: () => ({
    conversations: [
      { id: 1, title: 'Welcome' },
      { id: 2, title: 'System prompt test' }
    ]
  }),
  methods: {
    toggleDark() {
      Dark.toggle();
    },
    logout() {
      localStorage.removeItem('jwt')
      this.$router.replace('/login')
    }
  }
}
</script>

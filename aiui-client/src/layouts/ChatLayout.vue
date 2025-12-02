<template>
  <q-layout view="hHh LpR fFf">
    <q-drawer show-if-above bordered width="260" class="bg-panel">
      <q-scroll-area class="fit">
        <div class="q-pa-md column justify-between full-height">
          <div>
            <q-btn
              flat
              icon="add"
              label="New Chat"
              class="full-width q-mb-md"
              @click="$router.push('/chat')"
            />
            <q-list dense>
              <q-item
                v-for="c in conversations"
                :key="c.id"
                clickable
                @click="$router.push(`/chat/${c.id}`)"
              >
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
      </q-scroll-area>
    </q-drawer>

    <q-page-container>
      <router-view />
    </q-page-container>
  </q-layout>
</template>

<script>
import { Dark } from 'quasar'
import { api } from 'src/boot/axios'

export default {
  name: 'ChatLayout',
  data: () => ({
    conversations: []
  }),
  mounted() {
    this.getUserConversations()
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
          this.conversations = response.data.sort((a, b) => b.id - a.id)
        })
        .catch(error => {
          console.error('Error fetching conversations:', error)
        });
    }
  }
}
</script>

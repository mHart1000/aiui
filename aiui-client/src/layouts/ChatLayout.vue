<template>
  <q-layout view="hHh lpR fFf">
    <q-drawer show-if-above bordered width="260">
      <div class="q-pa-md column justify-between full-height">
        <div>
          <q-btn flat icon="add" label="New Chat" class="full-width q-mb-md" @click="createNewChat"/>
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
    </q-drawer>

    <q-page-container>
      <router-view />
    </q-page-container>
  </q-layout>
</template>

<script>
import { Dark } from 'quasar';
import { api } from 'src/boot/axios';

export default {
  name: 'ChatLayout',
  data: () => ({
    conversations: []
  }),
  mounted() {
    console.log('ChatLayout mounted');
    this.getUserConversations();
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
          this.conversations = response.data;
        })
        .catch(error => {
          console.error('Error fetching conversations:', error);
        });
    },
    async createNewChat() {
      try {
        const response = await api.post('/api/conversations')
        const newConversation = response.data;
        this.$router.push(`/chat/${newConversation.id}`);
      } catch (error) {
        console.error('Error creating new conversation:', error);
      }
    }

  }
}
</script>

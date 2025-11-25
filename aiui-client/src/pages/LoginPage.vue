<template>
  <q-page padding class="column items-center justify-center">
    <div class="q-pa-md q-gutter-md" style="max-width: 400px; width: 100%">
      <q-input filled v-model="email" label="Email" />
      <q-input filled v-model="password" type="password" label="Password" />

      <q-btn color="primary" label="Log In" @click="login" class="full-width" />

      <div class="text-center q-mt-md">
        Don't have an account?
        <q-btn flat color="primary" label="Sign Up" to="/signup" />
      </div>
    </div>
  </q-page>
</template>

<script>
import { api } from 'boot/axios'

export default {
  name: 'LoginPage',
  data: () => ({
    email: '',
    password: ''
  }),
  mounted() {
    const token = localStorage.getItem('jwt')
    if (token) {
      this.$router.push('/chat')
    }
  },
  methods: {
    async login() {
      try {
        const res = await api.post('/api/login', {
          user: { email: this.email, password: this.password }
        })

        localStorage.setItem('jwt', res.data.token)
        this.$router.push('/chat')
      } catch (err) {
        console.error(err)
      }
    }
  }
}
</script>

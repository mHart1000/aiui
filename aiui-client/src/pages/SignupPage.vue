<template>
  <q-page padding class="column items-center justify-center">
    <div class="q-pa-md q-gutter-md" style="max-width: 400px; width: 100%">
      <q-input filled v-model="email" label="Email" />
      <q-input filled v-model="password" type="password" label="Password" />
      <q-input filled v-model="passwordConfirmation" type="password" label="Confirm Password" />

      <q-btn color="primary" label="Sign Up" @click="signup" class="full-width" />

      <div class="text-center q-mt-md">
        Already have an account?
        <q-btn flat color="primary" label="Log in" to="/login" />
      </div>
    </div>
  </q-page>
</template>

<script>
import { api } from 'boot/axios'

export default {
  name: 'SignupPage',
  data: () => ({
    email: '',
    password: '',
    passwordConfirmation: ''
  }),
  methods: {
    async signup() {
      try {
        const res = await api.post('/signup', {
          user: {
            email: this.email,
            password: this.password,
            password_confirmation: this.passwordConfirmation
          }
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

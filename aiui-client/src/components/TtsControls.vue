<template>
  <div class="tts-controls row items-center q-gutter-sm">
    <!-- TTS Enable Toggle -->
    <q-toggle
      :model-value="isEnabled"
      @update:model-value="$emit('update:enabled', $event)"
      :disable="!isTtsAvailable"
      color="primary"
      icon="volume_up"
      :label="isTtsAvailable ? 'Voice' : 'Voice (unavailable)'"
    >
      <q-tooltip v-if="!isTtsAvailable">
        TTS service is not available. Make sure the Kokoro server is running.
      </q-tooltip>
    </q-toggle>

    <!-- Playback Controls (shown when TTS is enabled and playing/paused) -->
    <div v-if="isEnabled && (isPlaying || isPaused)" class="row items-center q-gutter-xs">
      <q-btn
        v-if="!isPlaying && isPaused"
        round
        flat
        dense
        icon="play_arrow"
        color="primary"
        @click="$emit('resume')"
        size="sm"
      >
        <q-tooltip>Resume</q-tooltip>
      </q-btn>

      <q-btn
        v-if="isPlaying"
        round
        flat
        dense
        icon="pause"
        color="primary"
        @click="$emit('pause')"
        size="sm"
      >
        <q-tooltip>Pause</q-tooltip>
      </q-btn>

      <q-btn
        round
        flat
        dense
        icon="stop"
        color="negative"
        @click="$emit('stop')"
        size="sm"
      >
        <q-tooltip>Stop</q-tooltip>
      </q-btn>
    </div>

    <!-- Voice Selector -->
    <q-select
      v-if="isEnabled && availableVoices.length > 0"
      :model-value="currentVoice"
      @update:model-value="$emit('update:voice', $event)"
      :options="availableVoices"
      label="Voice"
      dense
      style="min-width: 150px; max-width: 200px"
    />

    <!-- Speed Control -->
    <div v-if="isEnabled" class="row items-center q-gutter-xs" style="min-width: 120px">
      <q-icon name="speed" size="xs" />
      <q-slider
        :model-value="speed"
        @update:model-value="$emit('update:speed', $event)"
        :min="0.5"
        :max="2.0"
        :step="0.1"
        :label-value="speed.toFixed(1) + 'x'"
        label-always
        dense
        style="flex: 1"
      />
    </div>
  </div>
</template>

<script>
export default {
  name: 'TtsControls',

  props: {
    isEnabled: {
      type: Boolean,
      required: true
    },
    isPlaying: {
      type: Boolean,
      required: true
    },
    isPaused: {
      type: Boolean,
      required: true
    },
    isTtsAvailable: {
      type: Boolean,
      required: true
    },
    currentVoice: {
      type: String,
      required: true
    },
    speed: {
      type: Number,
      required: true
    },
    availableVoices: {
      type: Array,
      required: true
    }
  },

  emits: [
    'update:enabled',
    'update:voice',
    'update:speed',
    'play',
    'pause',
    'resume',
    'stop'
  ]
}
</script>

<style scoped>
.tts-controls {
  padding: 8px;
  background: rgba(0, 0, 0, 0.02);
  border-radius: 4px;
}
</style>

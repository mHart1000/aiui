class VoskAudioWorkletProcessor extends AudioWorkletProcessor {
  process (inputs) {
    const input = inputs[0]
    if (!input || !input[0] || input[0].length === 0) return true

    // Copy because the underlying buffer is reused by the AudioWorklet engine
    const channel0 = input[0]
    const chunk = new Float32Array(channel0.length)
    chunk.set(channel0)

    this.port.postMessage(chunk, [chunk.buffer])
    return true
  }
}

registerProcessor('vosk-audio-worklet', VoskAudioWorkletProcessor)


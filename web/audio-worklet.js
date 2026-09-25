'use strict';

/*
  The page's audio output, on the audio rendering thread.

  The SPU produces 44100 Hz stereo 16-bit frames in batches of 128; the main thread transfers
  each batch here as an ArrayBuffer and this processor plays them back in order, silence where
  the queue runs dry. It keeps at most a quarter of a second queued: the runtime paces itself by
  the count reported back, and a queue allowed to grow would only add latency. The count goes
  back every eighth render quantum, about every 23 ms, which is what `audioBuffered` answers.

  Replaces the deprecated ScriptProcessorNode, which rendered on the main thread and stalled
  whenever the game did. A `flush` message empties the queue on pause.
*/
class RecompsxAudioProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.buffered = 0;
    this.quantum = 0;
    this.port.onmessage = (event) => {
      const data = event.data;
      if (data === 'flush') {
        this.queue.length = 0;
        this.buffered = 0;
        return;
      }
      const samples = new Int16Array(data);
      const frames = samples.length >> 1;
      this.queue.push({ samples, frames, at: 0 });
      this.buffered += frames;
      while (this.buffered > 11025 && this.queue.length > 1) {
        const dropped = this.queue.shift();
        this.buffered -= dropped.frames - dropped.at;
      }
    };
  }

  process(inputs, outputs) {
    const output = outputs[0];
    const left = output[0];
    const right = output.length > 1 ? output[1] : output[0];
    let at = 0;
    while (at < left.length && this.queue.length) {
      const item = this.queue[0];
      const take = Math.min(left.length - at, item.frames - item.at);
      const samples = item.samples;
      let s = item.at * 2;
      for (let i = 0; i < take; i++) {
        left[at + i] = samples[s] / 32768;
        right[at + i] = samples[s + 1] / 32768;
        s += 2;
      }
      item.at += take;
      at += take;
      this.buffered -= take;
      if (item.at === item.frames) this.queue.shift();
    }
    for (let i = at; i < left.length; i++) { left[i] = 0; right[i] = 0; }
    if ((++this.quantum & 7) === 0) this.port.postMessage(this.buffered);
    return true;
  }
}

registerProcessor('recompsx-audio', RecompsxAudioProcessor);

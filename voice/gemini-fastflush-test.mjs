#!/usr/bin/env node
// Probe: does Gemini Live's server VAD cope with prelude audio flushed much
// faster than realtime? Simulates the wake ring-buffer plan: dump the whole
// utterance at once on session open, then trickle silence like a live mic.
//
//   node gemini-fastflush-test.mjs [wav] [model]

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const env = Object.fromEntries(
  readFileSync(join(homedir(), ".config/neon/secrets.env"), "utf8")
    .split("\n").filter(l => l.includes("="))
    .map(l => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)])
);
const KEY = env.GEMINI_API_KEY;
const wavPath = process.argv[2] || "/tmp/neon-prelude16k.wav";
const model = process.argv[3] || "gemini-3.1-flash-live-preview";

const wav = readFileSync(wavPath);
const pcm = wav.subarray(wav.indexOf("data") + 8);
console.error(`flushing ${(pcm.length / 32000).toFixed(1)}s of speech instantly; model=${model}`);

const url = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${KEY}`;
const ws = new WebSocket(url);
const t0 = Date.now();
const ts = () => ((Date.now() - t0) / 1000).toFixed(2);
let transcript = "", heard = "", audioChunks = 0;

const deadline = setTimeout(() => { console.error("timed out after 40s"); process.exit(1); }, 40_000);

ws.addEventListener("open", () => {
  ws.send(JSON.stringify({
    setup: {
      model: `models/${model}`,
      generationConfig: { responseModalities: ["AUDIO"] },
      systemInstruction: { parts: [{ text: "You are Neon, a kitchen assistant. Keep replies very short." }] },
      outputAudioTranscription: {},
      inputAudioTranscription: {},
    },
  }));
});

ws.addEventListener("message", async event => {
  const text = typeof event.data === "string"
    ? event.data
    : Buffer.from(await event.data.arrayBuffer()).toString();
  const msg = JSON.parse(text);

  if (msg.setupComplete !== undefined) {
    console.error(`${ts()} setup complete; instant flush`);
    // The whole prelude in one message — the wake plan's worst case.
    ws.send(JSON.stringify({ realtimeInput: { audio: { mimeType: "audio/pcm;rate=16000", data: pcm.toString("base64") } } }));
    // Then behave like a live mic: 100 ms silence chunks.
    const silence = Buffer.alloc(3200);
    const trickle = setInterval(() => {
      if (ws.readyState !== 1) { clearInterval(trickle); return; }
      ws.send(JSON.stringify({ realtimeInput: { audio: { mimeType: "audio/pcm;rate=16000", data: silence.toString("base64") } } }));
    }, 100);
    return;
  }

  const sc = msg.serverContent;
  if (!sc) return;
  if (sc.modelTurn?.parts?.some(p => p.inlineData)) {
    if (audioChunks === 0) console.error(`${ts()} first reply audio`);
    audioChunks++;
  }
  if (sc.inputTranscription?.text) heard += sc.inputTranscription.text;
  if (sc.outputTranscription?.text) transcript += sc.outputTranscription.text;
  if (sc.turnComplete) {
    clearTimeout(deadline);
    console.log(`heard:   ${heard.trim() || "(none)"}`);
    console.log(`replied: ${transcript.trim() || "(none)"}`);
    console.log(`chunks:  ${audioChunks}`);
    process.exit(transcript ? 0 : 1);
  }
});

ws.addEventListener("close", e => { console.error(`closed: ${e.code} ${e.reason}`); process.exit(1); });

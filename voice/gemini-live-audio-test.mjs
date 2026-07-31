#!/usr/bin/env node
// Probe the Gemini Live realtimeInput audio path: stream a prerecorded 16 kHz
// WAV as if it were mic audio, let server-side VAD detect the end of speech,
// and play the spoken reply. Validates the exact message schema the Swift
// VoiceSession will use.
//
//   node gemini-live-audio-test.mjs [wav] [model]

import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const env = Object.fromEntries(
  readFileSync(join(homedir(), ".config/neon/secrets.env"), "utf8")
    .split("\n").filter(l => l.includes("="))
    .map(l => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)])
);
const KEY = env.GEMINI_API_KEY;

const wavPath = process.argv[2] || "/tmp/neon-probe16k.wav";
const model = process.argv[3] || "gemini-2.5-flash-native-audio-latest";

// Extract PCM from the WAV's data chunk
const wav = readFileSync(wavPath);
const dataAt = wav.indexOf("data");
const pcmIn = wav.subarray(dataAt + 8);
console.error(`streaming ${(pcmIn.length / 32000).toFixed(1)}s of audio from ${wavPath}`);

const url = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${KEY}`;
const ws = new WebSocket(url);
const audioOut = [];
let inTx = "", outTx = "";

const deadline = setTimeout(() => { console.error("timed out after 45s"); process.exit(1); }, 45_000);

ws.addEventListener("open", () => {
  ws.send(JSON.stringify({
    setup: {
      model: `models/${model}`,
      generationConfig: { responseModalities: ["AUDIO"] },
      systemInstruction: { parts: [{ text: "You are Neon, a helpful kitchen assistant. Keep replies very short." }] },
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
    console.error("setup complete; streaming audio in ~real time");
    streamAudio();
    return;
  }
  if (msg.error) { console.error("SERVER ERROR:", JSON.stringify(msg.error)); process.exit(1); }

  const sc = msg.serverContent;
  if (!sc) { console.error("other message:", Object.keys(msg).join(",")); return; }
  if (sc.interrupted) console.error("[interrupted]");
  for (const part of sc.modelTurn?.parts ?? []) {
    if (part.inlineData?.data) audioOut.push(Buffer.from(part.inlineData.data, "base64"));
  }
  if (sc.inputTranscription?.text) inTx += sc.inputTranscription.text;
  if (sc.outputTranscription?.text) outTx += sc.outputTranscription.text;
  if (sc.turnComplete) { clearTimeout(deadline); ws.close(); finish(); }
});

ws.addEventListener("close", e => {
  if (audioOut.length === 0) { console.error(`closed early: ${e.code} ${e.reason}`); process.exit(1); }
});

async function streamAudio() {
  // 100 ms chunks at 16 kHz mono int16 = 3200 bytes, paced like a live mic
  const CHUNK = 3200;
  const silence = Buffer.alloc(CHUNK);
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  for (let off = 0; off < pcmIn.length; off += CHUNK) {
    sendChunk(pcmIn.subarray(off, off + CHUNK));
    await sleep(95);
  }
  console.error("speech sent; trailing silence for VAD");
  for (let i = 0; i < 20; i++) { sendChunk(silence); await sleep(95); }
}

function sendChunk(buf) {
  if (ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({
    realtimeInput: { audio: { mimeType: "audio/pcm;rate=16000", data: buf.toString("base64") } },
  }));
}

function finish() {
  const pcm = Buffer.concat(audioOut);
  const out = "/tmp/neon-audio-reply.wav";
  const h = Buffer.alloc(44);
  h.write("RIFF", 0); h.writeUInt32LE(36 + pcm.length, 4); h.write("WAVE", 8);
  h.write("fmt ", 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20);
  h.writeUInt16LE(1, 22); h.writeUInt32LE(24000, 24); h.writeUInt32LE(48000, 28);
  h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write("data", 36); h.writeUInt32LE(pcm.length, 40);
  writeFileSync(out, Buffer.concat([h, pcm]));
  console.log(`heard:   ${inTx.trim() || "(no input transcription)"}`);
  console.log(`replied: ${outTx.trim()}`);
  console.log(`audio:   ${(pcm.length / 48000).toFixed(1)}s -> ${out}`);
  execFileSync("afplay", [out], { stdio: "inherit" });
}

#!/usr/bin/env node
// Probe the OpenAI Realtime API: stream a prerecorded 24 kHz WAV as fake mic
// audio, let server VAD end the turn, play the spoken reply, and print the
// usage block. Validates the exact schema for the Swift engine.
//
//   node openai-realtime-test.mjs [wav] [model]

import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const env = Object.fromEntries(
  readFileSync(join(homedir(), ".config/neon/secrets.env"), "utf8")
    .split("\n").filter(l => l.includes("="))
    .map(l => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)])
);
const KEY = env.OPENAI_API_KEY;

const wavPath = process.argv[2] || "/tmp/neon-probe24k.wav";
const model = process.argv[3] || "gpt-realtime-2.1";

const wav = readFileSync(wavPath);
const pcmIn = wav.subarray(wav.indexOf("data") + 8);
console.error(`streaming ${(pcmIn.length / 48000).toFixed(1)}s of 24k audio; model=${model}`);

const ws = new WebSocket(`wss://api.openai.com/v1/realtime?model=${model}`, {
  headers: { Authorization: `Bearer ${KEY}` },
});

const audioOut = [];
let outTx = "", inTx = "";
const seen = new Set();
const deadline = setTimeout(() => { console.error("timed out after 45s"); finish(); }, 45_000);

ws.addEventListener("open", () => {
  ws.send(JSON.stringify({
    type: "session.update",
    session: {
      type: "realtime",
      instructions: "You are Neon, a helpful kitchen assistant. Keep replies very short.",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: 24000 },
          turn_detection: { type: "server_vad" },
          transcription: { model: "whisper-1" },
        },
        output: {
          format: { type: "audio/pcm", rate: 24000 },
          voice: "marin",
        },
      },
    },
  }));
  streamAudio();
});

ws.addEventListener("message", async event => {
  const text = typeof event.data === "string"
    ? event.data
    : Buffer.from(await event.data.arrayBuffer()).toString();
  const msg = JSON.parse(text);
  if (!seen.has(msg.type)) { seen.add(msg.type); console.error("event:", msg.type); }

  switch (msg.type) {
    case "error":
      console.error("SERVER ERROR:", JSON.stringify(msg.error ?? msg));
      break;
    case "response.output_audio.delta":
      audioOut.push(Buffer.from(msg.delta, "base64"));
      break;
    case "response.output_audio_transcript.delta":
      outTx += msg.delta;
      break;
    case "conversation.item.input_audio_transcription.completed":
      inTx += msg.transcript ?? "";
      break;
    case "response.done":
      console.error("usage:", JSON.stringify(msg.response?.usage ?? {}));
      clearTimeout(deadline);
      ws.close();
      finish();
      break;
  }
});

ws.addEventListener("close", e => {
  if (audioOut.length === 0) { console.error(`closed early: ${e.code} ${e.reason}`); process.exit(1); }
});

async function streamAudio() {
  const CHUNK = 4800; // 100 ms @ 24 kHz mono int16
  const silence = Buffer.alloc(CHUNK);
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  for (let off = 0; off < pcmIn.length; off += CHUNK) {
    ws.send(JSON.stringify({ type: "input_audio_buffer.append", audio: pcmIn.subarray(off, off + CHUNK).toString("base64") }));
    await sleep(95);
  }
  console.error("speech sent; trailing silence for VAD");
  for (let i = 0; i < 20; i++) {
    ws.send(JSON.stringify({ type: "input_audio_buffer.append", audio: silence.toString("base64") }));
    await sleep(95);
  }
}

function finish() {
  const pcm = Buffer.concat(audioOut);
  if (pcm.length === 0) { console.error("no audio received"); process.exit(1); }
  const out = "/tmp/neon-openai-reply.wav";
  const h = Buffer.alloc(44);
  h.write("RIFF", 0); h.writeUInt32LE(36 + pcm.length, 4); h.write("WAVE", 8);
  h.write("fmt ", 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20);
  h.writeUInt16LE(1, 22); h.writeUInt32LE(24000, 24); h.writeUInt32LE(48000, 28);
  h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write("data", 36); h.writeUInt32LE(pcm.length, 40);
  writeFileSync(out, Buffer.concat([h, pcm]));
  console.log(`heard:   ${inTx.trim() || "(none)"}`);
  console.log(`replied: ${outTx.trim()}`);
  console.log(`audio:   ${(pcm.length / 48000).toFixed(1)}s -> ${out}`);
  execFileSync("afplay", [out], { stdio: "inherit" });
}

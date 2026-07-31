#!/usr/bin/env node
// Minimal Gemini Live API round trip: open a session, send one text turn,
// save + play the spoken reply. Proves key, model, and protocol before any
// Swift work. No dependencies — uses Node's built-in WebSocket (Node 22+).
//
//   node gemini-live-test.mjs [model] [prompt...]

import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

// ---------------------------------------------------------------- secrets
const env = Object.fromEntries(
  readFileSync(join(homedir(), ".config/neon/secrets.env"), "utf8")
    .split("\n")
    .filter(l => l.includes("="))
    .map(l => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)])
);
const KEY = env.GEMINI_API_KEY;
if (!KEY) throw new Error("GEMINI_API_KEY not found in ~/.config/neon/secrets.env");

const model = process.argv[2] || "gemini-2.5-flash-native-audio-latest";
const prompt =
  process.argv.slice(3).join(" ") ||
  "Introduce yourself to Nick in a couple of sentences. This is the first time you have ever spoken out loud.";

const SYSTEM = `You are Neon, a new AI assistant who lives on a MacBook in
Nick's kitchen. You are named after the Valorant agent — quick, bright,
a little electric — and your visual form is a pair of glowing cyan eyes.
Keep spoken replies short and natural.`;

// ---------------------------------------------------------------- session
const url = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${KEY}`;
const ws = new WebSocket(url);
const audio = [];
let transcript = "";

const deadline = setTimeout(() => {
  console.error("timed out after 30s");
  process.exit(1);
}, 30_000);

ws.addEventListener("open", () => {
  console.error(`connected; model=${model}`);
  ws.send(JSON.stringify({
    setup: {
      model: `models/${model}`,
      generationConfig: { responseModalities: ["AUDIO"] },
      systemInstruction: { parts: [{ text: SYSTEM }] },
      outputAudioTranscription: {},
    },
  }));
});

ws.addEventListener("message", async event => {
  const text = typeof event.data === "string"
    ? event.data
    : Buffer.from(await event.data.arrayBuffer()).toString();
  const msg = JSON.parse(text);

  if (msg.setupComplete !== undefined) {
    console.error("setup complete; sending prompt");
    ws.send(JSON.stringify({
      clientContent: {
        turns: [{ role: "user", parts: [{ text: prompt }] }],
        turnComplete: true,
      },
    }));
    return;
  }

  const sc = msg.serverContent;
  if (!sc) return;
  for (const part of sc.modelTurn?.parts ?? []) {
    if (part.inlineData?.data) audio.push(Buffer.from(part.inlineData.data, "base64"));
  }
  if (sc.outputTranscription?.text) transcript += sc.outputTranscription.text;
  if (sc.turnComplete) {
    clearTimeout(deadline);
    ws.close();
    finish();
  }
});

ws.addEventListener("error", () => { console.error("websocket error"); process.exit(1); });
ws.addEventListener("close", e => {
  if (audio.length === 0) {
    console.error(`closed before audio arrived: code=${e.code} reason=${e.reason}`);
    process.exit(1);
  }
});

// ---------------------------------------------------------------- output
function finish() {
  const pcm = Buffer.concat(audio);
  const wav = wavify(pcm, 24_000);
  const out = "/tmp/neon-first-words.wav";
  writeFileSync(out, wav);
  const secs = (pcm.length / 2 / 24_000).toFixed(1);
  console.log(`audio: ${secs}s -> ${out}`);
  if (transcript) console.log(`transcript: ${transcript.trim()}`);
  execFileSync("afplay", [out], { stdio: "inherit" });
}

function wavify(pcm, rate) {
  const h = Buffer.alloc(44);
  h.write("RIFF", 0); h.writeUInt32LE(36 + pcm.length, 4); h.write("WAVE", 8);
  h.write("fmt ", 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20);
  h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28);
  h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write("data", 36); h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}

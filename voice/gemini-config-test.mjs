#!/usr/bin/env node
// Probe Gemini Live setup extras before they go into the Swift engine:
// Leda voice, thinking level, and Google Search grounding. A bad setup
// field errors or closes the socket; a good one returns setupComplete and
// a grounded spoken answer.
//
//   node gemini-config-test.mjs [model] [thinkingLevel|none]

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const env = Object.fromEntries(
  readFileSync(join(homedir(), ".config/neon/secrets.env"), "utf8")
    .split("\n").filter(l => l.includes("="))
    .map(l => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)])
);
const KEY = env.GEMINI_API_KEY;

const model = process.argv[2] || "gemini-3.1-flash-live-preview";
const thinking = process.argv[3] || "HIGH";

const generationConfig = {
  responseModalities: ["AUDIO"],
  speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: "Leda" } } },
};
if (thinking !== "none") generationConfig.thinkingConfig = { thinkingLevel: thinking };

const url = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${KEY}`;
const ws = new WebSocket(url);
let audioChunks = 0, transcript = "";

const deadline = setTimeout(() => { console.error("timed out after 45s"); process.exit(1); }, 45_000);

ws.addEventListener("open", () => {
  console.error(`connected; model=${model} thinking=${thinking}`);
  ws.send(JSON.stringify({
    setup: {
      model: `models/${model}`,
      generationConfig,
      systemInstruction: { parts: [{ text: "You are Neon, a kitchen assistant. Keep replies short." }] },
      outputAudioTranscription: {},
      tools: [
        { googleSearch: {} },
        { functionDeclarations: [{ name: "go_to_sleep", description: "End the conversation." }] },
      ],
    },
  }));
});

ws.addEventListener("message", async event => {
  const text = typeof event.data === "string"
    ? event.data
    : Buffer.from(await event.data.arrayBuffer()).toString();
  const msg = JSON.parse(text);

  if (msg.setupComplete !== undefined) {
    console.error("SETUP OK — asking a question that needs the web");
    ws.send(JSON.stringify({
      clientContent: {
        turns: [{ role: "user", parts: [{ text: "Quick: search the web — what is today's date and one current news headline?" }] }],
        turnComplete: true,
      },
    }));
    return;
  }
  if (msg.error) { console.error("SERVER ERROR:", JSON.stringify(msg).slice(0, 400)); process.exit(1); }

  const sc = msg.serverContent;
  if (!sc) { console.error("msg keys:", Object.keys(msg).join(",")); return; }
  if (sc.modelTurn?.parts?.some(p => p.inlineData)) audioChunks++;
  if (sc.outputTranscription?.text) transcript += sc.outputTranscription.text;
  if (sc.groundingMetadata) {
    const q = sc.groundingMetadata.webSearchQueries;
    console.error("GROUNDING:", JSON.stringify(q ?? Object.keys(sc.groundingMetadata)));
  }
  if (sc.turnComplete) {
    clearTimeout(deadline);
    console.log(`audio chunks: ${audioChunks}`);
    console.log(`said: ${transcript.trim()}`);
    process.exit(0);
  }
});

ws.addEventListener("close", e => { console.error(`closed: ${e.code} ${e.reason}`); process.exit(1); });

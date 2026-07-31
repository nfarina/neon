#!/usr/bin/env node
// Probe: does Gemini Live surface "the model is thinking" in the stream?
// Enables includeThoughts and logs the timing/shape of every serverContent
// message for a question that needs real thinking + search.
//
//   node gemini-thinking-test.mjs [model]

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

const url = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${KEY}`;
const ws = new WebSocket(url);
const t0 = Date.now();
const ts = () => ((Date.now() - t0) / 1000).toFixed(2).padStart(6);

const deadline = setTimeout(() => { console.error("timed out after 60s"); process.exit(1); }, 60_000);

ws.addEventListener("open", () => {
  ws.send(JSON.stringify({
    setup: {
      model: `models/${model}`,
      generationConfig: {
        responseModalities: ["AUDIO"],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: "Leda" } } },
        thinkingConfig: { thinkingLevel: "HIGH", includeThoughts: true },
      },
      systemInstruction: { parts: [{ text: "You are Neon, a kitchen assistant." }] },
      outputAudioTranscription: {},
      tools: [{ googleSearch: {} }],
    },
  }));
});

ws.addEventListener("message", async event => {
  const text = typeof event.data === "string"
    ? event.data
    : Buffer.from(await event.data.arrayBuffer()).toString();
  const msg = JSON.parse(text);

  if (msg.setupComplete !== undefined) {
    console.error(`${ts()} setup complete; asking`);
    ws.send(JSON.stringify({
      clientContent: {
        turns: [{ role: "user", parts: [{ text:
          "Search the web for tomorrow's weather in San Francisco and tell me if I need a jacket." }] }],
        turnComplete: true,
      },
    }));
    return;
  }

  const sc = msg.serverContent;
  if (!sc) { console.error(`${ts()} msg: ${Object.keys(msg).join(",")}`); return; }

  const desc = [];
  for (const p of sc.modelTurn?.parts ?? []) {
    if (p.thought) desc.push(`THOUGHT(${(p.text ?? "").slice(0, 60)}...)`);
    else if (p.inlineData) desc.push("audio");
    else if (p.text) desc.push(`text(${p.text.slice(0, 40)})`);
    else desc.push(`part keys: ${Object.keys(p).join("/")}`);
  }
  for (const k of Object.keys(sc)) if (k !== "modelTurn") desc.push(k);
  console.error(`${ts()} ${desc.join(" ")}`);

  if (sc.turnComplete) { clearTimeout(deadline); process.exit(0); }
});

ws.addEventListener("close", e => { console.error(`closed: ${e.code} ${e.reason}`); process.exit(1); });

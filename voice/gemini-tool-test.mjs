#!/usr/bin/env node
// Probe Gemini Live tool calling: declare a go_to_sleep function, send a text
// turn that should trigger it, and dump the raw toolCall message so the Swift
// parser can match the exact wire shape. Cheap: text in, tool call out.
//
//   node gemini-tool-test.mjs [model]

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

const deadline = setTimeout(() => { console.error("timed out after 30s"); process.exit(1); }, 30_000);

ws.addEventListener("open", () => {
  console.error(`connected; model=${model}`);
  ws.send(JSON.stringify({
    setup: {
      model: `models/${model}`,
      generationConfig: { responseModalities: ["AUDIO"] },
      systemInstruction: { parts: [{ text:
        "You are Neon, a kitchen assistant. When the conversation is over, " +
        "or you were woken by mistake, call go_to_sleep." }] },
      tools: [{
        functionDeclarations: [{
          name: "go_to_sleep",
          description: "End the conversation and go back to sleep. Call this when the user says goodbye, the conversation is clearly over, or you were woken by accident and nobody is talking to you.",
        }],
      }],
    },
  }));
});

ws.addEventListener("message", async event => {
  const text = typeof event.data === "string"
    ? event.data
    : Buffer.from(await event.data.arrayBuffer()).toString();
  const msg = JSON.parse(text);

  if (msg.setupComplete !== undefined) {
    console.error("setup complete; asking her to sleep");
    ws.send(JSON.stringify({
      clientContent: {
        turns: [{ role: "user", parts: [{ text: "Thanks, that's all — goodnight!" }] }],
        turnComplete: true,
      },
    }));
    return;
  }

  if (msg.toolCall) {
    console.log("TOOLCALL:", JSON.stringify(msg.toolCall, null, 2));
    clearTimeout(deadline);
    ws.close();
    process.exit(0);
  }

  // Log everything else compactly (audio elided)
  const sc = msg.serverContent;
  if (sc?.modelTurn?.parts?.some(p => p.inlineData)) { console.error("(audio chunk)"); return; }
  console.error("msg:", JSON.stringify(msg).slice(0, 300));
});

ws.addEventListener("error", () => { console.error("websocket error"); process.exit(1); });
ws.addEventListener("close", e => { console.error(`closed: ${e.code} ${e.reason}`); process.exit(1); });

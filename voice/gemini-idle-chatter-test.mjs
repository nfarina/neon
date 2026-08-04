#!/usr/bin/env node
// Probe: while nobody is talking, how often does Gemini Live send us
// *anything*?
//
// The shell's idle timer refuses to doze if the server said anything in the
// last 3 seconds — a guard added so she couldn't fall asleep between two
// thought parts. That guard is only safe if server silence roughly tracks
// room silence. If the server chatters on its own schedule (usage metadata
// for every second of streamed mic audio, transcription of ambient noise,
// session-resumption handles), the guard never lets go and she never dozes.
//
// Streams silence like a live mic and prints the gap between consecutive
// server messages after the opening reply is done.
//
//   node gemini-idle-chatter-test.mjs [model] [seconds]

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
const watchSeconds = Number(process.argv[3] || 45);

const url = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${KEY}`;
const ws = new WebSocket(url);
const t0 = Date.now();
const ts = () => ((Date.now() - t0) / 1000).toFixed(2);

let quietSince = null;      // when the opening reply finished
let lastMsgAt = null;       // arrival of the previous server message
const gaps = [];            // {at, gap, kind} once we're quiet

function describe(msg) {
  const keys = Object.keys(msg);
  const sc = msg.serverContent;
  if (!sc) return keys.join(",");
  const inner = Object.keys(sc).filter(k => k !== "modelTurn");
  if (sc.modelTurn?.parts?.some(p => p.inlineData)) inner.push("audio");
  if (sc.modelTurn?.parts?.some(p => p.thought)) inner.push("thought");
  return `serverContent{${inner.join(",")}}` +
    (keys.length > 1 ? ` +${keys.filter(k => k !== "serverContent").join(",")}` : "");
}

ws.addEventListener("open", () => {
  ws.send(JSON.stringify({
    setup: {
      model: `models/${model}`,
      generationConfig: {
        responseModalities: ["AUDIO"],
        thinkingConfig: { thinkingLevel: "MEDIUM", includeThoughts: true },
      },
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
  const now = Date.now();

  if (msg.setupComplete !== undefined) {
    console.error(`${ts()} setup complete — saying hello, then going quiet`);
    ws.send(JSON.stringify({
      clientContent: {
        turns: [{ role: "user", parts: [{ text: "Hi Neon." }] }],
        turnComplete: true,
      },
    }));
    // A live mic never stops sending: 100 ms of silence at a time, exactly
    // like sendMic does between utterances.
    const silence = Buffer.alloc(3200);
    setInterval(() => {
      if (ws.readyState !== 1) return;
      ws.send(JSON.stringify({
        realtimeInput: { audio: { mimeType: "audio/pcm;rate=16000", data: silence.toString("base64") } },
      }));
    }, 100);
    return;
  }

  if (quietSince) {
    const gap = (now - lastMsgAt) / 1000;
    gaps.push({ at: ts(), gap, kind: describe(msg) });
    console.error(`${ts()} +${gap.toFixed(2)}s  ${describe(msg)}`);
  }
  lastMsgAt = now;

  if (msg.serverContent?.turnComplete && !quietSince) {
    quietSince = now;
    console.error(`${ts()} reply done — watching ${watchSeconds}s of silence\n`);
    setTimeout(() => {
      const idle = gaps.filter(g => g.gap !== undefined);
      const max = idle.reduce((m, g) => Math.max(m, g.gap), 0);
      const overThree = idle.filter(g => g.gap >= 3).length;
      console.log(`\nmessages while quiet: ${idle.length}`);
      console.log(`longest gap:          ${max.toFixed(2)}s`);
      console.log(`gaps >= 3s:           ${overThree}`);
      const byKind = {};
      for (const g of idle) byKind[g.kind] = (byKind[g.kind] || 0) + 1;
      for (const [k, n] of Object.entries(byKind)) console.log(`  ${n} × ${k}`);
      console.log(max >= 3
        ? `\nVERDICT: the 3s server-silence guard would release — server chatter is not the problem.`
        : `\nVERDICT: the server never goes quiet for 3s. The guard can never release, so she can never doze.`);
      process.exit(0);
    }, watchSeconds * 1000);
  }
});

ws.addEventListener("error", e => { console.error("ws error", e.message || e); process.exit(1); });
ws.addEventListener("close", e => {
  if (!quietSince) { console.error(`closed early: ${e.code} ${e.reason}`); process.exit(1); }
});

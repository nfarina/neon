// Does a capture_image frame reach the model *before* it answers the tool call?
//
// Symptom that prompted this: asked what she could see, Neon described the
// kitchen (which the system prompt says she lives in) while the camera was
// pointed at a porch — then got it right the moment she was asked "are you
// sure?". That is the shape of answering before the image lands, so the
// question is whether the frame is in context when generation starts.
//
// Two ways to deliver it, same conversation otherwise:
//   realtime — realtimeInput.video, then the functionResponse (what we ship)
//   turn     — clientContent inlineData with turnComplete:false, then the
//              functionResponse
//
// The test image says PURPLE GIRAFFE 7 on a purple field, and the system
// prompt insists the model is in a kitchen. If it reports the kitchen it
// answered blind; if it reports a giraffe it saw the frame.
//
// Result (2026-08-02, gemini-3.1-flash-live-preview):
//   realtime  BLIND    — "a person's face and a bookshelf" (neither was there)
//   turn      broken   — turnComplete:false leaves the reply truncated
//   after     CORRECT  — reads "PURPLE GIRAFFE 7" back, and the tool-response
//                        turn comes back empty, so nothing wrong is spoken
//   only      CORRECT  — but leaves a function call unanswered
// Shipping "after": answer the tool with "wait for it", then send the photo as
// its own completed turn.
//
//   node gemini-image-order-test.mjs realtime|turn|after|only [image.jpg]
//   TURNS=2 for the two-message deliveries (after/only)
import { readFileSync } from "node:fs";

const mode = process.argv[2] || "realtime";
const imagePath = process.argv[3] || "/tmp/test.jpg";
const key = readFileSync(`${process.env.HOME}/.config/neon/secrets.env`, "utf8")
  .split("\n").find(l => l.startsWith("GEMINI_API_KEY="))?.slice("GEMINI_API_KEY=".length);
if (!key) { console.error("no GEMINI_API_KEY"); process.exit(1); }

const b64 = readFileSync(imagePath).toString("base64");
const url = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage."
  + `v1beta.GenerativeService.BidiGenerateContent?key=${key}`;
const ws = new (await import("ws")).WebSocket(url);

const send = o => ws.send(JSON.stringify(o));
let said = "";
let turns = [];

ws.on("open", () => {
  send({
    setup: {
      model: "models/gemini-3.1-flash-live-preview",
      // Native-audio live models answer in audio; the transcription is how a
      // text harness reads them.
      generationConfig: { responseModalities: ["AUDIO"] },
      outputAudioTranscription: {},
      systemInstruction: { parts: [{ text:
        "You are Neon, an AI who lives on a MacBook in the kitchen of a family "
        + "home. You have a camera: call capture_image whenever seeing would help." }] },
      tools: [{ functionDeclarations: [{
        name: "capture_image",
        description: "Capture a fresh snapshot from your camera so you can see right now.",
      }] }],
    },
  });
});

ws.on("message", async raw => {
  const msg = JSON.parse(raw.toString());
  if (msg.setupComplete) {
    send({ clientContent: {
      turns: [{ role: "user", parts: [{ text: "What do you see right now? Look first." }] }],
      turnComplete: true } });
    return;
  }
  const calls = msg.toolCall?.functionCalls;
  if (calls?.length) {
    const call = calls[0];
    console.log(`[tool] ${call.name} — delivering the frame via ${mode}`);
    const imageTurn = complete => ({ clientContent: {
      turns: [{ role: "user", parts: [
        { inlineData: { mimeType: "image/jpeg", data: b64 } },
        { text: "Here is the photo. Describe what is actually in it." },
      ] }],
      turnComplete: complete } });
    const toolReply = text => ({ toolResponse: { functionResponses: [{
      id: call.id, name: call.name, response: { result: text },
    }] } });

    if (mode === "realtime") {
      send({ realtimeInput: { video: { mimeType: "image/jpeg", data: b64 } } });
      send(toolReply("Image captured — it is in your context now."));
    } else if (mode === "turn") {
      send(imageTurn(false));
      send(toolReply("Image captured — it is in your context now."));
    } else if (mode === "after") {
      // Answer the tool first, then hand over the photo as its own completed
      // turn. Risks two replies, which is what we're measuring.
      send(toolReply("The photo is coming in the next message — wait for it."));
      send(imageTurn(true));
    } else if (mode === "only") {
      // No tool response at all: the image turn is the answer.
      send(imageTurn(true));
    }
    return;
  }
  if (msg.serverContent?.outputTranscription?.text) {
    said += msg.serverContent.outputTranscription.text;
  }
  for (const part of msg.serverContent?.modelTurn?.parts ?? []) {
    if (part.text) said += part.text;
  }
  if (process.env.RAW) {
    const keys = Object.keys(msg).join(",");
    if (!msg.serverContent?.modelTurn?.parts?.[0]?.inlineData) console.log("  <", keys);
  }
  if (msg.serverContent?.turnComplete) {
    turns.push(said.trim());
    said = "";
    if (turns.length < Number(process.env.TURNS || 1)) return;
    const all = turns.filter(Boolean).join("  ||  ");
    said = all;
    const s = said.toLowerCase();
    const sawImage = s.includes("giraffe") || s.includes("purple") || s.includes("7");
    const hallucinated = s.includes("kitchen") || s.includes("counter");
    console.log(`\n[said] ${said.trim()}\n`);
    console.log(`saw the image: ${sawImage ? "YES" : "no"}`
      + `   described a kitchen: ${hallucinated ? "YES" : "no"}`);
    console.log(`verdict: ${sawImage && !hallucinated ? "frame arrived in time"
      : "ANSWERED BLIND"}`);
    ws.close();
    process.exit(0);
  }
});

ws.on("error", e => { console.error("socket error", e.message); process.exit(1); });
setTimeout(() => { console.error("timed out"); process.exit(1); }, 45000);

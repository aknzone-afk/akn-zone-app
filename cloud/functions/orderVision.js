"use strict";

/**
 * orderVision.js — read a customer's MARKED order photo (owner's rules,
 * 1-Oct-2026) with Gemini vision. Returns per-design pieces; the caller does
 * the money maths. The model never talks to the customer.
 *
 * Measured 1-Oct on 9 real samples: gemini-3-flash-preview 8-11 s per photo,
 * marks/captions read right, but it can UNDER-count sarees in a busy photo —
 * so a low reading must never be used alone to turn a customer away.
 */

const logger = require("firebase-functions/logger");

const MODELS = (process.env.ORDER_VISION_MODELS || "gemini-3-flash-preview,gemini-3.5-flash,gemini-3.6-flash,gemini-flash-latest,gemini-3.8-flash,gemini-3.1-flash-lite,gemini-3.5-flash-lite,gemini-flash-lite-latest,gemini-3.1-flash-lite-preview")
  .split(",").map((s) => s.trim()).filter(Boolean);

const PROMPT = "You read wholesale saree ORDER photos for B.B Synthetics (AKN ZONE), Surat.\n\nTHE PHOTO. Each design photo shows ONE design laid out on artificial grass: usually one or two big spread sarees at the top and several folded sarees below, each a different COLOUR of the same design. Printed cards on the photo show the design number (small grey sticker, e.g. \"5257\", \"N10022\", \"7124\"), the PRICE OF ONE SAREE (card like \"Rs 1040/-\"), and the fabric name (e.g. \"FANDY SATIN\"). Cards saying \"FOAM POUCH PACKING\" or \"FULL CUT FULL WORK ...\" are NOT sarees. The image may be a phone screenshot of a chat or of the catalogue app: ignore the phone UI, chat bubbles, times, names, and any \"₹\" header bar of the app EXCEPT use it as a second source for the design number and price. One screenshot can contain MORE THAN ONE design photo; report each design photo separately. A design photo cut off so much that its sarees or its price card are not visible: report it with confidence below 0.5.\n\nCOUNT THE SAREES. Every distinct saree (each colour) visible in the design photo is one saree, including the big spread ones at the top. Do not count the white cards.\n\nTHE CUSTOMER'S MARKS (drawn with a finger, any ink colour — the ink colour never matters):\n- A NUMBER written on a saree (\"2\", \"3\", \"2 pc\", \"3pc\") = that many pieces of THAT saree.\n- A TICK, a DOT, or a short LINE/DASH on a saree = 1 piece. Several dots on one saree = that many pieces (3 dots = 3).\n- A NUMBER together with a tick on the SAME saree (\"2 ✓\", \"2 ✓ pc\", \"✓ 3\") = that number only. Never add the tick on top.\n- A CROSS (X) or a black/dark SCRIBBLE over a saree = NOT wanted (0).\nRULES, in this priority order:\n1. The customer's TEXT instruction wins over everything (\"3 red 3 rani\", \"2 set\", \"tick wali 3-3 piece, baaki 2-2\").\n   \"N set\" = N pieces of EVERY saree in the photo except the crossed ones.\n2. If the photo has ANY positive mark (number / tick / dot / dash) then ONLY the marked sarees are ordered; unmarked sarees = 0.\n3. If the photo has ONLY crosses/scribbles, every NON-crossed saree = 1 piece.\n4. If the photo has NO marks at all, every saree = 1 piece.\n\nOUTPUT strictly the JSON schema. For each design photo give: designNo (as printed, or null), pricePerSaree (rupees, number, or null), fabric, sareeCount (all sarees visible), the list of sarees with their mark and pieces, totalPieces, the rule you applied, and your confidence 0-1. Never invent a price or a design number you cannot read.\n\n\nOUR OWN BILL. If the image is a TAX INVOICE / bill printed by B.B. SYNTHETICS (seller header \"B. B. SYNTHETICS\", invoice number like \"4231/S\" or \"OP733\", items table, bank details) then it is NOT a design photo: return photos as an empty list and fill invoice: number exactly as printed (e.g. \"4231/S\", \"OP733\"), date as printed, buyer (Bill to) name, the grand total amount in rupees, and \"Dispatched through\" as transport. For every other image set invoice to null.";

const SCHEMA = {"type":"object","properties":{"photos":{"type":"array","items":{"type":"object","properties":{
 "designNo":{"type":["string","null"]},"pricePerSaree":{"type":["number","null"]},"fabric":{"type":["string","null"]},
 "sareeCount":{"type":"integer"},
 "sarees":{"type":"array","items":{"type":"object","properties":{"where":{"type":"string"},"colour":{"type":"string"},"mark":{"type":"string","enum":["none","number","tick","dot","dash","cross"]},"pieces":{"type":"integer"}},"required":["where","colour","mark","pieces"]}},
 "totalPieces":{"type":"integer"},"ruleApplied":{"type":"string","enum":["text_instruction","marked_only","all_but_crossed","no_marks_all_one"]},
 "confidence":{"type":"number"}},"required":["designNo","pricePerSaree","sareeCount","sarees","totalPieces","ruleApplied","confidence"]}},"invoice":{"type":["object","null"],"properties":{"number":{"type":["string","null"]},"date":{"type":["string","null"]},"buyer":{"type":["string","null"]},"total":{"type":["number","null"]},"transport":{"type":["string","null"]}}}},"required":["photos","invoice"]};

async function readOrderPhoto({ apiKey, bytes, mime, text }) {
  const body = {
    systemInstruction: { parts: [{ text: PROMPT }] },
    contents: [{ role: "user", parts: [
      { inlineData: { mimeType: mime || "image/jpeg", data: Buffer.from(bytes).toString("base64") } },
      { text: "Customer's text with this photo: " + (String(text || "").trim() || "(none)") },
    ] }],
    generationConfig: { responseMimeType: "application/json", responseJsonSchema: SCHEMA, temperature: 0 },
  };
  let lastErr = null;
  for (const model of MODELS) {
    const t0 = Date.now();
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 75000);
      const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
        method: "POST", headers: { "x-goog-api-key": apiKey, "Content-Type": "application/json" },
        body: JSON.stringify(body), signal: ctl.signal,
      }).finally(() => clearTimeout(timer));
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { lastErr = `${model} ${r.status}`; logger.warn("orderVision model failed", { model, status: r.status }); continue; }
      const textOut = j.candidates && j.candidates[0] && j.candidates[0].content && j.candidates[0].content.parts &&
        j.candidates[0].content.parts.map((p) => p.text || "").join("");
      const parsed = JSON.parse(textOut);
      if (!parsed || !Array.isArray(parsed.photos)) throw new Error("no photos[]");
      const inv = parsed.invoice && parsed.invoice.number ? parsed.invoice : null;
      return { ok: true, model, ms: Date.now() - t0, photos: inv ? [] : parsed.photos.map(clean), invoice: inv };
    } catch (err) {
      lastErr = `${model} ${err.name === "AbortError" ? "timeout" : err.message}`;
      logger.warn("orderVision model error", { model, error: lastErr });
    }
  }
  return { ok: false, error: lastErr, photos: [] };
}

function clean(p) {
  const pieces = Array.isArray(p.sarees) ? p.sarees.reduce((n, s) => n + Math.max(0, Number(s.pieces) || 0), 0) : 0;
  const price = Number(p.pricePerSaree);
  return {
    designNo: p.designNo ? String(p.designNo).trim().slice(0, 20) : null,
    price: Number.isFinite(price) && price > 0 && price < 100000 ? price : null,
    fabric: p.fabric ? String(p.fabric).slice(0, 40) : null,
    sareeCount: Number(p.sareeCount) || 0,
    pieces,
    rule: p.ruleApplied || null,
    confidence: Math.max(0, Math.min(1, Number(p.confidence) || 0)),
    marks: (p.sarees || []).filter((s) => s.mark !== "none").map((s) => `${s.mark}:${s.pieces}`).slice(0, 20),
  };
}

module.exports = { readOrderPhoto, MODELS };

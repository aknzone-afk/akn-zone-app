"use strict";

/**
 * AKN Zone catalog app — cloud helper (codebase "bbapp", owner 11-Oct-2026).
 *
 * readMarks: the customer drew on a design photo in the app (tick / line / dot
 * = wanted, cross / scribble = not wanted, a written number = that many
 * pieces). The app posts the marked photo here; we read it with the SAME
 * reader and rules as the AKN Chat bot (orderVision.js is a copy of
 * akn-chat functions/lib/orderVision.js) and return the pieces, which feed the
 * ₹30,000 minimum.
 *
 * Lives in the AKN Chat Firebase project (it already has the Gemini key and
 * Blaze billing) but in its OWN codebase, so deploying it never touches the
 * AKN Chat functions:  firebase deploy --only functions:bbapp
 */

const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { readOrderPhoto } = require("./orderVision");

// Own FREE key (BBSynRenamer project) — never spends AKN Chat's daily free quota.
const GEMINI_API_KEY = defineSecret("BBAPP_GEMINI_KEY");
const APP_KEY = "akn-zone-app-2026"; // not a secret — only keeps random traffic out
const MAX_BYTES = 3 * 1024 * 1024;
const PER_IP_PER_HOUR = 120;

const hits = new Map(); // ip → [timestamps] (per instance; good enough)
function limited(ip) {
  const now = Date.now();
  const arr = (hits.get(ip) || []).filter((t) => now - t < 3600e3);
  arr.push(now);
  hits.set(ip, arr);
  if (hits.size > 5000) hits.clear();
  return arr.length > PER_IP_PER_HOUR;
}

exports.readMarks = onRequest(
  {
    region: "asia-south1",
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 120,
    memory: "512MiB",
    maxInstances: 5,
    cors: true,
    invoker: "public",
  },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).json({ ok: false, error: "POST only" });
    if (req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false, error: "forbidden" });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited(ip)) return res.status(429).json({ ok: false, error: "too many" });

    const b64 = req.body && typeof req.body.image === "string" ? req.body.image : "";
    const bytes = Buffer.from(b64, "base64");
    if (!bytes.length || bytes.length > MAX_BYTES) {
      return res.status(400).json({ ok: false, error: "image missing or too big" });
    }
    const r = await readOrderPhoto({ apiKey: GEMINI_API_KEY.value(), bytes, mime: "image/jpeg", text: "" });
    const p = r.ok && r.photos && r.photos[0];
    if (!p) {
      logger.warn("readMarks: no reading", { error: r.error || null });
      return res.status(200).json({ ok: false, error: r.error || "no design photo found" });
    }
    logger.info("readMarks", { ms: r.ms, model: r.model, sarees: p.sareeCount, pieces: p.pieces, rule: p.rule, conf: p.confidence });
    return res.status(200).json({
      ok: true,
      sareeCount: p.sareeCount,
      pieces: p.pieces,
      rule: p.rule,
      confidence: p.confidence,
      designNo: p.designNo,
      price: p.price,
      marks: p.marks,
    });
  },
);

/**
 * detectSarees: where is each saree in a catalog photo (for TAP-TO-SELECT in
 * the app: tap a saree = +1 of that colour, tap the background = +1 SET).
 * Called by the shop PC (CLE\AKNZonePieces\count_pieces.py) once per photo;
 * the result is published in bbsynthetics.in/app/pieces.json.
 */
const BOX_PROMPT =
  "Saree catalogue photo from B.B Synthetics (AKN ZONE), Surat: ONE design laid on artificial grass — usually 1-2 big spread/open sarees at the top " +
  "and several folded sarees below, each a different COLOUR of the same design. Printed white cards (design number, price \"Rs 1040/-\", fabric name, " +
  "\"FOAM POUCH PACKING\", \"FULL CUT FULL WORK\") are NOT sarees. IMPORTANT: a big OPEN/spread saree usually shows its " +
  "BLOUSE PIECE and/or PALLU lying next to its body in a different pattern or shade — that whole open spread (body + blouse piece + " +
  "pallu) is ONE saree: give it ONE box covering all its parts. Only separate folded pieces of different colours are separate sarees. " +
  "Find EVERY saree (spread and folded). For each give box_2d " +
  "[ymin, xmin, ymax, xmax] normalised to 0-1000 tightly around that saree's VISIBLE part, its colour, and a label point " +
  "[y, x] (0-1000): the CENTRE of the largest area where ONLY that saree's own colour is visible — never on an edge, a fold line, " +
  "a sticker, a card or where another saree overlaps it (a number will be drawn there and must clearly belong to this one saree). Also read the design number and the " +
  "price of one saree if printed (else null). Return strictly the JSON schema.";
const BOX_SCHEMA = { type: "object", properties: {
  sarees: { type: "array", items: { type: "object", properties: {
    box_2d: { type: "array", items: { type: "integer" } }, colour: { type: "string" },
    point: { type: "array", items: { type: "integer" } } }, required: ["box_2d", "colour", "point"] } },
  designNo: { type: ["string", "null"] }, price: { type: ["number", "null"] } }, required: ["sarees"] };

exports.detectSarees = onRequest(
  { region: "asia-south1", secrets: [GEMINI_API_KEY], timeoutSeconds: 120, memory: "512MiB", maxInstances: 5, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).json({ ok: false });
    if (req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const bytes = Buffer.from(String((req.body && req.body.image) || ""), "base64");
    if (!bytes.length || bytes.length > MAX_BYTES) return res.status(400).json({ ok: false, error: "bad image" });
    const { MODELS } = require("./orderVision");
    let lastErr = null;
    for (const model of MODELS) {
      try {
        const ctl = new AbortController();
        const timer = setTimeout(() => ctl.abort(), 80000);
        const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
          method: "POST",
          headers: { "x-goog-api-key": GEMINI_API_KEY.value(), "Content-Type": "application/json" },
          body: JSON.stringify({
            contents: [{ role: "user", parts: [{ inlineData: { mimeType: "image/jpeg", data: bytes.toString("base64") } }, { text: BOX_PROMPT }] }],
            generationConfig: { responseMimeType: "application/json", responseJsonSchema: BOX_SCHEMA, temperature: 0 },
          }),
          signal: ctl.signal,
        }).finally(() => clearTimeout(timer));
        const j = await r.json().catch(() => ({}));
        if (!r.ok) { lastErr = `${model} ${r.status}`; continue; }
        const txt = j.candidates[0].content.parts.map((p) => p.text || "").join("");
        const d = JSON.parse(txt);
        const clamp = (v) => Math.max(0, Math.min(1000, Math.round(Number(v) || 0)));
        const good = (d.sarees || []).filter((s) => {
          const b = (s.box_2d || []).map(clamp);
          return b.length === 4 && b[2] > b[0] && b[3] > b[1];
        });
        const boxes = good.map((s) => s.box_2d.map(clamp));
        // Label point must lie inside its own box; else the box centre.
        const points = good.map((s, i) => {
          const b = boxes[i];
          const p = (s.point || []).map(clamp);
          return p.length === 2 && p[0] >= b[0] && p[0] <= b[2] && p[1] >= b[1] && p[1] <= b[3]
            ? p : [Math.round((b[0] + b[2]) / 2), Math.round((b[1] + b[3]) / 2)];
        });
        const price = Number(d.price);
        return res.json({ ok: true, model, sareeCount: boxes.length, boxes, points,
          designNo: d.designNo || null, price: Number.isFinite(price) && price > 0 ? price : null });
      } catch (e) { lastErr = `${model} ${e.message}`; }
    }
    logger.warn("detectSarees failed", { lastErr });
    return res.json({ ok: false, error: lastErr });
  },
);

/**
 * lookupParty: OLD CUSTOMER in the app types only the mobile number → the
 * party's details from Tally (same lookup as the DAILY CUSTOMER desk).
 * Data = parties.json bundled with this function (PRIVATE, never on the
 * website), rebuilt daily on the shop PC from TallyOrderBot's own cache by
 * CLE\AKNZonePieces\parties_sync.py.
 */
let PARTIES = null;
exports.lookupParty = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).json({ ok: false });
    if (req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("p:" + ip)) return res.status(429).json({ ok: false, error: "too many" });
    let d = String((req.body && req.body.mobile) || "").replace(/\D/g, "");
    if (d.length === 12 && d.startsWith("91")) d = d.slice(2);
    if (d.length === 11 && d.startsWith("0")) d = d.slice(1);
    if (!/^[6-9]\d{9}$/.test(d)) return res.json({ ok: false, error: "bad mobile" });
    if (!PARTIES) PARTIES = require("./parties.json");
    const list = (PARTIES[d] || []).slice(0, 5);
    logger.info("lookupParty", { found: list.length });
    return res.json({ ok: true, parties: list });
  },
);

/**
 * nextOrderNo: serial ORDER NO. 1, 2, 3… for the Telegram group, shared by
 * every customer's phone. Idempotent per app order (ref) so a retried send
 * keeps its number. Firestore (free tier): bbapp_counters/orders,
 * bbapp_orders/{ref}. Separate collections — never touches AKN Chat data.
 */
const admin = require("firebase-admin");
if (!admin.apps.length) admin.initializeApp();
exports.nextOrderNo = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).json({ ok: false });
    if (req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("n:" + ip)) return res.status(429).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    if (!ref) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    const orderDoc = db.collection("bbapp_orders").doc(ref);
    const counter = db.collection("bbapp_counters").doc("orders");
    const no = await db.runTransaction(async (tx) => {
      const o = await tx.get(orderDoc);
      if (o.exists) return o.get("no");
      const c = await tx.get(counter);
      const next = (c.exists ? c.get("last") || 0 : 0) + 1;
      tx.set(counter, { last: next }, { merge: true });
      tx.set(orderDoc, { no: next, at: admin.firestore.FieldValue.serverTimestamp() });
      return next;
    });
    return res.json({ ok: true, no });
  },
);

/* ───────────── ORDER STATUS (owner, 11-Oct-2026) ─────────────
 * Each order's details message in the Telegram group carries buttons
 * ✅ Received · 📦 Packed · 🚚 Dispatched. A tap lands here (bot webhook),
 * the status is stored on bbapp_orders/{ref}, the buttons are redrawn with a
 * tick, and the customer's app shows it in My Orders. Replying to the order
 * message with text ("LR 4521 DRT") attaches that as the dispatch info.
 */
const TG_TOKEN = defineSecret("BBAPP_TG_TOKEN");
const TG_SECRET = defineSecret("BBAPP_TG_SECRET");
// Owner: RECEIVED is automatic (set when the order reaches the group).
// Buttons in strict order: Getting order ready → (2 h later) Packed → Dispatched.
const STATUSES = { g: "getting_ready", p: "packed", d: "dispatched" };
const LABELS = { g: "🧺 Getting order ready", p: "📦 Packed", d: "🚚 Dispatched" };
const ORDER = ["received", "getting_ready", "packed", "dispatched"];
const PACK_AFTER_MS = 2 * 3600 * 1000;

function statusKeyboard(ref, current) {
  const btn = (k) => ({
    text: LABELS[k],
    callback_data: `s|${k}|${ref}`.slice(0, 64),
  });
  const done = ORDER.indexOf(current || "received");
  const b2 = (k) => {
    const x = btn(k);
    if (ORDER.indexOf(STATUSES[k]) <= done) x.text = "✔ " + LABELS[k];
    return x;
  };
  return { inline_keyboard: [[b2("g")], [b2("p"), b2("d")]] };
}

async function tg(method, body) {
  const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  return r.json().catch(() => ({}));
}

exports.tgWebhook = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN, TG_SECRET], timeoutSeconds: 30, memory: "256MiB", maxInstances: 3, invoker: "public" },
  async (req, res) => {
    if (req.get("x-telegram-bot-api-secret-token") !== TG_SECRET.value().trim()) return res.status(403).send("no");
    const u = req.body || {};
    const db = admin.firestore();
    try {
      if (u.callback_query) {
        const q = u.callback_query;
        const [tag, k, ref] = String(q.data || "").split("|");
        if (tag === "s" && STATUSES[k] && ref) {
          const status = STATUSES[k];
          const docRef = db.collection("bbapp_orders").doc(ref);
          // Strict order + 2-hour gap before Packed (checked in a transaction).
          const verdict = await db.runTransaction(async (tx) => {
            const d = await tx.get(docRef);
            const cur = (d.exists && d.get("status")) || "received";
            const ci = ORDER.indexOf(cur), ni = ORDER.indexOf(status);
            if (ni <= ci) return { ok: false, msg: `Already ${cur.replace("_", " ")}.`, cur };
            if (ni !== ci + 1) {
              return { ok: false, msg: `First tap "${LABELS[{ received: "g", getting_ready: "p", packed: "d" }[cur]]}".`, cur };
            }
            if (status === "packed") {
              const g = d.get("readyAt");
              const since = g ? Date.now() - g.toMillis() : 0;
              if (since < PACK_AFTER_MS) {
                const at = new Date((g ? g.toMillis() : Date.now()) + PACK_AFTER_MS);
                const hhmm = at.toLocaleTimeString("en-IN", { timeZone: "Asia/Kolkata", hour: "numeric", minute: "2-digit" });
                return { ok: false, msg: `Packed can be marked after ${hhmm} (2 hours after Getting order ready).`, cur };
              }
            }
            const upd = { status, statusAt: admin.firestore.FieldValue.serverTimestamp(),
              statusBy: (q.from && (q.from.first_name || q.from.username)) || "" };
            if (status === "getting_ready") upd.readyAt = admin.firestore.FieldValue.serverTimestamp();
            tx.set(docRef, upd, { merge: true });
            return { ok: true, cur: status };
          });
          await tg("answerCallbackQuery", { callback_query_id: q.id,
            text: verdict.ok ? `Marked ${LABELS[k]}` : verdict.msg, show_alert: !verdict.ok });
          if (!verdict.ok) return res.status(200).send("ok");
          if (q.message) {
            await tg("editMessageReplyMarkup", {
              chat_id: q.message.chat.id, message_id: q.message.message_id,
              reply_markup: statusKeyboard(ref, status),
            });
          }
        } else {
          await tg("answerCallbackQuery", { callback_query_id: q.id });
        }
      } else if (u.message && u.message.reply_to_message && u.message.text) {
        // A reply to an order message = dispatch info (LR no., transport).
        const m = u.message;
        const map = await db.collection("bbapp_msgmap").doc(`${m.chat.id}_${m.reply_to_message.message_id}`).get();
        if (map.exists) {
          const ref = map.get("ref");
          await db.collection("bbapp_orders").doc(ref).set({
            lr: String(m.text).slice(0, 120), lrAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
          await tg("setMessageReaction", { chat_id: m.chat.id, message_id: m.message_id, reaction: [{ type: "emoji", emoji: "👍" }] });
        }
      }
    } catch (e) {
      logger.warn("tgWebhook", { error: e.message });
    }
    return res.status(200).send("ok");
  },
);

/** The app registers the order's Telegram message (so replies map to it). */
exports.registerOrder = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const chat = String((req.body && req.body.chat) || "").replace(/[^0-9-]/g, "");
    const msg = Number(req.body && req.body.msg) || 0;
    if (!ref || !chat || !msg) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    await db.collection("bbapp_msgmap").doc(`${chat}_${msg}`).set({ ref });
    const docRef = db.collection("bbapp_orders").doc(ref);
    const d = await docRef.get();
    await docRef.set({ msg, chat, ...(d.exists && d.get("status") ? {} : {
      status: "received", statusAt: admin.firestore.FieldValue.serverTimestamp() }) }, { merge: true });
    return res.json({ ok: true });
  },
);

/** My Orders: statuses for this phone's orders. */
exports.orderStatus = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("s:" + ip)) return res.status(429).json({ ok: false });
    const refs = ((req.body && req.body.refs) || []).map((r) => String(r).replace(/[^A-Z0-9-]/gi, "").slice(0, 40)).filter(Boolean).slice(0, 60);
    const db = admin.firestore();
    const snaps = refs.length ? await db.getAll(...refs.map((r) => db.collection("bbapp_orders").doc(r))) : [];
    const out = {};
    for (const s of snaps) {
      if (s.exists) out[s.id] = { status: s.get("status") || null, lr: s.get("lr") || null };
    }
    return res.json({ ok: true, orders: out });
  },
);

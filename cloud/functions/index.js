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
  "pallu) is ONE saree (its box covers only the open spread). Normally the photo has exactly ONE open saree at the top: count it ONCE " +
  "even if it shows 2-3 strips of different colour or pattern side by side (body, pallu, blouse piece). BUT every FOLDED saree is a separate saree — even when it lies ON TOP of " +
  "the open saree or has the same colours; folded pieces usually carry their own design-number sticker. Never merge a folded piece into the " +
  "open saree's box. " +
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
// Owner (11-Oct-2026): RECEIVED is automatic. Then ONE button at a time:
//   🧺 Maal nikalna chalu  →  (3 hours later) 📦 Packed  →  🚚 Dispatched  →  ✅ Delivered
// A done step stays as "✔ <step> — by <name>" (name = the tapper's Telegram
// name); tapping the LATEST done step again undoes it.
const STEPS = [
  { k: "g", status: "getting_ready", label: "🧺 Maal nikalna chalu", by: "readyBy", at: "readyAt" },
  { k: "b", status: "bill_sent", label: "🧾 Bill sent for payment", by: "billBy", at: "billAt", auto: true,
    wait: "⏳ Waiting for bill (post it in the Bill group)" },
  { k: "y", status: "payment_received", label: "💰 Payment received", by: "paidBy", at: "paidAt" },
  { k: "d", status: "dispatched", label: "🚚 Dispatched", by: "dispatchedBy", at: "dispatchedAt", auto: true,
    wait: "⏳ Dispatched ticks when the parcel date is in Daily Parcels" },
  { k: "l", status: "bilty", label: "📄 Bilty", by: "biltyBy", at: "biltyAt", auto: true,
    wait: "⏳ Bilty ticks when the bilty no. is entered" },
];
const ORDER = ["received", ...STEPS.map((x) => x.status)];
const PACK_AFTER_MS = 3 * 3600 * 1000;
const STATUSES = Object.fromEntries(STEPS.map((x) => [x.k, x.status]));

function hhmm(ms) {
  return new Date(ms).toLocaleTimeString("en-IN", { timeZone: "Asia/Kolkata", hour: "numeric", minute: "2-digit" });
}
const escH = (x) => String(x).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** The order message = original details + a STATUS section with every tap
 *  and undo, full name and time (owner: nothing cut off). */
function statusText(d, fallbackPlain) {
  const base = (d && d.text) || escH(String(fallbackPlain || "").split("\n\nSTATUS")[0]);
  const log = (d && d.log) || [];
  if (!log.length) return base;
  const lines = log.map((e) => {
    const st = STEPS.find((x) => x.k === e.k);
    const name = st ? st.label : e.k;
    return e.a === "undo"
      ? `↩️ Undone ${escH(name)} — by ${escH(e.by)} · ${hhmm(e.at)}`
      : `✔ ${escH(name)} — by ${escH(e.by)} · ${hhmm(e.at)}`;
  });
  return `${base}\n\n<b>STATUS</b>\n${lines.join("\n")}`;
}

/** Short buttons: ↩️ Undo (latest step, only its tapper) + the NEXT step. */
function statusKeyboard(ref, d) {
  const cur = (d && d.status) || "received";
  const ci = ORDER.indexOf(cur);
  const log = (d && d.log) || [];
  const rows = [];
  const last = log[log.length - 1];
  const curStep = STEPS.find((x) => x.status === cur);
  if (curStep && last && last.a === "do" && last.k === curStep.k) {
    rows.push([{ text: `↩️ Undo (${last.by})`.slice(0, 40), callback_data: `s|${curStep.k}|${ref}`.slice(0, 64) }]);
  } else if (curStep && !log.length) {
    rows.push([{ text: `✔ ${curStep.label}`, callback_data: `s|${curStep.k}|${ref}`.slice(0, 64) }]);
  }
  const next = STEPS.find((x) => ORDER.indexOf(x.status) === ci + 1);
  if (next && next.auto) {
    rows.push([{ text: next.wait || "⏳ Waiting", callback_data: "n" }]);
  } else if (next) {
    let show = true;
    if (next.status === "packed") {
      const ready = d && d.readyAt ? d.readyAt.toMillis() : 0;
      if (Date.now() - ready < PACK_AFTER_MS) show = false; // packTimer reveals it after 3 h
    }
    if (show) rows.push([{ text: next.label, callback_data: `s|${next.k}|${ref}`.slice(0, 64) }]);
  }
  return { inline_keyboard: rows };
}

async function tg(method, body) {
  const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  return r.json().catch(() => ({}));
}

exports.tgWebhook = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN, TG_SECRET, GEMINI_API_KEY], timeoutSeconds: 120, memory: "256MiB", maxInstances: 3, invoker: "public" },
  async (req, res) => {
    if (req.get("x-telegram-bot-api-secret-token") !== TG_SECRET.value().trim()) return res.status(403).send("no");
    const u = req.body || {};
    const db = admin.firestore();
    try {
      if (u.callback_query) {
        const q = u.callback_query;
        if (q.data === "n") {
          await tg("answerCallbackQuery", { callback_query_id: q.id });
          return res.status(200).send("ok");
        }
        const [tag, k, ref] = String(q.data || "").split("|");
        const step = STEPS.find((x) => x.k === k);
        if (tag === "s" && step && step.auto) {
          await tg("answerCallbackQuery", { callback_query_id: q.id, text: "This step ticks by itself." });
          return res.status(200).send("ok");
        }
        if (tag === "s" && step && ref) {
          const docRef = db.collection("bbapp_orders").doc(ref);
          const name = [q.from && q.from.first_name, q.from && q.from.last_name].filter(Boolean).join(" ")
            || (q.from && q.from.username) || "staff";
          const verdict = await db.runTransaction(async (tx) => {
            const d = await tx.get(docRef);
            const cur = (d.exists && d.get("status")) || "received";
            const ci = ORDER.indexOf(cur), ni = ORDER.indexOf(step.status);
            const del = admin.firestore.FieldValue.delete();
            if (ni === ci) {
              // Undo the latest step — only by the person who tapped it.
              const lg = d.get("log") || [];
              const lastDo = [...lg].reverse().find((e) => e.a === "do" && e.k === step.k);
              if (lastDo && lastDo.uid && q.from && lastDo.uid !== q.from.id) {
                return { ok: false, msg: `Only ${lastDo.by} can undo this.` };
              }
              const upd = { status: ORDER[ci - 1], [step.by]: del, [step.at]: del,
                statusAt: admin.firestore.FieldValue.serverTimestamp(),
                log: admin.firestore.FieldValue.arrayUnion({ a: "undo", k: step.k, by: name, at: Date.now(), uid: (q.from && q.from.id) || 0 }) };
              if (step.status === "getting_ready") upd.packShown = del;
              tx.set(docRef, upd, { merge: true });
              return { ok: true, msg: `Undone: ${step.label}` };
            }
            if (ni < ci) return { ok: false, msg: "Undo the later step first." };
            if (ni !== ci + 1) return { ok: false, msg: "Not yet — do the steps in order." };
            if (step.status === "packed") {
              const g = d.get("readyAt");
              const at = (g ? g.toMillis() : Date.now()) + PACK_AFTER_MS;
              if (Date.now() < at) {
                const hhmm = new Date(at).toLocaleTimeString("en-IN", { timeZone: "Asia/Kolkata", hour: "numeric", minute: "2-digit" });
                return { ok: false, msg: `Packed opens at ${hhmm} (3 hours after Maal nikalna chalu).` };
              }
            }
            tx.set(docRef, { status: step.status, [step.by]: name,
              [step.at]: admin.firestore.FieldValue.serverTimestamp(),
              statusAt: admin.firestore.FieldValue.serverTimestamp(),
              log: admin.firestore.FieldValue.arrayUnion({ a: "do", k: step.k, by: name, at: Date.now(), uid: (q.from && q.from.id) || 0 }) },
              { merge: true });
            return { ok: true, msg: `${step.label} — by ${name}` };
          });
          await tg("answerCallbackQuery", { callback_query_id: q.id, text: verdict.msg, show_alert: !verdict.ok });
          if (verdict.ok && q.message) {
            const fresh = (await docRef.get()).data() || {};
            await tg("editMessageText", {
              chat_id: q.message.chat.id, message_id: q.message.message_id,
              text: statusText(fresh, q.message.text), parse_mode: "HTML",
              disable_web_page_preview: true,
              reply_markup: statusKeyboard(ref, fresh),
            });
          }
        } else {
          await tg("answerCallbackQuery", { callback_query_id: q.id });
        }
      } else if (u.message && /bill/i.test(String((u.message.chat && u.message.chat.title) || ""))
                 && (u.message.photo || (u.message.document && /image|pdf/.test(u.message.document.mime_type || "")))) {
        await handleBillPhoto(db, u.message);
      } else if (u.message && /^\/reset(\s|$)/i.test(String(u.message.text || ""))) {
        // "/reset 98xxxxxxxx" — free this number from every phone lock.
        let m = String(u.message.text).replace(/\D/g, "");
        if (m.length === 12 && m.startsWith("91")) m = m.slice(2);
        let freed = 0;
        if (m.length >= 7) {
          const ds = await db.collection("bbapp_devices").where("mobiles", "array-contains", m).get();
          for (const d of ds.docs) {
            await d.ref.set({ mobiles: (d.get("mobiles") || []).filter((x) => x !== m) }, { merge: true });
            freed++;
          }
          await db.collection("bbapp_mobiles").doc(m).delete().catch(() => {});
        }
        await tg("sendMessage", { chat_id: u.message.chat.id, reply_to_message_id: u.message.message_id,
          text: m.length >= 7 ? `✅ ${m} reset — removed from ${freed} phone lock(s).` : "Send: /reset 98xxxxxxxx" });
      } else if (u.message && u.message.reply_to_message && !(u.message.from && u.message.from.is_bot)
                 && (u.message.text || u.message.photo || u.message.document)) {
        // A staff reply to an order message (or to a party's chat message)
        // = a chat message to that party in the app.
        const m = u.message;
        const map = await db.collection("bbapp_msgmap").doc(`${m.chat.id}_${m.reply_to_message.message_id}`).get();
        if (map.exists) {
          const ref = map.get("ref");
          const fileId = m.photo ? m.photo[m.photo.length - 1].file_id : (m.document ? m.document.file_id : null);
          await addChat(db, ref, { from: "shop", text: String(m.text || m.caption || "").slice(0, 2000),
            fileId, mime: m.photo ? "image/jpeg" : (m.document && m.document.mime_type) || null,
            by: (m.from && m.from.first_name) || "" });
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
    const text = String((req.body && req.body.text) || "").slice(0, 3500);
    const mobile = String((req.body && req.body.mobile) || "").replace(/\D/g, "").slice(-10);
    const billName = String((req.body && req.body.billName) || "").slice(0, 120);
    const serial = Number(req.body && req.body.serial) || null;
    const addOnTo = String((req.body && req.body.addOnTo) || "").slice(0, 40) || null;
    if (!ref || !chat || !msg) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    await db.collection("bbapp_msgmap").doc(`${chat}_${msg}`).set({ ref });
    const docRef = db.collection("bbapp_orders").doc(ref);
    const d = await docRef.get();
    await docRef.set({ msg, chat, mobile, billName, serial, addOnTo, ...(text ? { text } : {}), ...(d.exists && d.get("status") ? {} : {
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
    // The app also sends who each order is for — fills orders registered
    // before this was stored, so their bills can be matched.
    const info = (req.body && req.body.info) || {};
    for (const sn of snaps) {
      const i = info[sn.id];
      if (sn.exists && i && !sn.get("mobile")) {
        await sn.ref.set({
          mobile: String(i.mobile || "").replace(/\D/g, "").slice(-10),
          billName: String(i.billName || "").slice(0, 120),
          serial: Number(i.serial) || null,
          addOnTo: String(i.addOnTo || "").slice(0, 40) || null,
        }, { merge: true });
      }
    }
    const out = {};
    for (const s of snaps) {
      if (s.exists) out[s.id] = { status: s.get("status") || null, lr: s.get("lr") || null,
        bill: !!s.get("billFileId"), billNo: s.get("billNo") || null, billTotal: s.get("billTotal") || null };
    }
    return res.json({ ok: true, orders: out });
  },
);

/* ───────────── PHONE LOCK (owner, 11-Oct-2026) ─────────────
 * One phone (app-made id kept in the iOS Keychain / Android secure store)
 * may use at most 2 mobile numbers. The 3rd is refused. A number seen before
 * on another phone is allowed but flagged ("new phone"). Shop resets with
 * "/reset 98xxxxxxxx" in the orders group (see tgWebhook).
 */
exports.phoneLock = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("l:" + ip)) return res.status(429).json({ ok: false });
    const device = String((req.body && req.body.device) || "").replace(/[^a-z0-9-]/gi, "").slice(0, 64);
    let m = String((req.body && req.body.mobile) || "").replace(/\D/g, "");
    if (m.length === 12 && m.startsWith("91")) m = m.slice(2);
    if (!device || m.length < 7) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    const dRef = db.collection("bbapp_devices").doc(device);
    const mRef = db.collection("bbapp_mobiles").doc(m);
    const out = await db.runTransaction(async (tx) => {
      const d = await tx.get(dRef);
      const mm = await tx.get(mRef);
      const mobiles = (d.exists && d.get("mobiles")) || [];
      const devices = (mm.exists && mm.get("devices")) || [];
      const newPhone = devices.length > 0 && !devices.includes(device);
      if (!mobiles.includes(m)) {
        if (mobiles.length >= 2) return { allowed: false, mobiles };
        mobiles.push(m);
        tx.set(dRef, { mobiles, at: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
      }
      if (!devices.includes(device)) {
        tx.set(mRef, { devices: [...devices, device] }, { merge: true });
      }
      return { allowed: true, index: mobiles.indexOf(m) + 1, first: mobiles[0], newPhone, phone: device.slice(-4).toUpperCase() };
    });
    return res.json({ ok: true, ...out });
  },
);


/** Every 10 minutes: orders 3 h past "Maal nikalna chalu" get their Packed button. */
const { onSchedule } = require("firebase-functions/v2/scheduler");
exports.packTimer = onSchedule(
  { schedule: "every 10 minutes", region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 120, memory: "256MiB" },
  async () => {
    const db = admin.firestore();
    const snap = await db.collection("bbapp_orders").where("status", "==", "getting_ready").get();
    for (const doc of snap.docs) {
      const d = doc.data();
      if (d.packShown || !d.readyAt || !d.msg || !d.chat) continue;
      if (Date.now() - d.readyAt.toMillis() < PACK_AFTER_MS) continue;
      await tg("editMessageReplyMarkup", { chat_id: d.chat, message_id: d.msg, reply_markup: statusKeyboard(doc.id, d) });
      await doc.ref.set({ packShown: true }, { merge: true });
    }
  },
);


/* ───────────── BILL GROUP + PAYMENT (owner, 11-Oct-2026) ─────────────
 * A bill photo posted in any group with "Bill" in its name is read (party
 * name, mobile, GSTIN, bill no., total), matched to that party's open order,
 * linked to it (status Bill sent for payment) and shown in the party's app.
 * The party sends a payment screenshot from the app → it is posted under the
 * order in the Party order group and the order ticks Payment received.
 */
async function tgFileBytes(fileId) {
  const f = await tg("getFile", { file_id: fileId });
  const path = f && f.result && f.result.file_path;
  if (!path) return null;
  const r = await fetch(`https://api.telegram.org/file/bot${TG_TOKEN.value()}/${path}`);
  return r.ok ? Buffer.from(await r.arrayBuffer()) : null;
}

const BILL_PROMPT =
  "This is a SALES BILL / TAX INVOICE from B.B. SYNTHETICS (AKN ZONE), Surat. Read the BUYER (Bill to / party) details — " +
  "NOT the seller. Return JSON: buyerName (as printed), buyerMobile (digits, may be inside the address), buyerGstin, " +
  "billNo (as printed, e.g. 4231/S), billDate, grandTotal (number, rupees). Use null when not printed.";
const BILL_SCHEMA = { type: "object", properties: {
  buyerName: { type: ["string", "null"] }, buyerMobile: { type: ["string", "null"] }, buyerGstin: { type: ["string", "null"] },
  billNo: { type: ["string", "null"] }, billDate: { type: ["string", "null"] }, grandTotal: { type: ["number", "null"] } },
  required: ["buyerName"] };

async function geminiJson(bytes, mime, prompt, schema) {
  const { MODELS } = require("./orderVision");
  for (const model of MODELS) {
    try {
      const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
        method: "POST", headers: { "x-goog-api-key": GEMINI_API_KEY.value(), "Content-Type": "application/json" },
        body: JSON.stringify({ contents: [{ role: "user", parts: [{ inlineData: { mimeType: mime, data: bytes.toString("base64") } }, { text: prompt }] }],
          generationConfig: { responseMimeType: "application/json", responseJsonSchema: schema, temperature: 0 } }),
      });
      if (!r.ok) continue;
      const j = await r.json();
      return JSON.parse(j.candidates[0].content.parts.map((p) => p.text || "").join(""));
    } catch (e) { /* next model */ }
  }
  return null;
}

const normName = (x) => String(x || "").toUpperCase().replace(/\(.*?\)/g, " ").replace(/[^A-Z0-9]/g, "");

/** Moves an order to a step automatically and redraws its group message. */
async function autoStep(db, ref, k, by, extra) {
  const step = STEPS.find((x) => x.k === k);
  const docRef = db.collection("bbapp_orders").doc(ref);
  const before = (await docRef.get()).data() || {};
  if (ORDER.indexOf(before.status || "received") >= ORDER.indexOf(step.status)) {
    if (extra && Object.keys(extra).length) await docRef.set(extra, { merge: true });
    return before;
  }
  await docRef.set({ status: step.status, [step.by]: by, [step.at]: admin.firestore.FieldValue.serverTimestamp(),
    statusAt: admin.firestore.FieldValue.serverTimestamp(),
    log: admin.firestore.FieldValue.arrayUnion({ a: "do", k, by, at: Date.now(), uid: 0 }), ...(extra || {}) }, { merge: true });
  const d = (await docRef.get()).data() || {};
  if (d.chat && d.msg) {
    await tg("editMessageText", { chat_id: d.chat, message_id: d.msg, text: statusText(d, ""), parse_mode: "HTML",
      disable_web_page_preview: true, reply_markup: statusKeyboard(ref, d) });
  }
  return d;
}

async function handleBillPhoto(db, m) {
  const reply = (text) => tg("sendMessage", { chat_id: m.chat.id, reply_to_message_id: m.message_id, text });
  const fileId = m.photo ? m.photo[m.photo.length - 1].file_id : m.document.file_id;
  const mime = m.photo ? "image/jpeg" : (m.document.mime_type || "image/jpeg");
  const bytes = await tgFileBytes(fileId);
  if (!bytes) return reply("⚠️ Could not download this bill.");
  const b = await geminiJson(bytes, mime, BILL_PROMPT, BILL_SCHEMA);
  if (!b) return reply("⚠️ Could not read this bill (AI busy) — please send it again in a few minutes.");
  const mob = String(b.buyerMobile || "").replace(/\D/g, "").slice(-10);
  const nm = normName(b.buyerName);
  // Open orders (not yet billed), newest first; main orders before add-ons.
  const snap = await db.collection("bbapp_orders").where("status", "in", ["received", "getting_ready"]).get();
  const all = snap.docs.map((x) => ({ id: x.id, ...x.data() }))
    .filter((o) => (mob && o.mobile && o.mobile === mob) || (nm && o.billName && normName(o.billName) === nm)
      || (nm && o.billName && (normName(o.billName).includes(nm) || nm.includes(normName(o.billName)))));
  if (!all.length) {
    return reply(`❓ No open app order found for ${b.buyerName || "this party"}${mob ? " (" + mob + ")" : ""}. Bill not sent.`);
  }
  // Owner: steps strictly in order — the bill only after "Maal nikalna chalu".
  const cands = all.filter((o) => o.status === "getting_ready");
  if (!cands.length) {
    const o = all[0];
    return reply(`⛔ ${o.billName} — ${o.serial ? "ORDER NO. " + o.serial : "this order"}: first tap "🧺 Maal nikalna chalu" on the order, then send the bill again.`);
  }
  cands.sort((a, c) => (c.statusAt ? c.statusAt.toMillis() : 0) - (a.statusAt ? a.statusAt.toMillis() : 0));
  const main = cands.find((o) => !o.addOnTo) || cands[0];
  const linked = [main, ...cands.filter((o) => o.addOnTo && (o.addOnTo === main.id))];
  const extra = { billFileId: fileId, billMime: mime, billNo: b.billNo || null, billTotal: b.grandTotal || null,
    billSentAt: Date.now(), billGroup: main.id };
  for (const o of linked) {
    await autoStep(db, o.id, "b", "Bill group", extra);
  }
  // One message per customer chat (all linked orders share the mobile).
  await addChat(db, main.id, { from: "shop", text: "🧾 Sir, please make the payment — Bill" + (b.billNo ? " " + b.billNo : "") +
    (b.grandTotal ? " · " + inr(b.grandTotal) : "") + ". Send the payment screenshot here 🙏", fileId, mime });
  const no = main.serial ? `ORDER NO. ${main.serial}` : "the order";
  return reply(`✅ Bill sent to ${main.billName} — ${no}${b.billNo ? " · Bill " + b.billNo : ""}${b.grandTotal ? " · ₹" + b.grandTotal : ""}`);
}

const inr = (n) => "₹" + Math.round(Number(n) || 0).toLocaleString("en-IN");

const PAY_PROMPT = "This should be a payment screenshot (UPI app like GPay/PhonePe/Paytm/BHIM, or a bank app NEFT/RTGS/IMPS). " +
  "Return JSON: amount (number, rupees paid), date (YYYY-MM-DD of the payment as shown), time (HH:MM 24-hour as shown), " +
  "txnId (UPI ref no. / UTR / transaction id, digits and letters only), success (true only if it clearly says successful/completed/paid), " +
  "payee (receiver name). Use null when not shown. If it is not a payment screenshot, amount = null.";
const PAY_SCHEMA = { type: "object", properties: {
  amount: { type: ["number", "null"] }, date: { type: ["string", "null"] }, time: { type: ["string", "null"] },
  txnId: { type: ["string", "null"] }, success: { type: ["boolean", "null"] }, payee: { type: ["string", "null"] } },
  required: ["amount"] };

/**
 * Owner (11-Oct-2026): every payment screenshot is read and added up against
 * the bill. Only payments made AFTER the bill was sent count; the same UTR
 * never counts twice; short → "please pay ₹X more sir"; Payment received is
 * ticked only when the bill is fully paid. Returns true when fully paid.
 */
async function checkPayment(db, ref, img) {
  const first = (await db.collection("bbapp_orders").doc(ref).get()).data() || {};
  const mainRef = first.billGroup || ref;
  const mainDoc = db.collection("bbapp_orders").doc(mainRef);
  const m = (await mainDoc.get()).data() || {};
  const staff = (text) => m.chat && tg("sendMessage", { chat_id: m.chat, reply_to_message_id: m.msg || undefined, text });
  const say = (text) => addChat(db, mainRef, { from: "shop", text });
  const head = `${m.billName || "Party"}${m.serial ? " · ORDER NO. " + m.serial : ""}`;

  const p = await geminiJson(img, "image/jpeg", PAY_PROMPT, PAY_SCHEMA);
  if (!p || !p.amount || p.amount <= 0) {
    await staff(`💰❓ ${head}: could not read an amount from this screenshot — please check it.`);
    return false;
  }
  if (p.success === false) {
    await say(`⚠️ This payment of ${inr(p.amount)} does not show as successful. Please send the screenshot of a successful payment.`);
    await staff(`💰⚠️ ${head}: screenshot ${inr(p.amount)} is NOT successful — not counted.`);
    return false;
  }
  // Time on the screenshot (India time) must be after the bill was sent.
  const sentAt = m.billSentAt || (m.billAt && m.billAt.toMillis ? m.billAt.toMillis() : 0);
  const nowIst = new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10);
  const tm = /^\d{1,2}:\d{2}$/.test(String(p.time || "")) ? String(p.time).padStart(5, "0") : null;
  const dt = /^\d{4}-\d{2}-\d{2}$/.test(String(p.date || "")) ? p.date : (tm ? nowIst : null);
  const paidAt = dt ? Date.parse(`${dt}T${tm || "23:59"}:00+05:30`) : NaN;
  if (!isNaN(paidAt) && sentAt && paidAt < Math.floor(sentAt / 60000) * 60000) {
    const when = new Date(sentAt + 5.5 * 3600e3).toISOString().slice(0, 16).replace("T", " ");
    await say(`⚠️ This screenshot (${inr(p.amount)}, ${dt}${tm ? " " + tm : ""}) is from before the bill was sent (${when}). ` +
      "Please send the screenshot of the payment made for this bill.");
    await staff(`💰⛔ ${head}: old screenshot ${inr(p.amount)} dated ${dt}${tm ? " " + tm : ""} (bill sent ${when}) — not counted.`);
    return false;
  }
  if (!isNaN(paidAt) && paidAt > Date.now() + 15 * 60e3) {
    await staff(`💰❓ ${head}: screenshot ${inr(p.amount)} shows a future time ${dt} ${tm || ""} — please check it.`);
    return false;
  }
  const txn = String(p.txnId || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  const r = await db.runTransaction(async (t) => {
    const cur = (await t.get(mainDoc)).data() || {};
    const pays = cur.payments || [];
    if (txn && pays.some((x) => x.txn === txn)) return { dup: true, total: pays.reduce((a, x) => a + x.amt, 0) };
    pays.push({ amt: Number(p.amount), txn, paidAt: isNaN(paidAt) ? null : paidAt, at: Date.now() });
    const total = pays.reduce((a, x) => a + x.amt, 0);
    t.set(mainDoc, { payments: pays, paidTotal: total }, { merge: true });
    return { dup: false, total };
  });
  if (r.dup) {
    await say(`ℹ️ This payment (${inr(p.amount)}) is already counted. Total received ${inr(r.total)}.`);
    return false;
  }
  const bill = Number(m.billTotal) || 0;
  if (!bill) {
    await say(`✅ Payment ${inr(p.amount)} received. Our staff will confirm the bill amount.`);
    await staff(`💰 ${head}: ${inr(p.amount)} received (total ${inr(r.total)}) — bill amount not known, please tick Payment received after checking.`);
    return false;
  }
  const due = bill - r.total;
  if (due > 1) {
    await say(`✅ Received ${inr(p.amount)} — total ${inr(r.total)} of bill ${inr(bill)}. Sir, please pay ${inr(due)} more and send the screenshot 🙏`);
    await staff(`💰 ${head}: +${inr(p.amount)} → ${inr(r.total)} / ${inr(bill)} · balance ${inr(due)}`);
    return false;
  }
  await say(`✅ Full payment received — ${inr(r.total)} for bill ${inr(bill)}. Thank you sir 🙏`);
  await staff(`💰✅ ${head}: FULL payment ${inr(r.total)} / ${inr(bill)}${due < -1 ? " (extra " + inr(-due) + ")" : ""}`);
  const linked = await db.collection("bbapp_orders").where("billGroup", "==", mainRef).get();
  const refs = new Set([mainRef, ...linked.docs.map((x) => x.id)]);
  for (const id of refs) await autoStep(db, id, "y", "Payment check (screenshots)", {});
  return true;
}

/** App: the bill image for an order (party taps VIEW BILL). */
exports.billImage = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 30, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const d = ref ? (await admin.firestore().collection("bbapp_orders").doc(ref).get()).data() : null;
    if (!d || !d.billFileId) return res.json({ ok: false, error: "no bill yet" });
    const bytes = await tgFileBytes(d.billFileId);
    if (!bytes) return res.json({ ok: false });
    return res.json({ ok: true, mime: d.billMime || "image/jpeg", billNo: d.billNo || null, total: d.billTotal || null,
      data: bytes.toString("base64") });
  },
);

/** App: party's payment screenshot → posted under the order → Payment received. */
exports.paymentProof = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN, GEMINI_API_KEY], timeoutSeconds: 60, memory: "512MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const img = Buffer.from(String((req.body && req.body.image) || ""), "base64");
    if (!ref || !img.length || img.length > 6 * 1024 * 1024) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    const d = (await db.collection("bbapp_orders").doc(ref).get()).data();
    if (!d || !d.chat) return res.json({ ok: false, error: "order not found" });
    const fd = new FormData();
    fd.append("chat_id", String(d.chat));
    if (d.msg) fd.append("reply_to_message_id", String(d.msg));
    fd.append("caption", `💰 Payment screenshot — ${d.billName || ""}${d.serial ? " · ORDER NO. " + d.serial : ""}`);
    fd.append("photo", new Blob([img], { type: "image/jpeg" }), "payment.jpg");
    await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendPhoto`, { method: "POST", body: fd });
    let paid = false;
    if ((d.status || "received") === "bill_sent") paid = await checkPayment(db, ref, img);
    return res.json({ ok: true, paid });
  },
);


/* ───────────── DISPATCH + BILTY from the Daily Parcel Report (owner 11-Oct) ─────────────
 * The shop PC (CLE\AKNZonePieces\dispatch_sync.py) reads the Daily Parcel
 * Report Excel (read-only) every 15 min and posts {billNo, parcelDate, bilty}
 * rows here. An order whose bill no. (read off the bill in the Bill group)
 * shows a parcel date ticks Dispatched; a bilty no. ticks Bilty.
 */
const normBill = (x) => String(x || "").toUpperCase().replace(/\s+/g, "");
exports.syncDispatch = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 120, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const rows = (req.body && req.body.rows) || [];
    const byBill = new Map();
    for (const r of rows) if (r && r.billNo) byBill.set(normBill(r.billNo), r);
    const db = admin.firestore();
    const snap = await db.collection("bbapp_orders").where("status", "in", ["bill_sent", "payment_received", "dispatched"]).get();
    let disp = 0, bil = 0;
    for (const doc of snap.docs) {
      const d = doc.data();
      const r = d.billNo && byBill.get(normBill(d.billNo));
      if (!r) continue;
      if (r.parcelDate && d.status === "payment_received") {
        await autoStep(db, doc.id, "d", `Daily Parcels (${r.parcelDate})`, { parcelDate: String(r.parcelDate) });
        disp++;
      }
      if (r.bilty) {
        const cur = ((await doc.ref.get()).data() || {}).status;
        if (cur === "dispatched") {
          await autoStep(db, doc.id, "l", "Bilty entry", { lr: `Bilty ${r.bilty}`, bilty: String(r.bilty) });
          bil++;
        }
      }
    }
    return res.json({ ok: true, checked: snap.size, dispatched: disp, bilty: bil });
  },
);


/* ───────────── CHAT per order (owner, 11-Oct-2026) ─────────────
 * Party ↔ shop messages for one order. The party writes in the app → the
 * message is posted under the order in the Party order group; staff answer
 * with a Telegram REPLY → it shows in the party's chat. The bill from the Bill
 * group lands in the chat too. A photo sent while the bill is pending = the
 * payment screenshot (ticks Payment received).
 */
async function addChat(db, ref, m) {
  const o = (await db.collection("bbapp_orders").doc(ref).get()).data() || {};
  await db.collection("bbapp_chat").add({ ref, cust: o.mobile || "", from: m.from, text: m.text || "",
    fileId: m.fileId || null, mime: m.mime || null, by: m.by || "", at: Date.now() });
}

exports.chatSend = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN, GEMINI_API_KEY], timeoutSeconds: 60, memory: "512MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("c:" + ip)) return res.status(429).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const text = String((req.body && req.body.text) || "").slice(0, 2000);
    const img = req.body && req.body.image ? Buffer.from(String(req.body.image), "base64") : null;
    if (!ref || (!text && !img) || (img && img.length > 6 * 1024 * 1024)) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    const d = (await db.collection("bbapp_orders").doc(ref).get()).data();
    if (!d || !d.chat) return res.json({ ok: false, error: "order not found" });
    const head = `💬 ${d.billName || "Party"}${d.serial ? " · ORDER NO. " + d.serial : ""}`;
    let sent;
    if (img) {
      const fd = new FormData();
      fd.append("chat_id", String(d.chat));
      if (d.msg) fd.append("reply_to_message_id", String(d.msg));
      fd.append("caption", `${head}${text ? "\n" + text : ""}`.slice(0, 1000));
      fd.append("photo", new Blob([img], { type: "image/jpeg" }), "chat.jpg");
      sent = await (await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendPhoto`, { method: "POST", body: fd })).json();
    } else {
      sent = await tg("sendMessage", { chat_id: d.chat, reply_to_message_id: d.msg || undefined, text: `${head}\n${text}` });
    }
    const mid = sent && sent.result && sent.result.message_id;
    if (mid) await db.collection("bbapp_msgmap").doc(`${d.chat}_${mid}`).set({ ref });
    const fileId = sent && sent.result && sent.result.photo ? sent.result.photo[sent.result.photo.length - 1].file_id : null;
    await addChat(db, ref, { from: "party", text, fileId, mime: fileId ? "image/jpeg" : null });
    let paid = false;
    if (img && (d.status || "received") === "bill_sent") paid = await checkPayment(db, ref, img);
    return res.json({ ok: true, paid });
  },
);

exports.chatList = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    // ONE chat per customer (owner): all messages for this mobile.
    const cust = String((req.body && req.body.mobile) || "").replace(/\D/g, "").slice(-10);
    if (cust.length !== 10) return res.status(400).json({ ok: false });
    const snap = await admin.firestore().collection("bbapp_chat").where("cust", "==", cust).get();
    const msgs = snap.docs.map((x) => ({ id: x.id, ...x.data() })).sort((a, b) => a.at - b.at).slice(-200)
      .map((m) => ({ id: m.id, from: m.from, text: m.text, at: m.at, by: m.by, file: !!m.fileId, mime: m.mime }));
    return res.json({ ok: true, msgs });
  },
);

exports.chatFile = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 30, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const cust = String((req.body && req.body.mobile) || "").replace(/\D/g, "").slice(-10);
    const id = String((req.body && req.body.id) || "").slice(0, 64);
    const m = id ? (await admin.firestore().collection("bbapp_chat").doc(id).get()).data() : null;
    if (!m || m.cust !== cust || !m.fileId) return res.json({ ok: false });
    const bytes = await tgFileBytes(m.fileId);
    if (!bytes) return res.json({ ok: false });
    return res.json({ ok: true, mime: m.mime || "image/jpeg", data: bytes.toString("base64") });
  },
);

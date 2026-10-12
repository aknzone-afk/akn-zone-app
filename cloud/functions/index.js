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
// Apple push key "AKN Push" (Key ID YS956XB4FC, team DWJM58G45V) — iPhone
// push goes straight to Apple (APNs), owner 11-Oct-2026.
const APNS_KEY = defineSecret("BBAPP_APNS_KEY");
const APP_KEY = "akn-zone-app-2026"; // not a secret — only keeps random traffic out
// Shop-PC programs (NewPartyBot, parties_sync, dispatch_sync, count_pieces)
// prove themselves with this key (C:\BotSecrets\bbapp_pc_key.txt). The
// app's key sits inside the APK, so it alone must not open party data.
const PC_KEY = defineSecret("BBAPP_PC_KEY");
const pcOk = (req) => {
  try { return !!req.get("x-pc-key") && req.get("x-pc-key") === PC_KEY.value().trim(); } catch (e) { return false; }
};
/** Cut a text at a line end (never inside an HTML tag). */
const cutAt = (x, n) => {
  const t = String(x || "");
  if (t.length <= n) return t;
  const i = t.lastIndexOf("\n", n);
  return t.slice(0, i > n / 2 ? i : n) + "\n…";
};
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
  { region: "asia-south1", secrets: [GEMINI_API_KEY, PC_KEY], timeoutSeconds: 120, memory: "512MiB", maxInstances: 5, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).json({ ok: false });
    if (!pcOk(req)) return res.status(403).json({ ok: false });
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
    if (!PARTIES) PARTIES = require("./parties.json");
    // Owner 12-Oct: a NEW-looking customer whose GST / PAN is already a party
    // → show that account (match by GSTIN, or PAN inside a GSTIN).
    const tax = String((req.body && req.body.tax) || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (tax) {
      const isGst = /^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$/.test(tax);
      const isPan = /^[A-Z]{5}\d{4}[A-Z]$/.test(tax);
      if (!isGst && !isPan) return res.json({ ok: true, parties: [] });
      const seen = new Set(), out = [];
      for (const [mob, recs] of Object.entries(PARTIES)) {
        for (const r of recs) {
          const g = String(r.gstin || "").toUpperCase();
          const hit = isGst ? g === tax : (g === tax || (g.length === 15 && g.slice(2, 12) === tax));
          if (hit && !seen.has(r.name)) {
            seen.add(r.name);
            out.push({ ...r }); // never the party's mobile (privacy)
          }
        }
        if (out.length >= 5) break;
      }
      logger.info("lookupParty tax", { found: out.length });
      return res.json({ ok: true, parties: out });
    }
    let d = String((req.body && req.body.mobile) || "").replace(/\D/g, "");
    if (d.length > 10) d = d.slice(-10); // +91 / 0 / repeated prefix — the last 10 digits
    if (d.length === 12 && d.startsWith("91")) d = d.slice(2);
    if (d.length === 11 && d.startsWith("0")) d = d.slice(1);
    if (!/^[6-9]\d{9}$/.test(d)) return res.json({ ok: false, error: "bad mobile" });
    // Owner 12-Oct: ledgers made today (NewPartyBot / app) are known at once.
    const live = await admin.firestore().collection("bbapp_parties_live").doc(d).get();
    // Live entries are a bridge until the 2-hourly Tally sync — never older
    // than a day, and the sync removes ledgers deleted in Tally.
    const fresh = live.exists && Date.now() - (live.get("at") || 0) < 86400e3 ? (live.get("list") || []) : [];
    const names = new Set(fresh.map((x) => x.name));
    const list = [...fresh, ...(PARTIES[d] || []).filter((x) => !names.has(x.name))].slice(0, 5);
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
  const tail = `\n\n<b>STATUS</b>\n${lines.join("\n")}`;
  // Telegram edits fail above 4096 chars — trim the details, keep the status.
  return (base.length + tail.length > 4000 ? cutAt(base, 4000 - tail.length) : base) + tail;
}

/**
 * Buttons (owner 11-Oct-2026): a done step's button shows just WHO + WHEN,
 * e.g. "🧺 ✅ Akshay 11:10" (tap again = undo, only by that person). After an
 * undo: a plain line "↩️ Undone Akshay 11:20" and the step's button again.
 * Automatic steps show a ⏳ waiting line.
 */
const firstName = (x) => String(x || "").trim().split(/\s+/)[0] || "?";
function statusKeyboard(ref, d) {
  const cur = (d && d.status) || "received";
  const ci = ORDER.indexOf(cur);
  const log = (d && d.log) || [];
  const rows = [];
  const last = log[log.length - 1];
  const curStep = STEPS.find((x) => x.status === cur);
  if (curStep) {
    const done = [...log].reverse().find((e) => e.a === "do" && e.k === curStep.k);
    const icon = String(curStep.label).split(" ")[0];
    const who = done ? `${firstName(done.by)} ${hhmm(done.at)}` : "";
    rows.push([{ text: `${icon} ✅ ${who}`.trim().slice(0, 60), callback_data: `s|${curStep.k}|${ref}`.slice(0, 64) }]);
  }
  if (last && last.a === "undo") {
    rows.push([{ text: `↩️ Undone ${firstName(last.by)} ${hhmm(last.at)}`.slice(0, 60), callback_data: "n" }]);
  }
  const next = STEPS.find((x) => ORDER.indexOf(x.status) === ci + 1);
  if (next && next.auto) {
    rows.push([{ text: next.wait || "⏳ Waiting", callback_data: "n" }]);
  } else if (next) {
    rows.push([{ text: next.label, callback_data: `s|${next.k}|${ref}`.slice(0, 64) }]);
  }
  return { inline_keyboard: rows };
}

async function tg(method, body) {
  try {
    const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/${method}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    const j = await r.json().catch(() => ({}));
    if (!j.ok) logger.warn("tg " + method, { code: j.error_code, desc: j.description, chat: body && body.chat_id });
    return j;
  } catch (e) {
    logger.warn("tg " + method, { error: e.message });
    return {};
  }
}

exports.tgWebhook = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN, TG_SECRET, GEMINI_API_KEY, APNS_KEY], timeoutSeconds: 120, memory: "256MiB", maxInstances: 3, invoker: "public" },
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
      } else if (u.message && /^\/?count\s+/i.test(String(u.message.text || ""))) {
        // Owner 12-Oct: fix a wrong saree count — "count T58 (2) 6".
        const mm = /^\/?count\s+(.+?)\s*[=:-]?\s*(\d{1,3})\s*(pcs|pc|pieces)?\s*$/i.exec(String(u.message.text).trim());
        let txt = "Send: count <design no.> <pieces>   e.g.  count T58 (2) 6";
        if (mm) {
          const key = mm[1].toUpperCase().replace(/[^A-Z0-9]/g, "");
          const n = Number(mm[2]);
          if (key && n >= 1 && n <= 200) {
            await db.collection("bbapp_counts").doc(key).set({ n, design: mm[1].trim(), by: (u.message.from && u.message.from.first_name) || "", at: Date.now() });
            txt = `✅ ${mm[1].trim()} = ${n} sarees — the app uses this count now.`;
          }
        }
        await tg("sendMessage", { chat_id: u.message.chat.id, reply_to_message_id: u.message.message_id, text: txt });
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
  { region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const chat = String((req.body && req.body.chat) || "").replace(/[^0-9-]/g, "");
    const msg = Number(req.body && req.body.msg) || 0;
    const text = cutAt((req.body && req.body.text) || "", 3500);
    const mobile = String((req.body && req.body.mobile) || "").replace(/\D/g, "").slice(-10);
    const billName = String((req.body && req.body.billName) || "").slice(0, 120);
    const serial = Number(req.body && req.body.serial) || null;
    const addOnTo = String((req.body && req.body.addOnTo) || "").slice(0, 40) || null;
    if (!ref || !chat || !msg) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    await db.collection("bbapp_msgmap").doc(`${chat}_${msg}`).set({ ref });
    // Tester 13-Oct: staff also reply to a photo of the album, to "ORDER NO. N"
    // or to the dots — those replies must reach the customer too.
    const extra = [...new Set(((req.body && req.body.extra) || []).map(Number).filter((n) => n > 0))].slice(0, 60);
    if (extra.length) {
      const batch = db.batch();
      for (const id of extra) batch.set(db.collection("bbapp_msgmap").doc(`${chat}_${id}`), { ref });
      await batch.commit();
    }
    const docRef = db.collection("bbapp_orders").doc(ref);
    const d = await docRef.get();
    // New customer's details (for the Tally ledger via NewPartyBot).
    const c = req.body && req.body.cust;
    const cust = c && typeof c === "object" && c.kind !== "old" ? Object.fromEntries(
      ["country", "billName", "address", "bookingPlace", "pincode", "mobile", "transport", "taxId", "kind"]
        .map((k) => [k, String(c[k] || "").slice(0, 300)])) : null;
    await docRef.set({ msg, chat, mobile, billName, serial, addOnTo, ...(text ? { text } : {}), ...(cust ? { cust } : {}), ...(d.exists && d.get("status") ? {} : {
      status: "received", statusAt: admin.firestore.FieldValue.serverTimestamp() }) }, { merge: true });
    // Owner 12-Oct: a new customer's verified 10% advance is the order's
    // first payment (the bill balance asks only for the rest) + its
    // screenshot goes under the order in the group.
    const adv = (await db.collection("bbapp_advances").doc(ref).get()).data();
    if (adv && adv.state === "paid" && !(d.exists && d.get("advanceAmt"))) {
      // One payment per screenshot (a part-paid advance has 2 UTRs): the
      // same screenshot sent again later as a "bill payment" is then a dup.
      const parts = (adv.parts && adv.parts.length) ? adv.parts
        : [{ amt: Number(adv.paid), utr: adv.utr || null, paidAt: adv.paidAt || null }];
      const payments = parts.map((x) => ({ amt: Number(x.amt) || 0, txn: x.utr || "", paidAt: x.paidAt || null, at: Date.now(), kind: "advance" }));
      await docRef.set({ advanceAmt: adv.paid, advanceUtr: adv.utr || null, payments,
        paidTotal: payments.reduce((t, x) => t + x.amt, 0) }, { merge: true });
      // Owner 12-Oct: the advance screenshot is the FIRST message of the
      // customer's chat (and goes to the new-party group with the ledger).
      try {
        const [bytes] = await admin.storage().bucket().file(adv.path).download();
        await addChat(db, ref, { from: "party", text: `💰 Advance ${inr(adv.paid)} paid (10%)${adv.utr ? " · UTR " + adv.utr : ""}`,
          bytes, mime: "image/jpeg" });
      } catch (e) { logger.warn("advance photo", { ref, error: e.message }); }
    }
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
      // Test 12-Oct: just TYPING / looking up a number (peek) must not use up
      // the 2-numbers-per-phone limit — only a placed order links it.
      if (req.body && req.body.peek) {
        if (!mobiles.includes(m) && mobiles.length >= 2) return { allowed: false, mobiles };
        return { allowed: true, index: mobiles.includes(m) ? mobiles.indexOf(m) + 1 : mobiles.length + 1,
          first: mobiles[0] || null, newPhone, phone: device.slice(-4).toUpperCase() };
      }
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
  // Tester 13-Oct: mobile > exact name > part of the name (6+ letters). Only
  // the best class counts, and a part-match shared by two parties is refused.
  const score = (o) => {
    const on = normName(o.billName);
    if (mob && o.mobile && o.mobile === mob) return 3;
    if (nm && on && on === nm) return 2;
    if (nm && on && nm.length >= 6 && on.length >= 6 && (on.includes(nm) || nm.includes(on))) return 1;
    return 0;
  };
  const scored = snap.docs.map((x) => ({ id: x.id, ...x.data() })).map((o) => ({ ...o, _s: score(o) })).filter((o) => o._s > 0);
  const best = scored.reduce((t, o) => Math.max(t, o._s), 0);
  const all = scored.filter((o) => o._s === best);
  if (best === 1 && new Set(all.map((o) => o.mobile || o.billName)).size > 1) {
    const names = [...new Set(all.map((o) => `${o.billName}${o.serial ? " (ORDER NO. " + o.serial + ")" : ""}`))].join(", ");
    return reply(`❓ "${b.buyerName || "?"}" could be ${names}. Bill not sent — please put the party's mobile number on the bill, or send it again with the exact name.`);
  }
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
  const advPaid = Number(main.paidTotal || 0);
  const balance = b.grandTotal ? Math.max(0, Number(b.grandTotal) - advPaid) : 0;
  await addChat(db, main.id, { from: "shop", text: "🧾 Sir, please make the payment — Bill" + (b.billNo ? " " + b.billNo : "") +
    (b.grandTotal ? " · " + inr(b.grandTotal) : "") +
    (advPaid > 0 && b.grandTotal ? ` (advance ${inr(advPaid)} received — balance ${inr(balance)})` : "") +
    ". Send the payment screenshot here 🙏", fileId, mime });
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
  const staff = async (text) => {
    if (!m.chat) return;
    const r = await tg("sendMessage", { chat_id: m.chat, reply_to_message_id: m.msg || undefined, text });
    const mid = r && r.result && r.result.message_id; // staff can REPLY to this note → customer's chat
    if (mid) await db.collection("bbapp_msgmap").doc(`${m.chat}_${mid}`).set({ ref: mainRef });
  };
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
  { region: "asia-south1", secrets: [TG_TOKEN, GEMINI_API_KEY, APNS_KEY], timeoutSeconds: 60, memory: "512MiB", maxInstances: 3, invoker: "public", cors: true },
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
    const sent = await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendPhoto`, { method: "POST", body: fd })
      .then((r) => r.json()).catch(() => ({}));
    const mid = sent && sent.result && sent.result.message_id;
    if (mid) await db.collection("bbapp_msgmap").doc(`${d.chat}_${mid}`).set({ ref: d.billGroup || ref });
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
  { region: "asia-south1", secrets: [PC_KEY, TG_TOKEN], timeoutSeconds: 120, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
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
  let storagePath = null;
  try {
    storagePath = await mirrorToAknChat(db, o, m);
  } catch (e) {
    logger.warn("AKN Chat mirror failed", { ref, error: e.message });
  }
  await db.collection("bbapp_chat").add({ ref, cust: o.mobile || "", from: m.from, text: m.text || "",
    fileId: m.fileId || null, storagePath: m.fileId ? null : storagePath, mime: m.mime || null,
    by: m.by || "", at: Date.now(), mirrored: true });
  if (m.from === "shop" && o.mobile) await pushTo(db, String(o.mobile).replace(/\D/g, "").slice(-10), m.text || "📎 Sent you a file");
}

/* ───────────── AKN Chat "AKN App" tab (owner, 11-Oct-2026) ─────────────
 * Every app chat also appears in the AKN Chat staff app as its own chip
 * "AKN App" (pseudo number id 99999, never a WhatsApp number). Staff reply
 * there like any chat; aknChatOut below carries the reply to the customer's
 * app. Safety: bot_logs/{msgId} is created FIRST so AKN Chat's WhatsApp bot
 * never answers these; botEnabled false; numbers["99999"].bot false.
 */
const AKZ_PNID = "99999";
const akzChatId = (mob) => `91${mob}_${AKZ_PNID}`;
let akzTabReady = false;

async function mirrorToAknChat(db, o, m) {
  const mob = String(o.mobile || "").replace(/\D/g, "").slice(-10);
  if (mob.length !== 10) return null;
  const { Timestamp, FieldValue } = admin.firestore;
  if (!akzTabReady) {
    await db.collection("settings").doc("app").set({ numbers: { [AKZ_PNID]: { label: "AKN App", bot: false } } }, { merge: true });
    akzTabReady = true;
  }
  const chatId = akzChatId(mob);
  const inbound = m.from === "party";
  const msgId = `aknz_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  // Media → Storage (AKN Chat reads wa-media/…), with a download URL.
  let bytes = m.bytes || null;
  if (!bytes && m.fileId) bytes = await tgFileBytes(m.fileId);
  const mime = m.mime || (bytes ? "image/jpeg" : null);
  const isPdf = String(mime || "").includes("pdf");
  let media = {};
  let storagePath = null;
  if (bytes) {
    storagePath = `wa-media/${AKZ_PNID}/91${mob}/${msgId}.${isPdf ? "pdf" : "jpg"}`;
    const token = require("crypto").randomUUID();
    const file = admin.storage().bucket().file(storagePath);
    await file.save(bytes, { contentType: mime, metadata: { metadata: { firebaseStorageDownloadTokens: token } } });
    const url = `https://firebasestorage.googleapis.com/v0/b/${file.bucket.name}/o/${encodeURIComponent(storagePath)}?alt=media&token=${token}`;
    media = { mediaPath: storagePath, mediaUrl: url, mediaMime: mime, mediaStatus: "stored", fileSize: bytes.length,
      ...(isPdf ? { fileName: "bill.pdf" } : {}) };
  }
  const type = bytes ? (isPdf ? "document" : "image") : "text";
  const text = String(m.text || "");
  if (inbound) await db.collection("bot_logs").doc(msgId).set({ source: "aknzone-app", skip: true });
  const now = m.at ? Timestamp.fromMillis(m.at) : Timestamp.now();
  const msg = {
    direction: inbound ? "in" : "out", from: inbound ? "customer" : "bot", type,
    status: inbound ? "received" : "sent", statusRank: inbound ? null : 1,
    wamid: null, waId: `91${mob}`, phoneNumberId: AKZ_PNID, timestamp: now,
    createdAt: FieldValue.serverTimestamp(), replyToWamid: null, senderStaffId: null, error: null,
    mediaStatus: "none", text: type === "text" ? text : null, caption: type === "text" ? null : (text || null),
    mediaPath: null, mediaMime: null, fileName: null, fileSize: null, aknzSource: true, ...media,
  };
  const chatRef = db.collection("chats").doc(chatId);
  await db.runTransaction(async (t) => {
    const c = await t.get(chatRef);
    const base = c.exists ? {} : { pinned: false, needsAttention: false, botPausedUntil: null, createdAt: now,
      profileName: o.billName || `+91 ${mob}` };
    t.set(chatRef.collection("messages").doc(msgId), msg);
    t.set(chatRef, {
      ...base, waId: `91${mob}`, phoneNumberId: AKZ_PNID, name: o.billName || `+91 ${mob}`, botEnabled: false,
      lastMessageText: (type === "text" ? text : (type === "image" ? "📷 Photo" : "📄 Bill")).slice(0, 200),
      lastMessageAt: now, lastMessageType: type, updatedAt: now,
      windowExpiresAt: Timestamp.fromMillis(Date.now() + 3650 * 86400e3),
      ...(inbound ? { unreadCount: FieldValue.increment(1), lastCustomerMsgAt: now } : {}),
    }, { merge: true });
  });
  return storagePath;
}

/** Staff reply typed in AKN Chat's "AKN App" tab → the customer's app chat. */
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
exports.aknChatOut = onDocumentCreated(
  { document: "chats/{chatId}/messages/{msgId}", region: "asia-south1", memory: "256MiB", maxInstances: 3, secrets: [APNS_KEY] },
  async (event) => {
    const { chatId, msgId } = event.params;
    if (!chatId.endsWith("_" + AKZ_PNID)) return;
    const d = event.data && event.data.data();
    // Staff drafts: direction "out" + senderStaffId (the app doesn't always set from).
    if (!d || d.direction !== "out" || d.aknzSource || d.from === "bot" || !(d.senderStaffId || d.from === "staff")) return;
    const db = admin.firestore();
    const mob = chatId.slice(0, chatId.indexOf("_")).slice(-10);
    const ords = await db.collection("bbapp_orders").where("mobile", "==", mob).get();
    const latest = ords.docs.map((x) => ({ id: x.id, ...x.data() }))
      .sort((a, b) => ((b.serial || 0) - (a.serial || 0)) ||
        ((b.statusAt && b.statusAt.toMillis ? b.statusAt.toMillis() : 0) - (a.statusAt && a.statusAt.toMillis ? a.statusAt.toMillis() : 0)))[0];
    let by = "";
    if (d.senderStaffId) {
      const st = (await db.collection("staff").doc(String(d.senderStaffId)).get()).data() || {};
      by = String(st.name || st.displayName || "").split(" ")[0];
    }
    const text = String(d.text || d.caption || "");
    await db.collection("bbapp_chat").add({ ref: latest ? latest.id : "", cust: mob, from: "shop", text,
      fileId: null, storagePath: d.mediaPath || null, mime: d.mediaPath ? (d.mediaMime || "image/jpeg") : null,
      by, at: Date.now(), aknChatMsg: msgId });
    await pushTo(db, mob, text || "📷 Sent you a photo");
    // Tick it (AKN Chat's sendMessage also marks it sent for the AKN App tab).
    await event.data.ref.set({ status: "sent", statusRank: 1, wamid: `aknzone_${msgId}` }, { merge: true });
    await db.collection("chats").doc(chatId).set({ unreadCount: 0, needsAttention: false,
      lastMessageText: (text || "📷 Photo").slice(0, 200), lastMessageAt: d.timestamp || admin.firestore.Timestamp.now(),
      lastMessageType: d.type || "text" }, { merge: true });
  },
);

exports.chatSend = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN, GEMINI_API_KEY, APNS_KEY], timeoutSeconds: 60, memory: "512MiB", maxInstances: 3, invoker: "public", cors: true },
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
    const payShot = img && (d.status || "received") === "bill_sent";
    if (!payShot) {
      // Owner 11-Oct: chats are answered in AKN Chat → "AKN App", not in the group.
      await addChat(db, ref, { from: "party", text, bytes: img, mime: img ? "image/jpeg" : null });
      return res.json({ ok: true, paid: false });
    }
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
      .map((m) => ({ id: m.id, from: m.from, text: m.text, at: m.at, by: m.by, file: !!(m.fileId || m.storagePath), mime: m.mime }));
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
    if (!m || m.cust !== cust || (!m.fileId && !m.storagePath)) return res.json({ ok: false });
    const bytes = m.fileId ? await tgFileBytes(m.fileId)
      : await admin.storage().bucket().file(m.storagePath).download().then((r) => r[0]).catch(() => null);
    if (!bytes) return res.json({ ok: false });
    return res.json({ ok: true, mime: m.mime || "image/jpeg", data: bytes.toString("base64") });
  },
);


/**
 * NewPartyBot (app_party_feed.py on the shop PC): new customers' orders, from
 * the moment they are placed → it makes the Tally ledger (broker YOUTUBE).
 * {ack:[refs]} marks them handed over.
 */
exports.newParties = onRequest(
  { region: "asia-south1", secrets: [PC_KEY], timeoutSeconds: 30, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !(pcOk(req) || req.get("x-app-key") === APP_KEY)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    for (const r of ((req.body && req.body.ack) || []).slice(0, 50)) {
      await db.collection("bbapp_orders").doc(String(r).replace(/[^A-Z0-9-]/gi, "")).set(
        { partyQueuedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
    }
    const snap = await db.collection("bbapp_orders")
      // Owner 11-Oct: the ledger is made as soon as the customer places the order.
      .where("status", "in", ["received", "getting_ready", "bill_sent", "payment_received", "dispatched", "bilty"]).get();
    const out = snap.docs.map((x) => ({ ref: x.id, ...x.data() }))
      .filter((o) => o.cust && !o.addOnTo && !o.partyQueuedAt)
      .sort((a, b) => (a.serial || 0) - (b.serial || 0)) // oldest first
      .map((o) => ({ ref: o.ref, serial: o.serial || null, cust: o.cust,
        advance: o.advanceAmt ? { paid: o.advanceAmt, utr: o.advanceUtr || null } : null }));
    return res.json({ ok: true, parties: out });
  },
);

/* ───────────── New customer: check BEFORE the order is sent (owner, 11-Oct-2026) ─────────────
 * Same checks NewPartyBot does before it makes the Tally ledger, so the
 * customer fixes things right there instead of the shop later:
 *   hard (must fix): mobile already a party → use OLD CUSTOMER; bill name
 *     already a ledger; GSTIN already with another party.
 *   soft (can keep): transport / booking place not in Tally's lists → nearest
 *     names offered to tap.
 * Data = newparty_check.json (PRIVATE, bundled; written by parties_sync.py).
 */
let NPCHECK = null;
const npNorm = (x) => String(x || "").toUpperCase().replace(/\s+/g, " ").trim();
function nearest(q, list, n = 5) {
  const Q = npNorm(q);
  const words = Q.split(" ").filter((w) => w.length >= 3);
  const score = (x) => {
    if (x === Q) return 100;
    let s = 0;
    if (x.startsWith(Q) || Q.startsWith(x)) s += 50;
    for (const w of words) if (x.includes(w)) s += 10 + w.length;
    // shared leading letters (spelling slips: AHEMDABAD / AHMEDABAD)
    let i = 0;
    while (i < x.length && i < Q.length && x[i] === Q[i]) i++;
    return s + i * 3;
  };
  return list.filter((x) => !/CLOSED|(^|\s)DELIVERY$|WITH OTHER PARTY/.test(x)).map((x) => [x, score(x)]).filter((e) => e[1] >= 12).sort((a, b) => b[1] - a[1]).slice(0, n).map((e) => e[0]);
}
exports.checkNewParty = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("n:" + ip)) return res.status(429).json({ ok: false });
    try {
      if (!NPCHECK) NPCHECK = require("./newparty_check.json");
      if (!PARTIES) PARTIES = require("./parties.json");
    } catch (e) {
      return res.json({ ok: true, errors: [], soft: [] }); // no data yet → don't block orders
    }
    const c = (req.body && req.body.cust) || {};
    const errors = [], soft = [];
    const mob = String(c.mobile || "").replace(/\D/g, "").slice(-10);
    const byMob = (mob && ((PARTIES[mob] || [])[0] || {}).name) || (mob && NPCHECK.mobiles[mob]);
    if (byMob) {
      errors.push({ field: "mobile", msg: `We already have an account with this mobile number: ${byMob}. ` +
        "Type this mobile number in the Mobile box — your account opens by itself." });
    }
    // Owner 11-Oct: a bill name already in Tally becomes "NAME (BOOKING PLACE)"
    // by itself (Tally can't have two ledgers with one name) — no error.
    const key = (x) => String(x || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    let rename = null;
    const base = String(c.billName || "").trim().toUpperCase();
    if (!byMob && base && NPCHECK.ledgers.includes(key(base))) {
      const place = String(c.bookingPlace || c.pincode || "").trim().toUpperCase();
      let cand = place ? `${base} (${place})` : base;
      for (let i = 2; NPCHECK.ledgers.includes(key(cand)) && i < 10; i++) cand = `${base} (${place}) ${i}`;
      rename = cand;
    }
    const gst = String(c.taxId || "").toUpperCase().replace(/\s/g, "");
    if (/^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$/.test(gst) && NPCHECK.gstins[gst] && !byMob) {
      errors.push({ field: "taxId", msg: `This GST number is already registered with us: ${NPCHECK.gstins[gst]}. ` +
        "Please order from that account (type its mobile number in the Mobile box), or remove the GST number." });
    }
    const tr = npNorm(c.transport);
    if (tr && (c.country || "India") === "India" && !NPCHECK.transports.includes(tr)) {
      soft.push({ field: "transport", msg: `Transport "${tr}" is not in our list. Please choose one:`,
        suggest: nearest(tr, NPCHECK.transports) });
    }
    const pl = npNorm(c.bookingPlace);
    if (pl && (c.country || "India") === "India" && !NPCHECK.dests.includes(pl)) {
      soft.push({ field: "bookingPlace", msg: `Booking place "${pl}" is not in our list. Please choose the nearest:`,
        suggest: nearest(pl, NPCHECK.dests) });
    }
    return res.json({ ok: true, errors, soft, rename });
  },
);

/* ───────────── PUSH to the customer's phone (owner, 11-Oct-2026) ─────────────
 * The app registers its FCM token with the customer mobiles it follows
 * (bbapp_push/{token}). Every shop → customer chat message (bill, payment
 * note, staff reply) rings those phones, even with the app closed.
 */
exports.registerPush = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const token = String((req.body && req.body.token) || "").slice(0, 400);
    const mobiles = ((req.body && req.body.mobiles) || []).map((m) => String(m).replace(/\D/g, "").slice(-10))
      .filter((m) => m.length === 10).slice(0, 3);
    if (token.length < 20 || !mobiles.length) return res.status(400).json({ ok: false });
    const apns = String((req.body && req.body.apns) || "").replace(/[^0-9a-f]/gi, "").slice(0, 200);
    // iPhone: keyed by the Apple address, so an FCM-token change never makes a
    // second record (= two pushes per message).
    const id = require("crypto").createHash("sha1").update(apns || token).digest("hex");
    await admin.firestore().collection("bbapp_push").doc(id).set({ token, mobiles, apns: apns || null,
      platform: String((req.body && req.body.platform) || "").slice(0, 10), at: Date.now() });
    return res.json({ ok: true });
  },
);

async function pushTo(db, mobile, body) {
  try {
    const snap = await db.collection("bbapp_push").where("mobiles", "array-contains", mobile).get();
    if (snap.empty) return;
    const text = String(body || "New message").slice(0, 180);
    const iosDocs = snap.docs.filter((d) => d.get("apns"));
    const sentApns = new Set();
    for (const d of iosDocs) {
      if (sentApns.has(d.get("apns"))) continue; // old duplicate record
      sentApns.add(d.get("apns"));
      const st = await apnsSend(d.get("apns"), text);
      if (st === 400 || st === 410) d.ref.set({ apns: null }, { merge: true }).catch(() => {});
    }
    const fcmDocs = snap.docs.filter((d) => !d.get("apns"));
    if (!fcmDocs.length) return;
    const tokens = fcmDocs.map((d) => d.get("token"));
    const r = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title: "AKN ZONE", body: String(body || "New message").slice(0, 180) },
      data: { route: "/chat" },
      apns: { payload: { aps: { sound: "default", badge: 1 } } },
      android: { priority: "high", notification: { sound: "default" } },
    });
    r.responses.forEach((x, i) => {
      const code = x.error && x.error.code;
      if (code === "messaging/registration-token-not-registered" || code === "messaging/invalid-registration-token") {
        fcmDocs[i].ref.delete().catch(() => {});
      }
    });
  } catch (e) {
    logger.warn("push failed", { mobile, error: e.message });
  }
}

/** iPhone push straight to Apple with the team's APNs key (JWT, HTTP/2). */
let _apnsJwt = null;
function apnsJwt() {
  if (_apnsJwt && Date.now() - _apnsJwt.at < 40 * 60e3) return _apnsJwt.t;
  const crypto = require("crypto");
  const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const h = b({ alg: "ES256", kid: "YS956XB4FC" });
  const p = b({ iss: "DWJM58G45V", iat: Math.floor(Date.now() / 1000) });
  const sig = crypto.sign("sha256", Buffer.from(h + "." + p),
    { key: APNS_KEY.value(), dsaEncoding: "ieee-p1363" }).toString("base64url");
  _apnsJwt = { t: `${h}.${p}.${sig}`, at: Date.now() };
  return _apnsJwt.t;
}
function apnsSend(deviceToken, text, host = "api.push.apple.com") {
  const http2 = require("http2");
  return new Promise((resolve) => {
    let done = false, c = null;
    const finish = (v) => {
      if (done) return;
      done = true;
      try { if (c) c.close(); } catch (e) { /* closed */ }
      resolve(v);
    };
    try {
      c = http2.connect("https://" + host);
      c.on("error", () => finish(0));
      const req = c.request({ ":method": "POST", ":path": "/3/device/" + deviceToken,
        authorization: "bearer " + apnsJwt(), "apns-topic": "com.bbsynthetics.catalog",
        "apns-push-type": "alert", "apns-priority": "10", "content-type": "application/json" });
      let status = 0, out = "";
      req.on("response", (hd) => { status = hd[":status"]; });
      req.on("data", (d) => { out += d; });
      req.on("end", () => {
        if (status !== 200) logger.warn("apns", { status, out: out.slice(0, 200), host });
        // a development (Xcode) build's token is only valid on the sandbox host
        if (status === 400 && /BadDeviceToken/.test(out) && host === "api.push.apple.com") {
          return apnsSend(deviceToken, text, "api.sandbox.push.apple.com").then(finish);
        }
        finish(status);
      });
      req.on("error", () => finish(0));
      req.setTimeout(10000, () => { req.close(); finish(0); });
      req.end(JSON.stringify({ aps: { alert: { title: "AKN ZONE", body: text }, sound: "default", badge: 1 },
        route: "/chat" }));
    } catch (e) {
      logger.warn("apns send", { error: e.message });
      finish(0);
    }
  });
}

/** App: saree counts the shop corrected with "count <design> <n>". */
exports.countOverrides = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const snap = await admin.firestore().collection("bbapp_counts").get();
    const out = {};
    snap.docs.forEach((d) => { out[d.id] = d.get("n"); });
    return res.json({ ok: true, counts: out });
  },
);

/** App errors (caught by the app's safety net) — for fixing without asking the customer. */
exports.appError = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("e:" + ip)) return res.status(429).json({ ok: false });
    const b = req.body || {};
    await admin.firestore().collection("bbapp_errors").add({
      error: String(b.error || "").slice(0, 1500), stack: String(b.stack || "").slice(0, 4000),
      platform: String(b.platform || "").slice(0, 20), os: String(b.os || "").slice(0, 120), at: Date.now() });
    return res.json({ ok: true });
  },
);

/* ───────────── GST lookup for the order form (owner, 12-Oct-2026) ─────────────
 * Same two providers as NewPartyBot (appyflow, then gstincheck). Returns the
 * registered name, address, PIN, city, state and status so the app can fill
 * the new-customer form and validate the number. Cached in bbapp_gst 30 days.
 */
const GST_APPYFLOW = defineSecret("BBAPP_GST_APPYFLOW");
const GST_CHECK = defineSecret("BBAPP_GST_CHECK");
function gstParse(t) {
  const adr = ((t || {}).pradr || {}).addr || {};
  const seen = new Set(), lines = [];
  for (const p of [adr.bno, adr.bnm, adr.flno, adr.st, adr.loc]) {
    const v = String(p || "").trim().replace(/\s+/g, " ").toUpperCase().replace(/^[ ,]+|[ ,]+$/g, "");
    if (!v || seen.has(v) || ["0", "00", "NA", "N/A", "-", ".", "NIL"].includes(v)) continue;
    seen.add(v); lines.push(v);
  }
  return {
    legalName: String(t.lgnm || "").trim().replace(/\s+/g, " ").toUpperCase(),
    tradeName: String(t.tradeNam || "").trim().replace(/\s+/g, " ").toUpperCase(),
    address: lines.slice(0, 4).join(", "),
    city: String(adr.dst || adr.city || "").trim().toUpperCase(),
    pin: String(adr.pncd || "").replace(/\D/g, ""),
    state: String(adr.stcd || "").trim(),
    status: String(t.sts || "").trim(),
    gstin: String(t.gstin || "").trim().toUpperCase(),
  };
}
exports.gstLookup = onRequest(
  { region: "asia-south1", secrets: [GST_APPYFLOW, GST_CHECK], timeoutSeconds: 45, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("g:" + ip)) return res.status(429).json({ ok: false });
    const g = String((req.body && req.body.gstin) || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (!/^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$/.test(g)) return res.json({ ok: true, found: false, reason: "format" });
    const db = admin.firestore();
    const c = await db.collection("bbapp_gst").doc(g).get();
    if (c.exists && Date.now() - (c.get("at") || 0) < 30 * 86400e3) return res.json({ ok: true, found: true, ...c.get("info") });
    let info = null, notFound = false;
    try {
      const k = GST_APPYFLOW.value().trim();
      if (k) {
        const j = await (await fetch(`https://appyflow.in/api/verifyGST?gstNo=${g}&key_secret=${encodeURIComponent(k)}`)).json();
        if (j && j.taxpayerInfo && String(j.taxpayerInfo.gstin || "").toUpperCase() === g) info = gstParse(j.taxpayerInfo);
        else if (j && !j.error) notFound = true;
      }
    } catch (e) { logger.warn("appyflow", { error: e.message }); }
    if (!info) {
      try {
        const k = GST_CHECK.value().trim();
        if (k) {
          const j = await (await fetch(`https://sheet.gstincheck.co.in/check/${encodeURIComponent(k)}/${g}`)).json();
          if (j && j.flag && j.data && String(j.data.gstin || "").toUpperCase() === g) info = gstParse(j.data);
          else if (/NOT.*FOUND/i.test(String((j && j.message) || ""))) notFound = true;
        }
      } catch (e) { logger.warn("gstincheck", { error: e.message }); }
    }
    if (info) {
      await db.collection("bbapp_gst").doc(g).set({ info, at: Date.now() });
      return res.json({ ok: true, found: true, ...info });
    }
    return res.json({ ok: true, found: false, reason: notFound ? "notfound" : "unavailable" });
  },
);

/** Shop PC (NewPartyBot): a ledger it just made → found by mobile at once. */
exports.registerParty = onRequest(
  { region: "asia-south1", secrets: [PC_KEY], timeoutSeconds: 20, memory: "256MiB", maxInstances: 2, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !(pcOk(req) || req.get("x-app-key") === APP_KEY)) return res.status(403).json({ ok: false });
    const b = req.body || {};
    const rec = { name: String(b.name || "").slice(0, 120), address: String(b.address || "").slice(0, 300),
      dest: String(b.dest || "").slice(0, 60), pincode: String(b.pincode || "").slice(0, 10),
      state: String(b.state || "").slice(0, 40), country: String(b.country || "India").slice(0, 40),
      gstin: String(b.gstin || "").slice(0, 20), transport: String(b.transport || "").slice(0, 80) };
    if (!rec.name) return res.status(400).json({ ok: false });
    const mobs = (b.mobiles || []).map((m) => String(m).replace(/\D/g, "").slice(-10)).filter((m) => /^[6-9]\d{9}$/.test(m));
    const db = admin.firestore();
    for (const m of mobs.slice(0, 3)) {
      const ref = db.collection("bbapp_parties_live").doc(m);
      const cur = (await ref.get()).data() || {};
      const list = (cur.list || []).filter((x) => x.name !== rec.name);
      await ref.set({ list: [rec, ...list].slice(0, 5), at: Date.now() });
    }
    return res.json({ ok: true, mobiles: mobs.length });
  },
);

/** Shop PC (parties_sync): drop live entries whose ledger no longer exists in Tally. */
exports.pruneLiveParties = onRequest(
  { region: "asia-south1", secrets: [PC_KEY], timeoutSeconds: 60, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    const snap = await db.collection("bbapp_parties_live").get();
    if (req.body && req.body.list) {
      const names = new Set();
      snap.docs.forEach((d) => (d.get("list") || []).forEach((x) => names.add(x.name)));
      return res.json({ ok: true, names: [...names] });
    }
    const keep = new Set(((req.body && req.body.keep) || []).map((x) => String(x).toUpperCase().replace(/[^A-Z0-9]/g, "")));
    if (keep.size < 500) return res.status(400).json({ ok: false, error: "keep list too small" });
    let dropped = 0;
    for (const d of snap.docs) {
      const list = (d.get("list") || []).filter((x) => keep.has(String(x.name || "").toUpperCase().replace(/[^A-Z0-9]/g, "")));
      if (list.length !== (d.get("list") || []).length) {
        dropped++;
        if (list.length) await d.ref.set({ list }, { merge: true }); else await d.ref.delete();
      }
    }
    return res.json({ ok: true, dropped });
  },
);


/* ───────────── NEW CUSTOMER 10% ADVANCE (owner, 12-Oct-2026) ─────────────
 * A new customer's order is held on the phone until a 10% advance is paid to
 * B.B SYNTHETICS (UPI QR / bank). The payment screenshot is read here:
 * payee must be B.B SYNTHETICS (name / UPI vyapar.173947529358@hdfcbank /
 * A/c 270320110001776), amount >= the advance, successful, made after the
 * order, UTR never used before. Only then does the app send the order to the
 * group. Unpaid after 24 h → a reminder in the Party order group.
 */
const ORDER_GROUP = -5370195204;
const ADV_PROMPT = "This should be a payment screenshot (UPI app like GPay/PhonePe/Paytm/BHIM, or a bank app NEFT/RTGS/IMPS). " +
  "Return JSON: amount (number, rupees paid), date (YYYY-MM-DD of the payment as shown), time (HH:MM 24-hour as shown), " +
  "txnId (UPI ref no. / UTR / transaction id, digits and letters only), success (true only if it clearly says successful/completed/paid), " +
  "payee (the RECEIVER's name exactly as shown), payeeAccount (receiver's UPI id or account number, as shown). Use null when not shown. " +
  "If it is not a payment screenshot, amount = null.";
const ADV_SCHEMA = { type: "object", properties: {
  amount: { type: ["number", "null"] }, date: { type: ["string", "null"] }, time: { type: ["string", "null"] },
  txnId: { type: ["string", "null"] }, success: { type: ["boolean", "null"] }, payee: { type: ["string", "null"] },
  payeeAccount: { type: ["string", "null"] } }, required: ["amount"] };

exports.advanceStart = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const b = req.body || {};
    const ref = String(b.ref || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const due = Math.round(Number(b.due) || 0);
    if (!ref || due <= 0) return res.status(400).json({ ok: false });
    const docRef = admin.firestore().collection("bbapp_advances").doc(ref);
    const cur = (await docRef.get()).data();
    if (cur && cur.state === "paid") return res.json({ ok: true, state: "paid", paid: cur.paid, utr: cur.utr });
    // Tester 13-Oct: a phone clock hours ahead made every screenshot "before
    // the order" — never later than the server's now. An order placed offline
    // keeps its own (earlier) time, so a payment made meanwhile still counts.
    const now = Date.now();
    const orderAt = Math.max(Math.min(Number(b.orderAt) || now, now), now - 7 * 86400e3);
    await docRef.set({ ref, due, billName: String(b.billName || "").slice(0, 120), mobile: String(b.mobile || "").slice(0, 20),
      total: Math.round(Number(b.total) || 0),
      state: "pending", ...(cur ? {} : { at: now, orderAt }) }, { merge: true });
    return res.json({ ok: true, state: "pending" });
  },
);

exports.advanceProof = onRequest(
  { region: "asia-south1", secrets: [GEMINI_API_KEY], timeoutSeconds: 120, memory: "512MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || req.get("x-app-key") !== APP_KEY) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("a:" + ip)) return res.status(429).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const img = Buffer.from(String((req.body && req.body.image) || ""), "base64");
    if (!ref || !img.length || img.length > 6 * 1024 * 1024) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    const docRef = db.collection("bbapp_advances").doc(ref);
    const a = (await docRef.get()).data();
    if (!a) return res.json({ ok: false, error: "Please go back and press PLACE ORDER again." });
    if (a.state === "paid") return res.json({ ok: true, paid: a.paid, utr: a.utr });
    const fail = (msg) => res.json({ ok: false, error: msg });
    // Tester 13-Oct: the SAME screenshot sent twice (no UTR readable) was
    // counted twice — every image is remembered by its hash.
    const hash = require("crypto").createHash("sha1").update(img).digest("hex");
    const have = (a.parts || []).reduce((t, x) => t + (x.amt || 0), 0);
    if ((a.hashes || []).includes(hash)) {
      return fail(`This screenshot is already received (${inr(have)} of the ${inr(a.due)} advance). Please pay ${inr(Math.max(0, a.due - have))} more and send that screenshot.`);
    }
    const usedImg = await db.collection("bbapp_advances").where("hashes", "array-contains", hash).get();
    if (usedImg.docs.some((x) => x.id !== ref)) return fail("This payment screenshot was already used for another order.");
    const p = await geminiJson(img, "image/jpeg", ADV_PROMPT, ADV_SCHEMA);
    if (!p) return fail("Could not read the screenshot right now — please try again in a minute.");
    if (!p.amount || p.amount <= 0) return fail("This does not look like a payment screenshot. Please send the screenshot of your payment.");
    if (p.success === false) return fail("This payment does not show as successful. Please send the screenshot of a successful payment.");
    // Only OUR name / UPI id / account — "XYZ SYNTHETICS" must not pass.
    const who = `${p.payee || ""} ${p.payeeAccount || ""}`.toUpperCase().replace(/[^A-Z0-9]/g, "");
    const ours = who.includes("BBSYNTHETIC") || who.includes("173947529358") || who.includes("270320110001776");
    if (!ours) return fail(`This payment went to "${p.payee || p.payeeAccount || "someone else"}". The advance must be paid to B.B SYNTHETICS only.`);
    const tm = /^\d{1,2}:\d{2}$/.test(String(p.time || "")) ? String(p.time).padStart(5, "0") : null;
    const dt = /^\d{4}-\d{2}-\d{2}$/.test(String(p.date || "")) ? p.date
      : (tm ? new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10) : null);
    const paidAt = dt ? Date.parse(`${dt}T${tm || "23:59"}:00+05:30`) : NaN;
    if (!isNaN(paidAt) && paidAt < Math.floor((a.orderAt || 0) / 60000) * 60000 - 10 * 60e3) {
      return fail("This screenshot is from before your order. Please send the screenshot of the payment you made now.");
    }
    const utr = String(p.txnId || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (utr) {
      const used = await db.collection("bbapp_advances").where("utrs", "array-contains", utr).get();
      const used2 = await db.collection("bbapp_advances").where("utr", "==", utr).get();
      if ([...used.docs, ...used2.docs].some((x) => x.id !== ref)) return fail("This payment screenshot was already used for another order.");
    }
    // Test 12-Oct: part-payments add up (₹5,000 now + ₹4,770 later). The
    // same payment again (same UTR, or no UTR but same amount + time) is one.
    const amt = Math.round(p.amount);
    const at = isNaN(paidAt) ? null : paidAt;
    const parts = (a.parts || []).filter((x) => !(utr ? x.utr === utr : (!x.utr && x.amt === amt && at && x.paidAt === at)));
    parts.push({ amt, utr: utr || null, paidAt: at, hash });
    const sum = parts.reduce((t, x) => t + x.amt, 0);
    const path = `advances/${ref}${parts.length > 1 ? "-" + parts.length : ""}.jpg`;
    await admin.storage().bucket().file(path).save(img, { contentType: "image/jpeg" });
    const utrs = parts.map((x) => x.utr).filter(Boolean);
    const hashes = admin.firestore.FieldValue.arrayUnion(hash);
    if (sum + 1 < a.due) {
      await docRef.set({ parts, utrs, hashes, utr: utrs[0] || null, path }, { merge: true });
      return fail(`Received ${inr(sum)} of the ${inr(a.due)} advance. Please pay ${inr(a.due - sum)} more and send that screenshot too.`);
    }
    await docRef.set({ state: "paid", parts, utrs, hashes, paid: sum, utr: utrs.join(", ") || null, payee: p.payee || null,
      paidAt: isNaN(paidAt) ? null : paidAt, path, verifiedAt: Date.now() }, { merge: true });
    return res.json({ ok: true, paid: sum, utr: utrs.join(", ") || null });
  },
);

exports.advanceReminder = onSchedule(
  { region: "asia-south1", schedule: "every 60 minutes", secrets: [TG_TOKEN], timeoutSeconds: 120, memory: "256MiB" },
  async () => {
    const db = admin.firestore();
    const snap = await db.collection("bbapp_advances").where("state", "==", "pending").get();
    for (const d of snap.docs) {
      const a = d.data();
      if (a.reminded || Date.now() - (a.at || 0) < 24 * 3600e3) continue;
      await tg("sendMessage", { chat_id: ORDER_GROUP,
        text: `⏳ NEW CUSTOMER has not paid the 10% advance yet\n${a.billName || "-"} · ${a.mobile || "-"}\nOrder approx ${inr(a.total)} · advance ${inr(a.due)}\nPlease call them.` });
      await d.ref.set({ reminded: Date.now() }, { merge: true });
    }
  },
);

/** Shop PC (NewPartyBot): a new customer's advance screenshot. */
exports.advanceImage = onRequest(
  { region: "asia-south1", secrets: [PC_KEY], timeoutSeconds: 30, memory: "256MiB", maxInstances: 2, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !(pcOk(req) || req.get("x-app-key") === APP_KEY)) return res.status(403).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const a = ref ? (await admin.firestore().collection("bbapp_advances").doc(ref).get()).data() : null;
    if (!a || a.state !== "paid" || !a.path) return res.json({ ok: false });
    const [bytes] = await admin.storage().bucket().file(a.path).download();
    return res.json({ ok: true, paid: a.paid, utr: a.utr || null, data: bytes.toString("base64") });
  },
);

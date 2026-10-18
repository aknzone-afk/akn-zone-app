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
// 3.0.0 (owner 13-Oct): the new app sends its own key. On store-release day
// set OLD_KEY_OK = false → every older app stops (orders, chat, lookups) and
// must update.
const APP_KEY_V3 = "akn-zone-app-v3";
const OLD_KEY_OK = true;
const appOk = (req) => req.get("x-app-key") === APP_KEY_V3 || (OLD_KEY_OK && req.get("x-app-key") === APP_KEY);
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
function limited(ip, max = PER_IP_PER_HOUR) {
  const now = Date.now();
  const arr = (hits.get(ip) || []).filter((t) => now - t < 3600e3);
  arr.push(now);
  hits.set(ip, arr);
  if (hits.size > 5000) hits.clear();
  return arr.length > max;
}

/**
 * Tester 13-Oct: ONE customer key everywhere (orders, chat, push, AKN Chat):
 * an Indian number = its last 10 digits (+91 / 0 prefixes dropped); a foreign
 * number (7-15 digits) = all its digits. Before, foreign numbers were cut to a
 * fake "+91" tail and 7-9 digit numbers had no chat at all.
 */
function custKey(raw) {
  const d = String(raw || "").replace(/\D/g, "");
  if (d.length > 10 && /^(0|91)+$/.test(d.slice(0, -10))) return d.slice(-10);
  return d.length >= 7 && d.length <= 15 ? d : "";
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
    if (!appOk(req)) return res.status(403).json({ ok: false, error: "forbidden" });
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
  "A STITCHED BLOUSE (ready-made blouse with sleeves / neck, or a folded blouse piece) shown with a saree is part of that saree — " +
  "NEVER give it its own box, point or count, even when it lies separately below or beside the saree (owner, 13-Oct). " +
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
    if (!appOk(req)) return res.status(403).json({ ok: false });
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
    if (d === DEMO_KEY) return res.json({ ok: true, parties: [DEMO_PARTY] });
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
    if (!appOk(req)) return res.status(403).json({ ok: false });
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
//   🧺 Maal nikalna chalu  →  🧾 Bill  →  💰 Payment  →  🚚 Dispatched  →  📄 Bilty
// A done step stays as "✔ <step> — by <name>" (name = the tapper's Telegram
// name); tapping the LATEST done step again undoes it.
// Tester 13-Oct: an automatic step can be undone by a human too (a wrongly
// matched bill locked the order) — `clear` = the data that step brought.
const STEPS = [
  { k: "g", status: "getting_ready", label: "🧺 Maal nikalna chalu", by: "readyBy", at: "readyAt" },
  { k: "b", status: "bill_sent", label: "🧾 Bill sent for payment", by: "billBy", at: "billAt", auto: true,
    wait: "⏳ Waiting for bill (post it in the Bill group)",
    clear: ["billFileId", "billMime", "billNo", "billTotal", "billSentAt", "billGroup"] },
  // Owner 18-Oct: payment ticks from Tally (bill settled) — no hand button.
  { k: "y", status: "payment_received", label: "💰 Payment received", by: "paidBy", at: "paidAt", auto: true,
    wait: "⏳ Payment ticks when the bill is settled in Tally" },
  { k: "d", status: "dispatched", label: "🚚 Dispatched", by: "dispatchedBy", at: "dispatchedAt", auto: true,
    wait: "⏳ Dispatched ticks when the parcel date is in Daily Parcels", clear: ["parcelDate"] },
  { k: "l", status: "bilty", label: "📄 Bilty", by: "biltyBy", at: "biltyAt", auto: true,
    wait: "⏳ Bilty ticks when the bilty no. is entered", clear: ["lr", "bilty"] },
];
const ORDER = ["received", ...STEPS.map((x) => x.status)];
const STATUSES = Object.fromEntries(STEPS.map((x) => [x.k, x.status]));

// Owner 17-Oct: hold / party-does-not-want lines in the STATUS section.
const FLAG_LINES = {
  hold: "⏸ Kept on hold",
  resume: "▶️ Hold removed",
  cancel: "🚫 Party does not want the goods",
  uncancel: "↩️ Order back on (party wants the goods)",
};

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
    if (FLAG_LINES[e.a]) return `${FLAG_LINES[e.a]} — by ${escH(e.by)} · ${hhmm(e.at)}`;
    const st = STEPS.find((x) => x.k === e.k);
    const name = st ? st.label : e.k;
    return e.a === "undo"
      ? `↩️ Undone ${escH(name)} — by ${escH(e.by)} · ${hhmm(e.at)}`
      : (e.k === "d" || e.k === "l") ? `✔ ${escH(name)} — ${escH(e.by)}`   // owner 18-Oct: date / bilty no. only
      : `✔ ${escH(name)} — by ${escH(e.by)} · ${hhmm(e.at)}`;
  });
  // Owner 18-Oct: the party closing balance in Tally (from the payment check).
  if (d && d.payBal != null && d.payChk) lines.push(`💼 Closing balance: ${inr(d.payBal)} · ${hhmm(d.payChk)}`);
  const tail = `\n\n<b>STATUS</b>\n${lines.join("\n")}`;
  // Telegram edits fail above 4096 chars — trim the details, keep the status.
  return (base.length + tail.length > 4000 ? cutAt(base, 4000 - tail.length) : base) + tail;
}

/**
 * Buttons (owner 11-Oct-2026): a done step's button shows just WHO + WHEN,
 * e.g. "🧺 ✅ Akshay 11:10" (tap again = undo, only by that person). After an
 * undo: a plain line "↩️ Undone Akshay 11:20" and the step's button again.
 * Automatic steps show a ⏳ waiting line.
 * Tester 13-Oct: the intent is in the data — "s|" = DO (pending step),
 * "u|" = UNDO (done step) — so a double tap can never flip a step back.
 */
const firstName = (x) => String(x || "").trim().split(/\s+/)[0] || "?";
function statusKeyboard(ref, d) {
  const cur = (d && d.status) || "received";
  const ci = ORDER.indexOf(cur);
  const log = (d && d.log) || [];
  const rows = [];
  // Owner 16-Oct: every finished step stays on the message (who + when).
  // Only the LATEST hand-tapped step can be undone; automatic steps (bill,
  // dispatch, bilty) are facts — tapping them does nothing.
  for (const st of STEPS) {
    const si = ORDER.indexOf(st.status);
    if (si > ci) break;
    const done = [...log].reverse().find((e) => e.a === "do" && e.k === st.k);
    const icon = String(st.label).split(" ")[0];
    const who = done ? ((st.k === "d" || st.k === "l") ? String(done.by) : `${firstName(done.by)} ${hhmm(done.at)}`) : "";
    const undoable = si === ci && !st.auto;
    rows.push([{ text: `${icon} ✅ ${who}`.trim().slice(0, 60), callback_data: undoable ? `u|${st.k}|${ref}`.slice(0, 64) : "n" }]);
  }
  // Owner 17-Oct: party does not want the goods -> only that line (tap = undo).
  if (d && d.cancelled) {
    return { inline_keyboard: [[{ text: `🚫 Party does not want — ${firstName(d.cancelledBy)} ${hhmm(d.cancelledAt || 0)}`.slice(0, 60),
      callback_data: `x|x|${ref}`.slice(0, 64) }]] };
  }
  const before = ci < ORDER.indexOf("dispatched");
  if (d && d.hold) {
    rows.push([{ text: `⏸ ON HOLD — ${firstName(d.holdBy)} ${hhmm(d.holdAt || 0)} · tap to resume`.slice(0, 60), callback_data: `h|x|${ref}`.slice(0, 64) }]);
    if (before) rows.push([{ text: "🚫 Party does not want the goods", callback_data: `x|x|${ref}`.slice(0, 64) }]);
    return { inline_keyboard: rows };
  }
  const next = STEPS.find((x) => ORDER.indexOf(x.status) === ci + 1);
  const extra = before ? [[{ text: "⏸ Keep on hold", callback_data: `h|x|${ref}`.slice(0, 64) }],
    [{ text: "🚫 Party does not want the goods", callback_data: `x|x|${ref}`.slice(0, 64) }]] : [];
  if (next && next.auto) {
    const wait = next.k === "y" && d && d.payBal != null ? `⏳ Payment · closing balance ${inr(d.payBal)}` : (next.wait || "⏳ Waiting");
    rows.push([{ text: wait, callback_data: "n" }]);
  } else if (next) {
    rows.push([{ text: next.label, callback_data: `s|${next.k}|${ref}`.slice(0, 64) }]);
  }
  rows.push(...extra);
  return { inline_keyboard: rows };
}

/** Owner 17-Oct: ⏸ hold (toggle) and 🚫 party does not want the goods
 *  (undo only by the same person). Both written to the STATUS log. */
async function holdCancelTap(db, q, tag, ref) {
  const docRef = db.collection("bbapp_orders").doc(ref);
  const name = [q.from && q.from.first_name, q.from && q.from.last_name].filter(Boolean).join(" ")
    || (q.from && q.from.username) || "staff";
  const uid = (q.from && q.from.id) || 0;
  const del = admin.firestore.FieldValue.delete();
  const verdict = await db.runTransaction(async (tx) => {
    const s0 = await tx.get(docRef);
    if (!s0.exists) return { ok: false, msg: "Order not found." };
    const d = s0.data();
    const at = Date.now();
    if (tag === "h") {
      if (d.cancelled) return { ok: false, msg: "Party does not want this order." };
      const on = !d.hold;
      tx.set(docRef, on ? { hold: true, holdBy: name, holdAt: at } : { hold: del, holdBy: del, holdAt: del,
        log: admin.firestore.FieldValue.arrayUnion({ a: "resume", by: name, at, uid }) }, { merge: true });
      if (on) tx.set(docRef, { log: admin.firestore.FieldValue.arrayUnion({ a: "hold", by: name, at, uid }) }, { merge: true });
      return { ok: true, msg: on ? "⏸ Order kept on hold" : "▶️ Hold removed" };
    }
    if (!d.cancelled) {
      tx.set(docRef, { cancelled: true, cancelledBy: name, cancelledAt: at, cancelledUid: uid, hold: del, holdBy: del, holdAt: del,
        log: admin.firestore.FieldValue.arrayUnion({ a: "cancel", by: name, at, uid }) }, { merge: true });
      return { ok: true, msg: "🚫 Marked: party does not want the goods" };
    }
    if (d.cancelledUid && d.cancelledUid !== uid) return { ok: false, msg: `Only ${d.cancelledBy} can undo this.` };
    tx.set(docRef, { cancelled: del, cancelledBy: del, cancelledAt: del, cancelledUid: del,
      log: admin.firestore.FieldValue.arrayUnion({ a: "uncancel", by: name, at, uid }) }, { merge: true });
    return { ok: true, msg: "↩️ Order back on" };
  });
  await tg("answerCallbackQuery", { callback_query_id: q.id, text: verdict.msg, show_alert: !verdict.ok });
  if (verdict.ok && q.message) {
    const fresh = (await docRef.get()).data() || {};
    await tg("editMessageText", { chat_id: q.message.chat.id, message_id: q.message.message_id,
      text: statusText(fresh, q.message.text), parse_mode: "HTML", disable_web_page_preview: true,
      reply_markup: statusKeyboard(ref, fresh) });
  }
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
      // Owner 13-Oct: the "Akn zone - auto receipts bot" group gets every
      // verified token screenshot + ledger name (old HDFC group untouched).
      const gc = u.message && u.message.chat;
      // Every group the bot is in is remembered by title (owner 14-Oct: a new
      // "approvals" group is picked up the moment someone writes in it).
      if (gc && gc.title) {
        const seen = (await db.collection("bbapp_chats").doc(String(gc.id)).get()).data();
        if (!seen || seen.title !== gc.title) {
          await db.collection("bbapp_chats").doc(String(gc.id)).set({ title: gc.title, at: Date.now() });
        }
      }
      if (gc && (/approv/i.test(String(gc.title || "")) || /^\s*akn\s*zone\s*app\s*$/i.test(String(gc.title || "")))) {
        const cur = (await db.collection("bbapp_settings").doc("approvals").get()).data();
        if (!cur || String(cur.chat) !== String(gc.id)) {
          await db.collection("bbapp_settings").doc("approvals").set({ chat: gc.id, title: gc.title, at: Date.now() });
          await tg("sendMessage", { chat_id: gc.id, text: "✅ Connected — new customer sign-ups (Approve / Decline), logins and /block will come here." });
        }
      }
      if (gc && /auto\s*receipt/i.test(String(gc.title || ""))) {
        const cur = (await db.collection("bbapp_settings").doc("receipts").get()).data();
        if (!cur || String(cur.chat) !== String(gc.id)) {
          await db.collection("bbapp_settings").doc("receipts").set({ chat: gc.id, title: gc.title, at: Date.now() });
          await tg("sendMessage", { chat_id: gc.id, text: "✅ Connected — every verified AKN Zone app token screenshot will come here with the party's ledger name." });
        }
      }
      if (u.callback_query) {
        const q = u.callback_query;
        if (q.data === "n") {
          await tg("answerCallbackQuery", { callback_query_id: q.id });
          return res.status(200).send("ok");
        }
        const [tag, k, ref] = String(q.data || "").split("|");
        const step = STEPS.find((x) => x.k === k);
        if (tag === "a" && ref) {
          await accountTap(db, q, k, ref);
          return res.status(200).send("ok");
        }
        if (tag === "sb" && ref) {
          await sheetBlockTap(db, q, k, ref);
          return res.status(200).send("ok");
        }
        if (tag === "m" && ref) {
          await moneyReceivedTap(db, q, ref);
          return res.status(200).send("ok");
        }
        if ((tag === "h" || tag === "x") && ref) {
          await holdCancelTap(db, q, tag, ref);
          return res.status(200).send("ok");
        }
        // Tester 13-Oct: "s" = DO, "u" = UNDO. Buttons already in the group
        // carry "s" on the done step too — that tap is now "Already done" (no
        // write) and the buttons are redrawn, so the next tap is a real undo.
        if ((tag === "s" || tag === "u") && step && ref) {
          const docRef = db.collection("bbapp_orders").doc(ref);
          const name = [q.from && q.from.first_name, q.from && q.from.last_name].filter(Boolean).join(" ")
            || (q.from && q.from.username) || "staff";
          const verdict = await db.runTransaction(async (tx) => {
            const d = await tx.get(docRef);
            const cur = (d.exists && d.get("status")) || "received";
            const ci = ORDER.indexOf(cur), ni = ORDER.indexOf(step.status);
            const del = admin.firestore.FieldValue.delete();
            if (tag === "u") {
              if (ni > ci) return { ok: false, msg: "Nothing to undo.", redraw: true };
              // Owner 16-Oct: a sent bill (and other automatic steps) stays.
              if (step.auto) return { ok: false, msg: "Already done — this cannot be undone.", redraw: true };
              if (ni < ci) return { ok: false, msg: "Undo the later step first." };
              // Undo the latest step — only by the person who tapped it
              // (an automatic step, uid 0, by anyone).
              const lg = d.get("log") || [];
              const lastDo = [...lg].reverse().find((e) => e.a === "do" && e.k === step.k);
              if (lastDo && lastDo.uid && q.from && lastDo.uid !== q.from.id) {
                return { ok: false, msg: `Only ${lastDo.by} can undo this.` };
              }
              const upd = { status: ORDER[ci - 1], [step.by]: del, [step.at]: del,
                statusAt: admin.firestore.FieldValue.serverTimestamp(),
                log: admin.firestore.FieldValue.arrayUnion({ a: "undo", k: step.k, by: name, at: Date.now(), uid: (q.from && q.from.id) || 0 }) };
              // Tester 13-Oct: a wrong bill / parcel date / bilty is removed
              // with its step, so the right one can be sent again.
              for (const f of step.clear || []) upd[f] = del;
              // Tester 13-Oct: an auto-ticked payment undone = the screenshot
              // that ticked it was bad — it no longer counts (else the next
              // screenshot ticks it again on the old total).
              if (step.k === "y" && lastDo && !lastDo.uid) {
                const pays = (d.get("payments") || []).map((x) => ({ ...x }));
                let i = pays.length - 1;
                while (i >= 0 && (pays[i].kind === "advance" || pays[i].voided)) i--;
                if (i >= 0) {
                  pays[i].voided = true;
                  pays[i].voidedBy = name;
                  upd.payments = pays;
                  upd.paidTotal = pays.filter((x) => !x.voided).reduce((t, x) => t + (Number(x.amt) || 0), 0);
                }
              }
              tx.set(docRef, upd, { merge: true });
              return { ok: true, msg: `Undone: ${step.label}` };
            }
            if (ni <= ci) return { ok: false, msg: "Already done.", redraw: true };
            if (d.get("cancelled")) return { ok: false, msg: "Party does not want this order." };
            if (d.get("hold")) return { ok: false, msg: "⏸ Order is on hold — resume it first." };
            if (step.auto) return { ok: false, msg: "This step ticks by itself." };
            if (ni !== ci + 1) return { ok: false, msg: "Not yet — do the steps in order." };
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
          } else if (verdict.redraw && q.message) {
            // Old-style or stale buttons → today's buttons (only if they differ;
            // Telegram refuses an edit that changes nothing).
            const kb = statusKeyboard(ref, (await docRef.get()).data() || {});
            if (JSON.stringify(kb) !== JSON.stringify(q.message.reply_markup || {})) {
              await tg("editMessageReplyMarkup", { chat_id: q.message.chat.id, message_id: q.message.message_id, reply_markup: kb });
            }
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
      } else if (u.message && /^\/verify(\s|$)/i.test(String(u.message.text || ""))) {
        // Owner 14-Oct: customer without WhatsApp calls the shop and tells the
        // code on the app screen. Staff call that number back, then send
        // "/verify 123456 98xxxxxxxx" — ONLY in the "Akn zone app" group.
        const chat = await approvalsChat(db);
        const by = (u.message.from && u.message.from.first_name) || "staff";
        const parts = String(u.message.text).replace(/^\/\w+/, "").trim().split(/\s+/);
        const code = String(parts[0] || "").replace(/\D/g, "");
        const key = accKey(parts.slice(1).join(""));
        let txt = "Send: /verify 123456 98xxxxxxxx  (the code on the customer's screen, then their number — call them back first)";
        if (!chat || String(u.message.chat.id) !== String(chat)) {
          txt = "/verify works only in the Akn zone app group.";
        } else if (code.length === 6 && key) {
          await db.collection("bbapp_verify").doc(code).set({ from: key.length === 10 ? "91" + key : key, at: Date.now(), manual: true, by });
          txt = `✅ Code ${code} → ${key} — the app on their phone / iPad opens in a few seconds (code works 20 min).`;
        }
        await tg("sendMessage", { chat_id: u.message.chat.id, reply_to_message_id: u.message.message_id, text: txt });
      } else if (u.message && /^\/(un)?block(\s|$)/i.test(String(u.message.text || ""))) {
        // Owner 14-Oct: "/block 98xxxxxxxx" — that number loses the app.
        const un = /^\/unblock/i.test(u.message.text);
        const key = accKey(String(u.message.text).replace(/^\/\w+/, ""));
        const by = (u.message.from && u.message.from.first_name) || "staff";
        let txt = `Send: /${un ? "unblock" : "block"} 98xxxxxxxx`;
        if (key) {
          await db.collection("bbapp_accounts").doc(key).set({ status: un ? "approved" : "blocked",
            log: admin.firestore.FieldValue.arrayUnion({ a: un ? "unblock" : "block", by, at: Date.now() }) }, { merge: true });
          txt = un ? `✅ ${key} unblocked — the app opens again.` : `🚫 ${key} blocked — the app is closed for this number.`;
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const chat = String((req.body && req.body.chat) || "").replace(/[^0-9-]/g, "");
    const msg = Number(req.body && req.body.msg) || 0;
    const text = cutAt((req.body && req.body.text) || "", 3500);
    const mobile = custKey(req.body && req.body.mobile);
    const billName = String((req.body && req.body.billName) || "").slice(0, 120);
    const serial = Number(req.body && req.body.serial) || null;
    const addOnTo = String((req.body && req.body.addOnTo) || "").slice(0, 40) || null;
    if (!ref || !chat || !msg) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    if (await isBlocked(db, mobile)) return res.status(403).json({ ok: false, error: "blocked" });
    // Owner 14-Oct: last order + order count on the account (Google Sheet).
    if (accKey(mobile) && !(await db.collection("bbapp_orders").doc(ref).get()).get("msg")) {
      await db.collection("bbapp_accounts").doc(accKey(mobile)).set({ lastOrderAt: Date.now(),
        orders: admin.firestore.FieldValue.increment(1) }, { merge: true });
    }
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
    // Owner 12-Oct: a new customer's verified 10% advance is the order's
    // first payment (the bill balance asks only for the rest) + its
    // screenshot goes under the order in the group. Review 13-Oct: written
    // in the SAME set as the status, so NewPartyBot never sees the order
    // without its token.
    const adv = (await db.collection("bbapp_advances").doc(ref).get()).data();
    const newAdv = !!(adv && adv.state === "paid" && !(d.exists && d.get("advanceAmt")));
    let tokenFields = {};
    if (newAdv) {
      // One payment per screenshot (a part-paid advance has 2 UTRs): the
      // same screenshot sent again later as a "bill payment" is then a dup.
      const parts = (adv.parts && adv.parts.length) ? adv.parts
        : [{ amt: Number(adv.paid), utr: adv.utr || null, paidAt: adv.paidAt || null }];
      const payments = parts.map((x) => ({ amt: Number(x.amt) || 0, txn: x.utr || "", paidAt: x.paidAt || null, at: Date.now(), kind: "advance" }));
      tokenFields = { advanceAmt: adv.paid, advanceUtr: adv.utr || null, payments,
        paidTotal: payments.reduce((t, x) => t + x.amt, 0), tokenDue: tokenDeadline(adv.paidAt || adv.verifiedAt || Date.now()),
        tokenMethod: adv.method || "upi" };
    }
    await docRef.set({ msg, chat, mobile, billName, serial, addOnTo, ...(text ? { text } : {}), ...(cust ? { cust } : {}), ...tokenFields,
      ...(d.exists && d.get("status") ? {} : { status: "received", statusAt: admin.firestore.FieldValue.serverTimestamp() }) }, { merge: true });
    // Owner 17-Oct: the app posts only "Maal nikalna chalu" — the cloud adds
    // ⏸ Keep on hold + 🚫 Party does not want the goods at once.
    if (!(d.exists && d.get("status")) && msg && chat) {
      await tg("editMessageReplyMarkup", { chat_id: chat, message_id: msg,
        reply_markup: statusKeyboard(ref, (await docRef.get()).data() || {}) }).catch(() => {});
    }
    if (newAdv) {
      // Owner 12-Oct: the advance screenshot is the FIRST message of the
      // customer's chat (and goes to the new-party group with the ledger).
      try {
        const [bytes] = await admin.storage().bucket().file(adv.path).download();
        await addChat(db, ref, { from: "party", text: `💰 Token ${inr(adv.paid)} paid (10%)${adv.utr ? " · UTR " + adv.utr : ""}`,
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
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
          mobile: custKey(i.mobile),
          billName: String(i.billName || "").slice(0, 120),
          serial: Number(i.serial) || null,
          addOnTo: String(i.addOnTo || "").slice(0, 40) || null,
        }, { merge: true });
      }
    }
    const out = {};
    for (const s of snaps) {
      if (s.exists) out[s.id] = { status: s.get("status") || null, lr: s.get("lr") || null,
        bill: !!s.get("billFileId"), billNo: s.get("billNo") || null, billTotal: s.get("billTotal") || null,
        adv: s.get("advanceAmt") || null, tokenRecv: !!s.get("tokenRecvAt"),
        tokenMiss: !s.get("tokenRecvAt") && !!s.get("tokenMissAt"), tokenDue: s.get("tokenDue") || null,
        tokenMethod: s.get("tokenMethod") || null };
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
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


// Tester 13-Oct: packTimer removed — there is no "Packed" step any more; it
// only re-sent identical buttons (Telegram 400 "not modified") every 10 min.
const { onSchedule } = require("firebase-functions/v2/scheduler");


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

let GEM_GOOD = null; // the model that answered last (per instance)
async function geminiJson(bytes, mime, prompt, schema) {
  const { MODELS } = require("./orderVision");
  const order = GEM_GOOD ? [GEM_GOOD, ...MODELS.filter((m) => m !== GEM_GOOD)] : MODELS;
  const deadline = Date.now() + 80000;
  for (const model of order) {
    const left = deadline - Date.now();
    if (left < 4000) break;
    const t0 = Date.now();
    try {
      // Owner 13-Oct: free models answer 429/503 fast but one can hang a minute
      // — 20 s per model, then the next; the working one is tried first.
      const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
        method: "POST", headers: { "x-goog-api-key": GEMINI_API_KEY.value(), "Content-Type": "application/json" },
        signal: AbortSignal.timeout(Math.min(20000, left)),
        body: JSON.stringify({ contents: [{ role: "user", parts: [{ inlineData: { mimeType: mime, data: bytes.toString("base64") } }, { text: prompt }] }],
          generationConfig: { responseMimeType: "application/json", responseJsonSchema: schema, temperature: 0 } }),
      });
      if (!r.ok) {
        logger.warn("gemini", { model, status: r.status, ms: Date.now() - t0 });
        if (GEM_GOOD === model) GEM_GOOD = null;
        continue;
      }
      const j = await r.json();
      const out = JSON.parse(j.candidates[0].content.parts.map((p) => p.text || "").join(""));
      GEM_GOOD = model;
      return out;
    } catch (e) {
      logger.warn("gemini", { model, error: e.message, ms: Date.now() - t0 });
      if (GEM_GOOD === model) GEM_GOOD = null;
    }
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
  const scored = snap.docs.map((x) => ({ id: x.id, ...x.data() })).filter((o) => !o.cancelled)
    .map((o) => ({ ...o, _s: score(o) })).filter((o) => o._s > 0);
  const best = scored.reduce((t, o) => Math.max(t, o._s), 0);
  const all = scored.filter((o) => o._s === best);
  if (best === 1 && new Set(all.map((o) => o.mobile || o.billName)).size > 1) {
    const names = [...new Set(all.map((o) => `${o.billName}${o.serial ? " (ORDER NO. " + o.serial + ")" : ""}`))].join(", ");
    return reply(`❓ "${b.buyerName || "?"}" could be ${names}. Bill not sent — please put the party's mobile number on the bill, or send it again with the exact name.`);
  }
  if (all.length && all.every((o) => o.hold)) {
    return reply(`⏸ ${all[0].billName}${all[0].serial ? " — ORDER NO. " + all[0].serial : ""} is ON HOLD. Bill not sent — remove the hold first, then send the bill again.`);
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
    (advPaid > 0 && b.grandTotal ? ` (token ${inr(advPaid)} received — deducted, balance ${inr(balance)})` : "") +
    ". Send the payment screenshot here 🙏", fileId, mime });
  const no = main.serial ? `ORDER NO. ${main.serial}` : "the order";
  return reply(`✅ Bill sent to ${main.billName} — ${no}${b.billNo ? " · Bill " + b.billNo : ""}${b.grandTotal ? " · ₹" + b.grandTotal : ""}`);
}

const inr = (n) => "₹" + Math.round(Number(n) || 0).toLocaleString("en-IN");

const PAY_PROMPT = "This should be a payment screenshot (UPI app like GPay/PhonePe/Paytm/BHIM, or a bank app NEFT/RTGS/IMPS). " +
  "Return JSON: amount (number, rupees paid), date (YYYY-MM-DD of the payment as shown), time (HH:MM 24-hour as shown), " +
  "txnId (the bank's UPI Ref No. / UTR / RRN — usually 12 digits; NOT the app's own id that starts with letters like T2610… or the PhonePe/GPay transaction id when a UTR is also shown), " +
  "refs (EVERY reference / transaction / UTR / RRN number shown on the screenshot, as strings), " +
  "success (true only if it clearly says successful/completed/paid), " +
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
    // Tester 13-Oct: a payment voided by undoing 💰 never counts (sum or dup).
    const sum = () => pays.filter((x) => !x.voided).reduce((a, x) => a + x.amt, 0);
    if (txn && pays.some((x) => !x.voided && x.txn === txn)) return { dup: true, total: sum() };
    pays.push({ amt: Number(p.amount), txn, paidAt: isNaN(paidAt) ? null : paidAt, at: Date.now() });
    const total = sum();
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
  await say(`✅ Payment screenshot received — ${inr(r.total)} for bill ${inr(bill)}. Thank you sir 🙏 We will confirm once it is credited.`);
  // Owner 18-Oct: a screenshot never ticks the step — only Tally (bill settled) does.
  await staff(`💰 ${head}: FULL payment screenshot ${inr(r.total)} / ${inr(bill)}${due < -1 ? " (extra " + inr(-due) + ")" : ""} — ticks when the bill is settled in Tally`);
  await mainDoc.set({ payShot: Date.now() }, { merge: true });
  return true;
}

/** App: the bill image for an order (party taps VIEW BILL). */
exports.billImage = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 30, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
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
// "17-10-2026" -> "17/10/26" (owner 18-Oct)
const dmy = (x) => { const m = /^(\d{2})-(\d{2})-(\d{4})$/.exec(String(x || "")); return m ? `${m[1]}/${m[2]}/${m[3].slice(2)}` : String(x || ""); };
exports.syncDispatch = onRequest(
  { region: "asia-south1", secrets: [PC_KEY, TG_TOKEN], timeoutSeconds: 120, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const rows = (req.body && req.body.rows) || [];
    const byBill = new Map();
    for (const r of rows) if (r && r.billNo) byBill.set(normBill(r.billNo), r);
    const byParty = new Map();
    for (const r of rows) {
      const k = normName(r && r.party);
      if (!k) continue;
      if (!byParty.has(k)) byParty.set(k, []);
      byParty.get(k).push(r);
    }
    // The first parcel-report bill of this party dated on/after the order day.
    const partyRow = (d) => {
      const list = byParty.get(normName(d.ledgerName || d.billName)) || [];
      const at = d.at && d.at.toDate ? d.at.toDate() : new Date(d.at || 0);
      const from = new Date(at.getTime() - 24 * 3600e3).toISOString().slice(0, 10);
      return list.filter((r) => r.billDate && r.billDate >= from).sort((a, b) => a.billDate.localeCompare(b.billDate))[0] || null;
    };
    const db = admin.firestore();
    const snap = await db.collection("bbapp_orders").where("status", "in", ["bill_sent", "payment_received", "dispatched"]).get();
    let disp = 0, bil = 0;
    for (const doc of snap.docs) {
      const d = doc.data();
      const r = (d.billNo && byBill.get(normBill(d.billNo))) || (d.tallyBillNo && byBill.get(normBill(d.tallyBillNo))) || partyRow(d);
      if (!r) continue;
      // Owner 18-Oct: the Tally bill no. lets the payment check find the bill.
      if (!d.tallyBillNo && r.billNo) await doc.ref.set({ tallyBillNo: String(r.billNo) }, { merge: true });
      if (r.parcelDate && d.status === "payment_received") {
        await autoStep(db, doc.id, "d", dmy(r.parcelDate), { parcelDate: String(r.parcelDate),
          tallyBillNo: String(r.billNo || ""), lr: `Dispatched ${dmy(r.parcelDate)}` });
        disp++;
      }
      if (r.bilty) {
        const cur = ((await doc.ref.get()).data() || {}).status;
        if (cur === "dispatched") {
          const pd = dmy(r.parcelDate || d.parcelDate);
          await autoStep(db, doc.id, "l", String(r.bilty), { lr: `${pd ? "Dispatched " + pd + " · " : ""}Bilty ${r.bilty}`,
            bilty: String(r.bilty), tallyBillNo: String(r.billNo || "") });
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
  // Tester 13-Oct: a photo whose only copy was the mirror (mirror failed, or
  // the number is not usable there) was lost while the app showed "sent" —
  // keep it in Storage ourselves; if even that fails, the send fails.
  if (m.bytes && !m.fileId && !storagePath) {
    storagePath = `bbapp-chat/${ref}/${Date.now()}_${Math.random().toString(36).slice(2, 8)}.${String(m.mime || "").includes("pdf") ? "pdf" : "jpg"}`;
    await admin.storage().bucket().file(storagePath).save(m.bytes, { contentType: m.mime || "image/jpeg" });
  }
  await db.collection("bbapp_chat").add({ ref, cust: o.mobile || "", from: m.from, text: m.text || "",
    fileId: m.fileId || null, storagePath: m.fileId ? null : storagePath, mime: m.mime || null,
    by: m.by || "", at: Date.now(), mirrored: true });
  if (m.from === "shop" && o.mobile) await pushTo(db, custKey(o.mobile), m.text || "📎 Sent you a file");
}

/* ───────────── AKN Chat "AKN App" tab (owner, 11-Oct-2026) ─────────────
 * Every app chat also appears in the AKN Chat staff app as its own chip
 * "AKN App" (pseudo number id 99999, never a WhatsApp number). Staff reply
 * there like any chat; aknChatOut below carries the reply to the customer's
 * app. Safety: bot_logs/{msgId} is created FIRST so AKN Chat's WhatsApp bot
 * never answers these; botEnabled false; numbers["99999"].bot false.
 */
const AKZ_PNID = "99999";
// Tester 13-Oct: a foreign customer's chip is their own full number, never
// "91" + a 10-digit tail (custKey keeps an Indian number at 10 digits).
const akzWaId = (mob) => (mob.length === 10 ? `91${mob}` : mob);
const akzShow = (mob) => (mob.length === 10 ? `+91 ${mob}` : `+${mob}`);
const akzChatId = (mob) => `${akzWaId(mob)}_${AKZ_PNID}`;
let akzTabReady = false;

async function mirrorToAknChat(db, o, m) {
  const mob = custKey(o.mobile);
  if (!mob) return null;
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
    storagePath = `wa-media/${AKZ_PNID}/${akzWaId(mob)}/${msgId}.${isPdf ? "pdf" : "jpg"}`;
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
    wamid: null, waId: akzWaId(mob), phoneNumberId: AKZ_PNID, timestamp: now,
    createdAt: FieldValue.serverTimestamp(), replyToWamid: null, senderStaffId: null, error: null,
    mediaStatus: "none", text: type === "text" ? text : null, caption: type === "text" ? null : (text || null),
    mediaPath: null, mediaMime: null, fileName: null, fileSize: null, aknzSource: true, ...media,
  };
  const chatRef = db.collection("chats").doc(chatId);
  await db.runTransaction(async (t) => {
    const c = await t.get(chatRef);
    const base = c.exists ? {} : { pinned: false, needsAttention: false, botPausedUntil: null, createdAt: now,
      profileName: o.billName || akzShow(mob) };
    t.set(chatRef.collection("messages").doc(msgId), msg);
    t.set(chatRef, {
      ...base, waId: akzWaId(mob), phoneNumberId: AKZ_PNID, name: o.billName || akzShow(mob), botEnabled: false,
      lastMessageText: (type === "text" ? text : (type === "image" ? "📷 Photo" : "📄 Bill")).slice(0, 200),
      lastMessageAt: now, lastMessageType: type, updatedAt: now,
      windowExpiresAt: Timestamp.fromMillis(Date.now() + 3650 * 86400e3),
      ...(inbound ? { unreadCount: FieldValue.increment(1), lastCustomerMsgAt: now } : {}),
      // Tester 13-Oct: a staff reply from the Telegram group (m.by = the
      // staff name) answers the chat — clear the chip like aknChatOut does.
      // Automatic notes (bill, payment) leave an unanswered chat unread.
      ...(!inbound && m.by ? { unreadCount: 0, needsAttention: false, lastHumanSendAt: now } : {}),
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
    // "91" + 10 digits = an Indian customer; anything else = a foreign key.
    const wa = chatId.slice(0, chatId.indexOf("_"));
    const mob = wa.length === 12 && wa.startsWith("91") ? wa.slice(2) : wa;
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("c:" + ip)) return res.status(429).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const text = String((req.body && req.body.text) || "").slice(0, 2000);
    const img = req.body && req.body.image ? Buffer.from(String(req.body.image), "base64") : null;
    if (!ref || (!text && !img) || (img && img.length > 6 * 1024 * 1024)) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    const d = (await db.collection("bbapp_orders").doc(ref).get()).data();
    if (!d || !d.chat) return res.json({ ok: false, error: "order not found" });
    if (await isBlocked(db, d.mobile)) return res.status(403).json({ ok: false, error: "blocked" });
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
    // Tester 13-Oct: the bytes go along too — a failed Telegram send must not
    // lose the screenshot (it is still kept in Storage / AKN Chat).
    await addChat(db, ref, { from: "party", text, fileId, bytes: img, mime: img ? "image/jpeg" : null });
    // Owner 16-Oct: every payment screenshot also goes to the payment group,
    // with the party name and destination under it.
    if (img) {
      try {
        const rg = (await db.collection("bbapp_settings").doc("receipts").get()).data();
        if (rg && rg.chat) {
          const acc = (await db.collection("bbapp_accounts").doc(accKey(d.mobile) || "-").get()).data() || {};
          const party = String(d.ledgerName || (acc.kind === "existing" && acc.party) || d.billName || "?").toUpperCase();
          const dest = String((d.cust && d.cust.bookingPlace) || (acc.cust && acc.cust.bookingPlace) || "").toUpperCase();
          const fd = new FormData();
          fd.append("chat_id", String(rg.chat));
          fd.append("caption", `${party}\n📍 ${dest || "-"}\n💰 Payment screenshot from the app${d.serial ? " · ORDER NO. " + d.serial : ""}${text ? "\n" + text : ""}`.slice(0, 1000));
          fd.append("photo", new Blob([img], { type: "image/jpeg" }), "payment.jpg");
          const x = await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendPhoto`, { method: "POST", body: fd }).then((y) => y.json());
          if (!x.ok) logger.warn("payment group photo", { ref, desc: x.description });
        }
      } catch (e) { logger.warn("payment group photo", { ref, error: e.message }); }
    }
    let paid = false;
    if (img && (d.status || "received") === "bill_sent") paid = await checkPayment(db, ref, img);
    return res.json({ ok: true, paid });
  },
);

exports.chatList = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    // A phone polls its 1-3 numbers every 20 s — the limit only stops guessing.
    if (limited("cl:" + ip, 1500)) return res.status(429).json({ ok: false });
    // ONE chat per customer (owner): all messages for this mobile.
    const cust = custKey(req.body && req.body.mobile);
    if (!cust) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    if (!(await deviceOwns(db, req.body && req.body.device, cust))) return res.status(403).json({ ok: false, error: "not linked" });
    // Tester 13-Oct: only messages newer than `since` (the app keeps the rest)
    // — reading the whole chat every poll drained the free Firestore quota.
    const since = Math.max(0, Number(req.body && req.body.since) || 0);
    let docs;
    try {
      let qy = db.collection("bbapp_chat").where("cust", "==", cust);
      if (since) qy = qy.where("at", ">", since);
      docs = (await qy.orderBy("at", "desc").limit(200).get()).docs;
    } catch (e) {
      // Index (cust ↑, at ↓) not built yet → the old full read, still correct.
      logger.warn("chatList index", { error: e.message });
      docs = (await db.collection("bbapp_chat").where("cust", "==", cust).get()).docs
        .filter((x) => (x.get("at") || 0) > since);
    }
    const msgs = docs.map((x) => ({ id: x.id, ...x.data() })).sort((a, b) => a.at - b.at).slice(-200)
      .map((m) => ({ id: m.id, from: m.from, text: m.text, at: m.at, by: m.by, file: !!(m.fileId || m.storagePath), mime: m.mime }));
    return res.json({ ok: true, msgs });
  },
);

/**
 * Tester 13-Oct: chats, bills and payment screenshots only for a phone linked
 * to that number (bbapp_devices — phoneLock links a number when this phone
 * places an order for it). Before, any guessed mobile opened them.
 */
async function deviceOwns(db, device, cust) {
  const id = String(device || "").replace(/[^a-z0-9-]/gi, "").slice(0, 64);
  if (!id || !cust) return false;
  const d = await db.collection("bbapp_devices").doc(id).get();
  return ((d.exists && d.get("mobiles")) || []).some((x) => custKey(x) === cust);
}

exports.chatFile = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 30, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("cf:" + ip, 600)) return res.status(429).json({ ok: false });
    const cust = custKey(req.body && req.body.mobile);
    const id = String((req.body && req.body.id) || "").slice(0, 64);
    const db = admin.firestore();
    if (!(await deviceOwns(db, req.body && req.body.device, cust))) return res.status(403).json({ ok: false, error: "not linked" });
    const m = id ? (await db.collection("bbapp_chat").doc(id).get()).data() : null;
    if (!m || !cust || m.cust !== cust || (!m.fileId && !m.storagePath)) return res.json({ ok: false });
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
    // Tester 13-Oct: shop PC only (x-pc-key) — the app key ships inside the
    // APK and must never open or change party data.
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    for (const r of ((req.body && req.body.ack) || []).slice(0, 50)) {
      const id = String(r).replace(/[^A-Z0-9-]/gi, "");
      // Owner 14-Oct: an approved sign-up ("ACCT-<mobile>") is acked on the account.
      await (id.startsWith("ACCT-") ? db.collection("bbapp_accounts").doc(id.slice(5)) : db.collection("bbapp_orders").doc(id)).set(
        { partyQueuedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
      // Owner 14-Oct: the first order made the ledger -> the account has one now.
      if (!id.startsWith("ACCT-")) {
        const om = accKey(((await db.collection("bbapp_orders").doc(id).get()).data() || {}).mobile);
        if (om) await db.collection("bbapp_accounts").doc(om).set({ partyQueuedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
      }
    }
    const snap = await db.collection("bbapp_orders")
      // Owner 11-Oct: the ledger is made as soon as the customer places the order.
      .where("status", "in", ["received", "getting_ready", "bill_sent", "payment_received", "dispatched", "bilty"]).get();
    // Owner 14-Oct: an app account's ledger is made at approval — its orders
    // are not sent again (no "already in Tally" note for every first order).
    const accAll = await db.collection("bbapp_accounts").get();
    const hasLedger = new Set(accAll.docs.filter((x) => x.get("kind") === "existing" || x.get("partyQueuedAt")).map((x) => x.id));
    // Owner 15-Oct: the optional PAN (and Aadhaar) from sign-up go into the ledger too.
    const accCust = new Map(accAll.docs.map((x) => [x.id, x.get("cust") || {}]));
    const out = snap.docs.map((x) => ({ ref: x.id, ...x.data() }))
      .filter((o) => o.cust && !o.addOnTo && !o.partyQueuedAt && !hasLedger.has(accKey(o.mobile)))
      .map((o) => { const ac = accCust.get(accKey(o.mobile)) || {}; return { ...o, cust: { ...o.cust,
        ...(!o.cust.pan && ac.pan ? { pan: ac.pan } : {}), ...(!o.cust.taxId && ac.taxId ? { taxId: ac.taxId } : {}) } }; })
      .sort((a, b) => (a.serial || 0) - (b.serial || 0)) // oldest first
      .map((o) => ({ ref: o.ref, serial: o.serial || null, cust: o.cust,
        advance: o.advanceAmt ? { paid: o.advanceAmt, utr: o.advanceUtr || null } : null }));
    // Owner 14-Oct 21:50: NO ledger at approval any more — the first order
    // (above) makes it. Accounts acked before keep their ledger (hasLedger).
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
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
    // Tester 13-Oct: only an Indian number can be an Indian party's — a
    // foreign number's last 10 digits matched one, named it and blocked the order.
    const inMob = (c.country || "India") === "India" && /^[6-9]\d{9}$/.test(mob);
    const byMob = inMob && ((((PARTIES[mob] || [])[0] || {}).name) || NPCHECK.mobiles[mob]);
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const token = String((req.body && req.body.token) || "").slice(0, 400);
    const mobiles = ((req.body && req.body.mobiles) || []).map(custKey).filter(Boolean).slice(0, 3);
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

async function pushTo(db, mobile, body, route = "/chat") {
  try {
    const snap = await db.collection("bbapp_push").where("mobiles", "array-contains", mobile).get();
    if (snap.empty) return;
    const text = String(body || "New message").slice(0, 180);
    const iosDocs = snap.docs.filter((d) => d.get("apns"));
    const sentApns = new Set();
    for (const d of iosDocs) {
      if (sentApns.has(d.get("apns"))) continue; // old duplicate record
      sentApns.add(d.get("apns"));
      const st = await apnsSend(d.get("apns"), text, "api.push.apple.com", route);
      if (st === 400 || st === 410) d.ref.set({ apns: null }, { merge: true }).catch(() => {});
    }
    const fcmDocs = snap.docs.filter((d) => !d.get("apns"));
    if (!fcmDocs.length) return;
    const tokens = fcmDocs.map((d) => d.get("token"));
    const r = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title: "B.B SYNTHETICS", body: String(body || "New message").slice(0, 180) },
      data: { route },
      apns: { payload: { aps: { sound: "default", badge: 1 } } },
      android: { priority: "high", notification: { sound: "default", channelId: "chat" } }, // heads-up channel
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
function apnsSend(deviceToken, text, host = "api.push.apple.com", route = "/chat") {
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
          return apnsSend(deviceToken, text, "api.sandbox.push.apple.com", route).then(finish);
        }
        finish(status);
      });
      req.on("error", () => finish(0));
      req.setTimeout(10000, () => { req.close(); finish(0); });
      // "gcm.message_id": firebase_messaging reports a tap / a foreground
      // arrival to the app only when this key is present (tester 13-Oct).
      req.end(JSON.stringify({ aps: { alert: { title: "B.B SYNTHETICS", body: text }, sound: "default", badge: 1 },
        route, "gcm.message_id": `${Date.now()}-${Math.random().toString(36).slice(2, 10)}` }));
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
    if (!appOk(req)) return res.status(403).json({ ok: false });
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
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
    // Tester 13-Oct: shop PC only (x-pc-key) — the app key ships inside the
    // APK and must never open or change party data.
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
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
  "txnId (the bank's UPI Ref No. / UTR / RRN — usually 12 digits; NOT the app's own id that starts with letters like T2610… or the PhonePe/GPay transaction id when a UTR is also shown), " +
  "refs (EVERY reference / transaction / UTR / RRN number shown on the screenshot, as strings), " +
  "success (true only if it clearly says successful/completed/paid), " +
  "payee (the RECEIVER's name exactly as shown), payeeAccount (receiver's UPI id or account number, as shown). Use null when not shown. " +
  "If it is not a payment screenshot, amount = null.";
const ADV_SCHEMA = { type: "object", properties: {
  amount: { type: ["number", "null"] }, date: { type: ["string", "null"] }, time: { type: ["string", "null"] },
  txnId: { type: ["string", "null"] }, refs: { type: ["array", "null"], items: { type: "string" } },
  success: { type: ["boolean", "null"] }, payee: { type: ["string", "null"] },
  payeeAccount: { type: ["string", "null"] } }, required: ["amount"] };

/** A payment screenshot's TEXT (read on the phone by ML Kit) → the same
 *  fields Gemini returns, or null when anything is unclear (then the AI reads
 *  the picture). Only a clear success to B B SYNTHETICS with an amount and a
 *  12-digit bank reference passes here. */
function parseUpiText(t) {
  if (!t || t.length < 20) return null;
  const U = t.toUpperCase();
  if (/FAIL|DECLIN|UNSUCCESS|PENDING|REVERS|CANCEL|REFUND|PROCESSING/.test(U)) return null;
  if (!/SUCCESS|PAID|COMPLETED|DEBITED|SENT/.test(U)) return null;
  const flat = U.replace(/[^A-Z0-9]/g, "");
  if (!(flat.includes("BBSYNTHETIC") || flat.includes("173947529358"))) return null;
  const amts = [...t.matchAll(/(?:₹|RS\.?|INR)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/gi)]
    .map((m) => Number(m[1].replace(/,/g, ""))).filter((n) => n > 0 && n < 10000000);
  if (!amts.length || new Set(amts).size > 2) return null; // no / conflicting amounts
  const amount = amts[0];
  // our own UPI id digits (vyapar.173947529358) are 12 digits too — never a UTR
  const refs = [...new Set((U.match(/\b\d{12}\b/g) || []))].filter((x) => x !== "173947529358");
  if (!refs.length) return null;
  const MON = { JAN: 1, FEB: 2, MAR: 3, APR: 4, MAY: 5, JUN: 6, JUL: 7, AUG: 8, SEP: 9, OCT: 10, NOV: 11, DEC: 12 };
  let date = null, time = null;
  const dm = /(\d{1,2})[\s-]*(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*[\s,-]*(\d{4})/.exec(U);
  if (dm) date = `${dm[3]}-${String(MON[dm[2]]).padStart(2, "0")}-${dm[1].padStart(2, "0")}`;
  const tm = /(\d{1,2})[:.](\d{2})\s*(AM|PM)?/.exec(U.slice(dm ? Math.max(0, dm.index - 40) : 0));
  if (tm) {
    let h = Number(tm[1]);
    if (tm[3] === "PM" && h < 12) h += 12;
    if (tm[3] === "AM" && h === 12) h = 0;
    if (h < 24) time = `${String(h).padStart(2, "0")}:${tm[2]}`;
  }
  return { amount, date, time, txnId: refs[0], refs, success: true, payee: "B B SYNTHETICS",
    payeeAccount: flat.includes("173947529358") ? "vyapar.173947529358@hdfcbank" : null, via: "phone-ocr" };
}

exports.advanceStart = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const b = req.body || {};
    const ref = String(b.ref || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    let due = Math.round(Number(b.due) || 0);
    if (!ref || due <= 0) return res.status(400).json({ ok: false });
    if (await isBlocked(admin.firestore(), b.mobile)) return res.status(403).json({ ok: false, error: "blocked" });
    // Review 13-Oct: the phone does not decide a small token. 10% of the
    // order (rounded up to ₹10) unless the owner's LIVE TEST switch is on and
    // this is his trial / "TEST…" order.
    const total = Math.round(Number(b.total) || 0);
    const live = ((await admin.firestore().collection("bbapp_settings").doc("livetest").get()).data() || {}).on === true;
    const testy = ref.startsWith("AKNTEST-") || /^\s*TEST/i.test(String(b.billName || ""));
    if (!(live && testy) && total > 0) due = Math.max(due, Math.ceil((total * 0.10) / 10) * 10);
    if (!(live && testy) && ref.startsWith("AKNTEST-")) return res.status(403).json({ ok: false });
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
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
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
      return fail(`This screenshot is already received (${inr(have)} of the ${inr(a.due)} token). Please pay ${inr(Math.max(0, a.due - have))} more and send that screenshot.`);
    }
    const usedImg = await db.collection("bbapp_advances").where("hashes", "array-contains", hash).get();
    if (usedImg.docs.some((x) => x.id !== ref)) return fail("This payment screenshot was already used for another order.");
    // Owner 13-Oct: the phone's own text reading first (fast, no AI quota);
    // the AI only when that text is unclear.
    const p = parseUpiText(String((req.body && req.body.ocr) || "")) || await geminiJson(img, "image/jpeg", ADV_PROMPT, ADV_SCHEMA);
    if (!p) return fail("Could not read the screenshot right now — please try again in a minute.");
    if (!p.amount || p.amount <= 0) return fail("This does not look like a payment screenshot. Please send the screenshot of your payment.");
    if (p.success === false) return fail("This payment does not show as successful. Please send the screenshot of a successful payment.");
    // Only OUR name / UPI id / account — "XYZ SYNTHETICS" must not pass.
    const who = `${p.payee || ""} ${p.payeeAccount || ""}`.toUpperCase().replace(/[^A-Z0-9]/g, "");
    const ours = who.includes("BBSYNTHETIC") || who.includes("173947529358");
    if (!ours) return fail(`This payment went to "${p.payee || p.payeeAccount || "someone else"}". The token must be paid to B B SYNTHETICS only.`);
    // Owner 13-Oct: HDFC only — not to our BOI / Kotak accounts (the morning
    // bank check reads the HDFC report only).
    if (who.includes("KOTAK") || who.includes("88665369922") || who.includes("270320110001776") || who.includes("BKID")) {
      return fail("Please pay the token only to our HDFC QR / UPI id on this page (vyapar.173947529358@hdfcbank) — not to another bank account.");
    }
    const tm = /^\d{1,2}:\d{2}$/.test(String(p.time || "")) ? String(p.time).padStart(5, "0") : null;
    const dt = /^\d{4}-\d{2}-\d{2}$/.test(String(p.date || "")) ? p.date
      : (tm ? new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10) : null);
    const paidAt = dt ? Date.parse(`${dt}T${tm || "23:59"}:00+05:30`) : NaN;
    if (!isNaN(paidAt) && paidAt < Math.floor((a.orderAt || 0) / 60000) * 60000 - 10 * 60e3) {
      return fail("This screenshot is from before your order. Please send the screenshot of the payment you made now.");
    }
    // The bank UTR = a 12-digit number (UPI RRN); prefer it over an app's own id.
    const allRefs = [p.txnId, ...(Array.isArray(p.refs) ? p.refs : [])]
      .map((x) => String(x || "").toUpperCase().replace(/[^A-Z0-9]/g, "")).filter((x) => x.length >= 8);
    const utr = allRefs.find((x) => /^\d{12}$/.test(x)) || allRefs[0] || "";
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
    parts.push({ amt, utr: utr || null, refs: [...new Set(allRefs)].slice(0, 6), paidAt: at, hash });
    const sum = parts.reduce((t, x) => t + x.amt, 0);
    const path = `advances/${ref}${parts.length > 1 ? "-" + parts.length : ""}.jpg`;
    await admin.storage().bucket().file(path).save(img, { contentType: "image/jpeg" });
    const utrs = [...new Set(parts.flatMap((x) => [x.utr, ...(x.refs || [])]).filter(Boolean))];
    const hashes = admin.firestore.FieldValue.arrayUnion(hash);
    if (sum + 1 < a.due) {
      await docRef.set({ parts, utrs, hashes, utr: utrs[0] || null, path }, { merge: true });
      return fail(`Received ${inr(sum)} of the ${inr(a.due)} token. Please pay ${inr(a.due - sum)} more and send that screenshot too.`);
    }
    // Where the money went (review 13-Oct): only the HDFC QR / Vyapar id is in
    // the bank report the morning check reads; BOI transfers and the Kotak id
    // are checked by hand.
    const method = (who.includes("8866") && who.includes("KOTAK")) || who.includes("88665369922") ? "kotak"
      : (who.includes("1776") || who.includes("BKID") || who.includes("BANKOFINDIA")) && !who.includes("VYAPAR") ? "bank"
        : "upi";
    await docRef.set({ state: "paid", method, parts, utrs, hashes, paid: sum, utr: utrs.join(", ") || null, payee: p.payee || null,
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
      if (String(d.id).startsWith("AKNTEST-")) continue; // owner's ₹5 payment trial
      await tg("sendMessage", { chat_id: ORDER_GROUP,
        text: `⏳ NEW CUSTOMER has not paid the 10% token yet\n${a.billName || "-"} · ${a.mobile || "-"}\nOrder approx ${inr(a.total)} · token ${inr(a.due)}\nPlease call them.` });
      await d.ref.set({ reminded: Date.now() }, { merge: true });
    }
  },
);

/* ───────────── "💰 Money received" (owner, 13-Oct-2026) ─────────────
 * NewPartyBot posts the new party's verified token screenshot in the "Akn zone
 * - New party creation" group, then asks here for a button under it. When the
 * money is really in the bank the owner taps it → the customer's app shows
 * "Token received". Tap again (same person) = undo.
 */
// Owner 13-Oct: no button — the HDFC bank check (token_confirm.py) ticks it.
// Review 13-Oct: BOI transfers / the Kotak id are not in the HDFC report —
// only those keep a "💰 Money received" button for the owner.
const moneyKeyboard = (ref, d) => ({ inline_keyboard: d && (d.tokenMethod === "bank" || d.tokenMethod === "kotak") ? [[d.tokenRecvAt
  ? { text: `💰 ✅ ${firstName(d.tokenRecvBy)}`, callback_data: `m|t|${ref}` }
  : { text: "💰 Money received (checked in the bank)", callback_data: `m|t|${ref}` }]] : [] });

function moneyText(d) {
  const head = `💰 TOKEN ${inr(d.advanceAmt || 0)} — ${escH(d.billName || "Party")}${d.serial ? " · ORDER NO. " + d.serial : ""}`;
  const log = (d.tokenLog || []).map((e) => e.a === "undo"
    ? `↩️ Undone — by ${escH(e.by)} · ${hhmm(e.at)}`
    : e.a === "miss" ? `❌ Money NOT received by 12:00 — ${escH(e.by)} · ${hhmm(e.at)}`
      : `✔ Money received — by ${escH(e.by)} · ${hhmm(e.at)}`);
  const due = d.tokenDue ? new Date(Number(d.tokenDue) + 5.5 * 3600e3).toISOString().slice(0, 10).split("-").reverse().join("-") : "tomorrow";
  const how = d.tokenMethod === "bank" ? "🏦 Paid to BOI by bank transfer — please check the BOI account and tap the button."
    : d.tokenMethod === "kotak" ? "🏦 Paid to the KOTAK UPI id — please check Kotak and tap the button."
      : `🏦 Bank check: automatic, by 12:00 on ${due}.`;
  return `${head}\n${how}${log.length ? "\n\n" + log.join("\n") : ""}`;
}

async function moneyReceivedTap(db, q, ref) {
  const docRef = db.collection("bbapp_orders").doc(String(ref).replace(/[^A-Z0-9-]/gi, "").slice(0, 40));
  const name = [q.from && q.from.first_name, q.from && q.from.last_name].filter(Boolean).join(" ")
    || (q.from && q.from.username) || "staff";
  const uid = (q.from && q.from.id) || 0;
  const verdict = await db.runTransaction(async (tx) => {
    const d = (await tx.get(docRef)).data();
    if (!d) return { ok: false, msg: "Order not found." };
    if (d.tokenRecvAt) {
      if (d.tokenRecvUid && d.tokenRecvUid !== uid) return { ok: false, msg: `Only ${d.tokenRecvBy} can undo this.` };
      tx.set(docRef, { tokenRecvAt: admin.firestore.FieldValue.delete(), tokenRecvBy: admin.firestore.FieldValue.delete(),
        tokenRecvUid: admin.firestore.FieldValue.delete(),
        tokenLog: admin.firestore.FieldValue.arrayUnion({ a: "undo", by: name, at: Date.now() }) }, { merge: true });
      return { ok: true, msg: "Undone." };
    }
    tx.set(docRef, { tokenRecvAt: admin.firestore.FieldValue.serverTimestamp(), tokenRecvBy: name, tokenRecvUid: uid,
      tokenMissAt: admin.firestore.FieldValue.delete(),
      tokenLog: admin.firestore.FieldValue.arrayUnion({ a: "do", by: name, at: Date.now() }) }, { merge: true });
    return { ok: true, msg: `Money received — by ${name}` };
  });
  await tg("answerCallbackQuery", { callback_query_id: q.id, text: verdict.msg, show_alert: !verdict.ok });
  if (verdict.ok && q.message) {
    const fresh = (await docRef.get()).data() || {};
    await tg("editMessageText", { chat_id: q.message.chat.id, message_id: q.message.message_id,
      text: moneyText(fresh), parse_mode: "HTML", reply_markup: moneyKeyboard(docRef.id, fresh) });
  }
}

/** Shop PC (NewPartyBot): post the "💰 Money received" button in its group. */
exports.tokenButton = onRequest(
  { region: "asia-south1", secrets: [PC_KEY, TG_TOKEN], timeoutSeconds: 30, memory: "256MiB", maxInstances: 2, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const chat = String((req.body && req.body.chat) || "").replace(/[^0-9-]/g, "");
    if (!ref || !chat) return res.status(400).json({ ok: false });
    const docRef = admin.firestore().collection("bbapp_orders").doc(ref);
    const d = (await docRef.get()).data();
    if (!d || !d.advanceAmt) return res.json({ ok: false, error: "no token on this order" });
    const r = await tg("sendMessage", { chat_id: chat, text: moneyText(d), parse_mode: "HTML", reply_markup: moneyKeyboard(ref, d) });
    // Owner 13-Oct: if the order bot is not in that group the status line is
    // skipped — the ledger name and the receipts-group photo still go ahead.
    if (!r.ok) logger.warn("tokenButton status line", { ref, chat, desc: r.description });
    const ledger = String((req.body && req.body.ledger) || "").slice(0, 120);
    await docRef.set({ ...(r.ok ? { tokenMsg: { chat, msg: r.result.message_id } } : {}),
      ...(ledger ? { ledgerName: ledger } : {}) }, { merge: true });
    try {
      const rg = (await admin.firestore().collection("bbapp_settings").doc("receipts").get()).data();
      const adv = (await admin.firestore().collection("bbapp_advances").doc(ref).get()).data();
      if (rg && rg.chat && adv && adv.path) {
        const [bytes] = await admin.storage().bucket().file(adv.path).download();
        const fd = new FormData();
        fd.append("chat_id", String(rg.chat));
        fd.append("caption", `${(ledger || "LEDGER NOT MADE — " + (d.billName || "?")).toUpperCase()}\n` +
          `📱 AKN ZONE APP TOKEN ${inr(d.advanceAmt)}${adv.utr ? " · UTR " + adv.utr : ""}${d.serial ? " · ORDER NO. " + d.serial : ""}`);
        fd.append("photo", new Blob([bytes], { type: "image/jpeg" }), "token.jpg");
        const x = await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendPhoto`, { method: "POST", body: fd }).then((y) => y.json());
        if (!x.ok) logger.warn("receipts group photo", { ref, desc: x.description });
      } else if (!rg) {
        logger.warn("receipts group not connected — add @Aknzonesales_bot to 'Akn zone - auto receipts bot'");
      }
    } catch (e) { logger.warn("receipts group photo", { ref, error: e.message }); }
    return res.json({ ok: true });
  },
);

/** 12:00 IST on the day after [ms] (IST) — the bank check deadline. */
function tokenDeadline(ms) {
  const ist = new Date(Number(ms) + 5.5 * 3600e3);
  return Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), ist.getUTCDate() + 1, 12, 0, 0) - 5.5 * 3600e3;
}

/** Shop PC (token_confirm.py): token orders still waiting for the bank check. */
exports.tokensPending = onRequest(
  { region: "asia-south1", secrets: [PC_KEY], timeoutSeconds: 30, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    const snap = await db.collection("bbapp_orders").where("advanceAmt", ">", 0).get();
    const out = [];
    for (const x of snap.docs) {
      const o = x.data();
      if (o.tokenRecvAt && o.tallyDone) continue;
      if (o.tokenRecvAt && Date.now() - (o.tokenRecvAt.toMillis ? o.tokenRecvAt.toMillis() : 0) > 30 * 86400e3) continue;
      const a = (await db.collection("bbapp_advances").doc(x.id).get()).data() || {};
      out.push({ ref: x.id, serial: o.serial || null, billName: o.billName || "", ledger: o.ledgerName || null, mobile: o.mobile || "",
        amount: o.advanceAmt, utrs: a.utrs || (a.utr ? String(a.utr).split(/[ ,]+/) : []),
        paidAt: a.paidAt || a.verifiedAt || null, method: a.method || o.tokenMethod || "upi",
        due: o.tokenDue || tokenDeadline(a.paidAt || a.verifiedAt || Date.now()), missed: !!o.tokenMissAt,
        recv: !!o.tokenRecvAt, tallyDone: o.tallyDone || null });
    }
    return res.json({ ok: true, tokens: out });
  },
);

/** Shop PC (token_confirm.py): the bank check result for one token. */
exports.tokenConfirm = onRequest(
  { region: "asia-south1", secrets: [PC_KEY, TG_TOKEN, APNS_KEY], timeoutSeconds: 30, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const b = req.body || {};
    const ref = String(b.ref || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    if (!ref) return res.status(400).json({ ok: false });
    const db = admin.firestore();
    const docRef = db.collection("bbapp_orders").doc(ref);
    const d = (await docRef.get()).data();
    if (!d || !d.advanceAmt) return res.json({ ok: false, error: "no token on this order" });
    const by = String(b.by || "HDFC bank check").slice(0, 60);
    if (b.ask) {
      if (!d.tokenAskAt && d.tokenMsg && d.tokenMsg.chat) {
        await tg("sendMessage", { chat_id: d.tokenMsg.chat, reply_to_message_id: d.tokenMsg.msg,
          text: `🏦 ${d.billName || "Party"}${d.serial ? " · ORDER NO. " + d.serial : ""}: token ${inr(d.advanceAmt)} — ${String(b.ask).slice(0, 300)}` });
      }
      await docRef.set({ tokenAskAt: Date.now() }, { merge: true });
      return res.json({ ok: true });
    }
    if (b.tally) {
      await docRef.set({ tallyDone: String(b.tally).slice(0, 200) }, { merge: true });
      return res.json({ ok: true });
    }
    if (b.received && d.tokenRecvAt) {
      if (b.note && d.tokenMsg && d.tokenMsg.chat) {
        await tg("sendMessage", { chat_id: d.tokenMsg.chat, reply_to_message_id: d.tokenMsg.msg,
          text: `ℹ️ ${d.billName || "Party"}${d.serial ? " · ORDER NO. " + d.serial : ""}: ${String(b.note).slice(0, 400)}` });
      }
      return res.json({ ok: true, already: true });
    }
    if (b.received) {
      await docRef.set({ tokenRecvAt: admin.firestore.FieldValue.serverTimestamp(), tokenRecvBy: by, tokenRecvUid: 0,
        tokenMissAt: admin.firestore.FieldValue.delete(),
        tokenLog: admin.firestore.FieldValue.arrayUnion({ a: "do", by, at: Date.now() }) }, { merge: true });
    } else {
      if (d.tokenRecvAt || d.tokenMissAt) return res.json({ ok: true, already: true });
      await docRef.set({ tokenMissAt: admin.firestore.FieldValue.serverTimestamp(),
        tokenLog: admin.firestore.FieldValue.arrayUnion({ a: "miss", by, at: Date.now() }) }, { merge: true });
    }
    const fresh = (await docRef.get()).data() || {};
    if (fresh.tokenMsg && fresh.tokenMsg.chat) {
      await tg("editMessageText", { chat_id: fresh.tokenMsg.chat, message_id: fresh.tokenMsg.msg,
        text: moneyText(fresh), parse_mode: "HTML", reply_markup: moneyKeyboard(ref, fresh) });
      if (!b.received) {
        await tg("sendMessage", { chat_id: fresh.tokenMsg.chat, reply_to_message_id: fresh.tokenMsg.msg,
          text: `❌ ${fresh.billName || "Party"}${fresh.serial ? " · ORDER NO. " + fresh.serial : ""}: token ${inr(fresh.advanceAmt)} NOT found in the HDFC bank report by 12:00 — please check.${b.note ? "\n" + String(b.note).slice(0, 300) : ""}` });
      }
    }
    return res.json({ ok: true });
  },
);

/** Shop PC (NewPartyBot): a new customer's advance screenshot. */
exports.advanceImage = onRequest(
  { region: "asia-south1", secrets: [PC_KEY], timeoutSeconds: 30, memory: "256MiB", maxInstances: 2, invoker: "public" },
  async (req, res) => {
    // Tester 13-Oct: shop PC only (x-pc-key) — the app key ships inside the
    // APK and must never open or change party data.
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const ref = String((req.body && req.body.ref) || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
    const a = ref ? (await admin.firestore().collection("bbapp_advances").doc(ref).get()).data() : null;
    if (!a || a.state !== "paid" || !a.path) return res.json({ ok: false });
    const [bytes] = await admin.storage().bucket().file(a.path).download();
    return res.json({ ok: true, paid: a.paid, utr: a.utr || null, data: bytes.toString("base64") });
  },
);


/* ───────────── ACCOUNTS (owner, 14-Oct-2026) ─────────────
 * First open: the customer's mobile is verified on WhatsApp ("AKN LOGIN
 * <code>" to the Inquiries number → AKN Chat writes bbapp_verify/{code}).
 *   • number in Tally (parties.json) → pick your party → approved at once
 *     (notice in the "Akn zone app" group, 🚫 Block button)
 *   • new Indian customer → full details (GST or PAN or Aadhaar) → pending →
 *     ✅ Approve / ❌ Decline / 🚫 Block in the group; ✅ → NewPartyBot makes
 *     the Tally ledger (newParties "ACCT-<mobile>")
 *   • outside India → name, bill name, address, destination → approved
 * bbapp_accounts/{key}: key = 10-digit Indian mobile or full foreign number.
 * /block 98xxxxxxxx, /unblock 98xxxxxxxx in any group with the bot.
 */
function accKey(raw) {
  let d = String(raw || "").replace(/\D/g, "");
  if (d.length === 12 && d.startsWith("91")) d = d.slice(2);
  if (d.length === 11 && d.startsWith("0")) d = d.slice(1);
  return d.length >= 7 && d.length <= 15 ? d : null;
}

async function isBlocked(db, mobile) {
  const k = accKey(mobile);
  if (!k) return false;
  const a = (await db.collection("bbapp_accounts").doc(k).get()).data();
  return !!(a && a.status === "blocked");
}

async function approvalsChat(db) {
  const s = (await db.collection("bbapp_settings").doc("approvals").get()).data();
  return s && s.chat;
}

const accKeyboard = (key, status) => ({ inline_keyboard: status === "pending"
  ? [[{ text: "✅ Approve", callback_data: `a|ok|${key}` }, { text: "❌ Decline", callback_data: `a|no|${key}` }],
    [{ text: "🚫 Block", callback_data: `a|blk|${key}` }]]
  : status === "blocked" ? [[{ text: "↩️ Unblock", callback_data: `a|unb|${key}` }, { text: "⏳ Waiting", callback_data: `a|wait|${key}` }]]
    : status === "declined" ? [[{ text: "✅ Approve", callback_data: `a|ok|${key}` }, { text: "🚫 Block", callback_data: `a|blk|${key}` }]]
    // Owner 15-Oct: "Waiting" puts an approved customer back on the
    // "waiting for approval" screen — they never see that they were stopped.
    : [[{ text: "⏳ Waiting", callback_data: `a|wait|${key}` }, { text: "🚫 Block", callback_data: `a|blk|${key}` }]] });

const GST_STATES = { "01": "Jammu & Kashmir", "02": "Himachal Pradesh", "03": "Punjab", "04": "Chandigarh", "05": "Uttarakhand",
  "06": "Haryana", "07": "Delhi", "08": "Rajasthan", "09": "Uttar Pradesh", "10": "Bihar", "11": "Sikkim", "12": "Arunachal Pradesh",
  "13": "Nagaland", "14": "Manipur", "15": "Mizoram", "16": "Tripura", "17": "Meghalaya", "18": "Assam", "19": "West Bengal",
  "20": "Jharkhand", "21": "Odisha", "22": "Chhattisgarh", "23": "Madhya Pradesh", "24": "Gujarat", "26": "Dadra & Nagar Haveli and Daman & Diu",
  "27": "Maharashtra", "29": "Karnataka", "30": "Goa", "31": "Lakshadweep", "32": "Kerala", "33": "Tamil Nadu", "34": "Puducherry",
  "35": "Andaman & Nicobar", "36": "Telangana", "37": "Andhra Pradesh", "38": "Ladakh" };
// Pincode first 2 digits -> state (when there is no GSTIN).
const PIN_STATES = [[11, 11, "Delhi"], [12, 13, "Haryana"], [14, 16, "Punjab"], [17, 17, "Himachal Pradesh"], [18, 19, "Jammu & Kashmir"],
  [20, 28, "Uttar Pradesh"], [30, 34, "Rajasthan"], [36, 39, "Gujarat"], [40, 44, "Maharashtra"], [45, 48, "Madhya Pradesh"],
  [49, 49, "Chhattisgarh"], [50, 50, "Telangana"], [51, 53, "Andhra Pradesh"], [56, 59, "Karnataka"], [60, 64, "Tamil Nadu"],
  [67, 69, "Kerala"], [70, 74, "West Bengal"], [75, 77, "Odisha"], [78, 78, "Assam"], [79, 79, "North East"], [80, 82, "Bihar"],
  [83, 83, "Jharkhand"], [84, 85, "Bihar"]];
function stateOf(c) {
  const g = String(c.taxId || "").toUpperCase();
  if (/^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$/.test(g) && GST_STATES[g.slice(0, 2)]) return GST_STATES[g.slice(0, 2)];
  const p = String(c.pincode || "");
  if (/^[1-9]\d{5}$/.test(p)) {
    if (p.startsWith("403")) return "Goa";
    if (p.startsWith("396") && /^3962[01]/.test(p)) return "Dadra & Nagar Haveli and Daman & Diu";
    const n = Number(p.slice(0, 2));
    const r = PIN_STATES.find(([a, b]) => n >= a && n <= b);
    if (r) return r[2];
  }
  return "";
}

function accText(key, a) {
  const c = a.cust || {};
  const lines = [];
  if (a.kind === "existing") {
    // Owner 15-Oct: LOGIN, then billing name, destination, mobile, state.
    const st = stateOf(c);
    lines.push("📱 <b>LOGIN</b>", `Billing: ${escH(a.party || c.billName || "-")}`,
      `Destination: ${escH(c.bookingPlace || "-")}`, `Mobile: ${key}`,
      ...(a.partySale != null ? [`📊 Last 6 months: ${inr(a.partySale)}`] : []),
      ...(st ? [`State: ${escH(st)}`] : []));
  }
  else {
    lines.push(...(a.kind === "foreign" ? ["🌍 Outside India"] : []),
      ...(c.contact ? [`Name: ${escH(c.contact)}`] : []), `Bill name: ${escH(c.billName || "-")}`,
      ...(c.businessType === "new_startup" || c.businessType === "existing_business" ? [`Business: ${c.businessType === "new_startup" ? "🌱 NEW STARTUP" : "🏪 OLD SAREE SHOP"}`] : []),
      ...(c.pan ? [`PAN: ${escH(c.pan)}`] : []),
      ...(c.bizNote ? [`Note: ${escH(c.bizNote)}`] : []),
      `Address: ${escH(c.address || "-")}`,
      ...(c.pincode ? [`Pincode: ${escH(c.pincode)}`] : []),
      `Destination: ${escH(c.bookingPlace || "-")}${c.country && c.country !== "India" ? " · " + escH(c.country) : ""}`,
      ...(c.transport ? [`Transport: ${escH(c.transport)}${c.transportTyped ? ` (typed: ${escH(c.transportTyped)})` : ""}`] : []),
      ...(c.taxId ? [`${(c.kycDoc || "ID").toUpperCase()}: ${escH(c.kycDoc === "aadhaar" ? "XXXX XXXX " + String(c.taxId).slice(-4) : c.taxId)}`] : []),
      `Mobile: ${key} ${a.abroadDirect ? "(outside India — typed, not verified)" : "(WhatsApp verified)"}`,
      ...kycLines(a, c));
  }
  if (a.loc) lines.push(`📍 Location: shared (map below)${a.loc.acc ? " · ±" + a.loc.acc + " m" : ""}`);
  else if (a.locIp !== undefined) lines.push(`📍 Location: NOT shared${a.locIp ? " · internet shows ~" + escH(a.locIp) : ""}`);
  const st = { approved: "✅ APPROVED", pending: "⏳ waiting for approval", declined: "❌ DECLINED", blocked: "🚫 BLOCKED" }[a.status] || a.status;
  lines.push("", `<b>${st}</b>`);
  // Owner 15-Oct: no times (Telegram shows them); a plain login needs no log line.
  for (const e of (a.log || []).slice(-4)) {
    if (a.kind === "existing" && /logged in$/.test(e.a)) continue;
    lines.push(e.by && e.by !== "app" ? `${e.a} — ${escH(e.by)}` : e.a);
  }
  return lines.join("\n");
}

async function accPost(db, key, endLine = false) {
  const chat = await approvalsChat(db);
  if (!chat) return;
  const a = (await db.collection("bbapp_accounts").doc(key).get()).data() || {};
  const r = await tg("sendMessage", { chat_id: chat, text: accText(key, a), parse_mode: "HTML", reply_markup: accKeyboard(key, a.status) });
  if (r.ok) await db.collection("bbapp_accounts").doc(key).set({ msg: { chat, id: r.result.message_id } }, { merge: true });
  if (r.ok && a.loc && a.locNew) {
    await tg("sendLocation", { chat_id: chat, latitude: a.loc.lat, longitude: a.loc.lng, reply_to_message_id: r.result.message_id, disable_notification: true });
    await db.collection("bbapp_accounts").doc(key).set({ locNew: false }, { merge: true });
  }
  // Owner 15-Oct: dotted line between two app messages.
  if (endLine) await tg("sendMessage", { chat_id: chat, text: "• • • • • • • • • •", disable_notification: true });
}

async function accountTap(db, q, act, key) {
  key = accKey(key);
  const docRef = db.collection("bbapp_accounts").doc(String(key));
  const by = [q.from && q.from.first_name, q.from && q.from.last_name].filter(Boolean).join(" ") || "staff";
  const to = { ok: "approved", no: "declined", blk: "blocked", unb: "approved", wait: "pending" }[act];
  const a = (await docRef.get()).data();
  if (!a || !to) {
    await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Not found." });
    return;
  }
  await docRef.set({ status: to, held: act === "wait", ...(act === "ok" ? { approvedAt: Date.now(), approvedBy: by } : {}),
    log: admin.firestore.FieldValue.arrayUnion({ a: { ok: "✅ approved", no: "❌ declined", blk: "🚫 blocked", unb: "↩️ unblocked", wait: "⏳ put on waiting" }[act], by, at: Date.now() }) },
  { merge: true });
  await tg("answerCallbackQuery", { callback_query_id: q.id, text: `${to} — ${key}` });
  const fresh = (await docRef.get()).data() || {};
  if (q.message) {
    await tg("editMessageText", { chat_id: q.message.chat.id, message_id: q.message.message_id,
      text: accText(key, fresh), parse_mode: "HTML", reply_markup: accKeyboard(key, fresh.status) });
  }
  if (act === "ok") await pushTo(db, key, "✅ Your B.B Synthetics account is approved — now you can open the app and start ordering.");
  // Owner 14-Oct: the PAN / Aadhaar photo is only kept until the decision.
  if ((act === "ok" || act === "no") && fresh.kycPath) {
    await admin.storage().bucket().file(fresh.kycPath).delete().catch(() => {});
    await docRef.set({ kycPath: null }, { merge: true });
  }
  // Owner 15-Oct: the ID photos leave the group after the decision.
  if ((act === "ok" || act === "no") && (fresh.idMsgs || []).length) {
    for (const x of fresh.idMsgs) await tg("deleteMessage", { chat_id: x.chat, message_id: x.id }).catch(() => {});
    await docRef.set({ idMsgs: [] }, { merge: true });
  }
  // The proof video already sits in the group; the cloud copy goes after the decision.
  if ((act === "ok" || act === "no") && fresh.proofVideo) {
    await admin.storage().bucket().file(fresh.proofVideo).delete().catch(() => {});
    await docRef.set({ proofVideo: null }, { merge: true });
  }
}

/** Read a WhatsApp verification (≤ 20 min old) → the verified key. */
async function verifiedKey(db, code) {
  const c = String(code || "").replace(/\D/g, "");
  if (c.length !== 6) return null;
  const v = (await db.collection("bbapp_verify").doc(c).get()).data();
  if (!v || !v.from || Date.now() - Number(v.at || 0) > 20 * 60e3) return null;
  return accKey(v.from);
}

/** Owner 14-Oct: a fresh live Tally answer (shop PC) beats the saved list. */
async function partiesLive(db, key) {
  const lk = (await db.collection("bbapp_lookup").doc(key).get()).data();
  if (lk && lk.ok && lk.done && Date.now() - lk.done < 30 * 60e3) return lk.parties || [];
  return null;
}

async function partiesFor(key, db) {
  if (db) {
    const live = await partiesLive(db, key);
    if (live) return live;
  }
  return partiesSaved(key);
}

function partiesSaved(key) {
  try {
    if (!PARTIES) PARTIES = require("./parties.json");
  } catch (e) {
    return [];
  }
  return (PARTIES[key] || []).map((x) => ({ name: x.name, address: x.address || "", dest: x.dest || "",
    pincode: x.pincode || "", gstin: x.gstin || "", transport: x.transport || "" })).filter((x) => x.name);
}

/** App: poll after "Verify on WhatsApp" — who is this number? */
exports.accountVerify = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("v:" + ip)) return res.status(429).json({ ok: false });
    const db = admin.firestore();
    const key = await verifiedKey(db, req.body && req.body.code);
    if (!key) return res.json({ ok: true, verified: false });
    let a = (await db.collection("bbapp_accounts").doc(key).get()).data();
    const india = key.length === 10;
    let parties = null;
    if (india) {
      // Owner 14-Oct: ask Tally live (shop PC). The app keeps polling while
      // we wait (verified:false), at most ~12 s, then the saved list.
      const lref = db.collection("bbapp_lookup").doc(key);
      const lk = (await lref.get()).data() || {};
      const hb = ((await db.collection("bbapp_settings").doc("lookup").get()).data() || {}).at || 0;
      const pcUp = Date.now() - hb < 90e3;
      const fresh = lk.req && Date.now() - lk.req < 3 * 60e3;
      if (!fresh) {
        if (pcUp) {
          await lref.set({ req: Date.now(), done: null, ok: null, parties: [] });
          return res.json({ ok: true, verified: false, checking: true });
        }
      } else if (!lk.done && pcUp && Date.now() - lk.req < 12e3) {
        return res.json({ ok: true, verified: false, checking: true });
      }
      let live = lk.done && lk.ok && fresh ? (lk.parties || []) : null;
      // Owner 16-Oct: a busy / company-less Tally answers "nothing" — never let
      // an empty live answer hide a party the saved list knows (Renu Sharma).
      const saved = partiesSaved(key);
      if (live && !live.length && saved.length) live = null;
      parties = live || saved;
      if (live && a && a.status === "approved") {
        const linked = a.kind === "existing" && live.some((p) => p.name === a.party);
        if (a.kind === "existing" && !linked) {
          // The number left that party in Tally -> link again / sign up.
          await db.collection("bbapp_accounts").doc(key).set({ status: "none", kind: null, party: null,
            log: admin.firestore.FieldValue.arrayUnion({ a: `↩️ number no longer in ${a.party} (Tally) — asked again`, by: "bot", at: Date.now() }) }, { merge: true });
          a = { ...a, status: "none", kind: null, party: null };
        } else if (a.kind === "new" && live.length) {
          // The shop made / found a ledger with this number -> pick it.
          a = { ...a, status: "none" };
        }
      }
      // A customer the owner put on Waiting / declined stays there.
      if (live && a && a.status === "pending" && live.length && !a.held) a = { ...a, status: "none" };
    }
    const devKey = a ? await giveDevKey(db, key, a) : null; // new numbers get it at sign-up
    return res.json({ ok: true, verified: true, mobile: key, india, devKey, status: (a && a.status) || "none",
      kind: (a && a.kind) || null, party: (a && a.party) || null, cust: (a && a.cust) || null,
      parties: india ? (parties || []) : [] });
  },
);

/** App: an existing Tally customer picks their party → approved at once. */
exports.accountClaim = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    const key = await verifiedKey(db, req.body && req.body.code);
    if (!key) return res.json({ ok: false, error: "Please verify your number on WhatsApp again." });
    const name = String((req.body && req.body.party) || "");
    const hit = (await partiesFor(key, db)).find((x) => x.name === name);
    if (!hit) return res.json({ ok: false, error: "This party is not on this number." });
    const ref = db.collection("bbapp_accounts").doc(key);
    const cur = (await ref.get()).data();
    if (cur && cur.status === "blocked") return res.json({ ok: true, status: "blocked" });
    // Owner's decision stands: Waiting (held) or declined cannot self-approve.
    if (cur && (cur.held || cur.status === "declined")) {
      await ref.set({ partySale: await partySale(db, hit.name) }, { merge: true });
      await ref.set({ kind: "existing", party: hit.name, log: admin.firestore.FieldValue.arrayUnion({ a: `📱 logged in again (${cur.held ? "on waiting" : "declined"})`, by: "app", at: Date.now() }) }, { merge: true });
      await saveLoc(ref, req, req.body && req.body.loc);
      await accPost(db, key, true);
      return res.json({ ok: true, status: cur.held ? "pending" : "declined" });
    }
    await ref.set({ partySale: await partySale(db, hit.name) }, { merge: true });
    await ref.set({ status: "approved", kind: "existing", party: hit.name, cust: { billName: hit.name, address: hit.address,
      pincode: hit.pincode, bookingPlace: hit.dest, transport: hit.transport, taxId: hit.gstin, mobile: key, country: "India", kind: "old" },
    verifiedAt: Date.now(), log: admin.firestore.FieldValue.arrayUnion({ a: "📱 logged in", by: "app", at: Date.now() }) }, { merge: true });
    await saveLoc(ref, req, req.body && req.body.loc);
    await accPost(db, key, true);
    return res.json({ ok: true, status: "approved", devKey: await giveDevKey(db, key, null) });
  },
);

/** App: a new customer's details → pending (India) / approved (abroad). */
exports.accountSignup = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 120, memory: "512MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    let key = await verifiedKey(db, req.body && req.body.code);
    let abroadDirect = false;
    if (!key && req.body && req.body.abroad) {
      // Owner 14-Oct: customer abroad — no WhatsApp login, approved at once,
      // but only from a network outside India and with a non-Indian number.
      const k = accKey(req.body.mobile);
      if (!k || k.length === 10) return res.json({ ok: false, error: "Indian numbers log in with WhatsApp." });
      const cc = await ipCountry(req);
      if (cc !== "ABROAD") {
        return res.json({ ok: false, error: cc === "IN" ? "You are in India — please log in with WhatsApp." : "Could not check your location — please log in with WhatsApp." });
      }
      key = k;
      abroadDirect = true;
    }
    if (!key) return res.json({ ok: false, error: "Please verify your number on WhatsApp again." });
    const c = (req.body && req.body.cust) || {};
    const cust = Object.fromEntries(["contact", "billName", "address", "pincode", "bookingPlace", "transport", "taxId", "country", "kycDoc", "businessType", "pan", "bizNote"]
      .map((k) => [k, String(c[k] || "").trim().slice(0, 300)]));
    // Security (14-Oct): an Indian number is ALWAYS India — the chosen
    // country can never skip the ID checks.
    if (key.length === 10) cust.country = "India";
    if (abroadDirect && cust.country === "India") cust.country = "Other";
    cust.country = cust.country || "India";
    cust.mobile = key;
    cust.kind = "new";
    const india = cust.country === "India";
    if (!cust.billName || !cust.address || !cust.bookingPlace) return res.json({ ok: false, error: "Please fill bill name, address and destination." });
    if (india && (!cust.pincode || !cust.transport || !cust.taxId)) {
      return res.json({ ok: false, error: "Please fill pincode, transport and GST / PAN / Aadhaar." });
    }
    // Owner 16-Oct: "MOHIT" -> our transporter "MOHIT TRANSPORT CORPORATION".
    let trWarn = null;
    if (india) {
      try { if (!NPCHECK) NPCHECK = require("./newparty_check.json"); } catch (e) { /* no list */ }
      const list = (NPCHECK && NPCHECK.transports) || [];
      const T = npNorm(cust.transport);
      if (list.includes(T)) cust.transport = T;
      else if (list.length) {
        const hit = list.filter((x) => x.startsWith(T + " ") || x.split(" ")[0] === T);
        if (hit.length === 1) { cust.transportTyped = T; cust.transport = hit[0]; }
        else {
          const sug = nearest(T, list, 3);
          trWarn = `⚠️ Transport "${T}" is not in our list${sug.length ? " — maybe " + sug.join(" / ") : ""}`;
        }
      }
    }
    const ref = db.collection("bbapp_accounts").doc(key);
    const cur = (await ref.get()).data();
    if (abroadDirect && cur) return res.json({ ok: false, error: "This number already has an account — please log in with WhatsApp." });
    if (cur && cur.status === "blocked") return res.json({ ok: true, status: "blocked" });
    if (cur && cur.status === "approved") return res.json({ ok: true, status: "approved" });
    // Owner 14-Oct: PAN / Aadhaar need their photo; GST only the number.
    const doc = (cust.kycDoc || (/^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$/i.test(cust.taxId) ? "gst"
      : /^[A-Z]{5}\d{4}[A-Z]$/i.test(cust.taxId) ? "pan" : "aadhaar")).toLowerCase();
    const img = String((c.kycImage) || "");
    // Owner 14-Oct 10:00: PAN / Aadhaar = the card PHOTO (number read from it).
    if (india && doc !== "gst" && img.length < 1000) {
      return res.json({ ok: false, error: `Please add a photo of your ${doc === "pan" ? "PAN card" : "Aadhaar card"}.` });
    }
    const card = String(c.cardImage || "");
    // Owner 15-Oct: no GST -> Aadhaar photo + a business proof photo, both compulsory.
    if (india && doc !== "gst" && doc !== "aadhaar") {
      return res.json({ ok: false, error: "No GST? Please add a photo of your Aadhaar card." });
    }
    const proofVideo = String(c.proofVideo || "");
    let videoOk = false;
    if (/^proof\/\d{7,15}-\d+\.mp4$/.test(proofVideo) && proofVideo.startsWith(`proof/${key}-`)) {
      try { videoOk = (await admin.storage().bucket().file(proofVideo).exists())[0]; } catch (e) { videoOk = false; }
    }
    if (india && doc !== "gst" && card.length < 1000 && !videoOk) {
      return res.json({ ok: false, error: "Please add a business proof photo or video." });
    }
    if (india && !idValid(doc, cust.taxId)) {
      return res.json({ ok: false, error: `This ${doc === "gst" ? "GST" : doc === "pan" ? "PAN" : "Aadhaar"} number is not valid — please check it.` });
    }
    const kyc = india ? await kycCheck(db, cust, doc, String(c.kycText || "")) : [];
    if (trWarn) kyc.push(trWarn);
    if (india && doc === "aadhaar") {
      // Owner 15-Oct: the BACK of the Aadhaar has the address — both sides needed.
      const AT = String(c.kycText || "");
      if (!/(?<!\d)[1-9]\d{5}(?!\d)/.test(AT) && !/address/i.test(AT)) {
        kyc.push("⚠️ Aadhaar BACK side (address) not received — ask the customer for it");
      }
    }
    if (india && doc !== "gst" && card.length < 1000 && videoOk) {
      kyc.push("🎥 Business proof is a video — please watch it");
    }
    if (india && doc !== "gst" && card.length >= 1000) {
      // Owner 14-Oct: the shop card / board must carry the bill name.
      const CT = String(c.cardText || "").toUpperCase();
      const bw = String(cust.billName || "").toUpperCase().split(/[^A-Z]+/).filter((w) => w.length >= 3 && !["THE", "AND", "SAREE", "SAREES"].includes(w));
      const hit = bw.filter((w) => CT.includes(w)).length;
      kyc.push(!CT.trim() ? "ℹ️ Business proof photo has no readable text — please look at it"
        : hit >= Math.max(1, Math.ceil(bw.length / 2)) ? "✅ Bill name is on the business proof" : "ℹ️ Bill name not seen on the business proof — please look at the photo");
    }
    let kycPath = null;
    if (india && doc !== "gst" && img.length >= 1000) {
      kycPath = `kyc/${key}.jpg`;
      try {
        await admin.storage().bucket().file(kycPath).save(Buffer.from(img, "base64"), { contentType: "image/jpeg" });
      } catch (e) { logger.warn("kyc save", { key, error: e.message }); kycPath = null; }
    }
    // Owner 14-Oct: approved by the bot when no Tally customer has this
    // pincode yet, or the pincode's sales in the last 6 months are under
    // ₹5 lakh (weekly figure from the shop PC); otherwise the owner decides.
    const pin6 = String(cust.pincode).replace(/\D/g, "");
    const known = tallyPincodes().has(pin6);
    const ps = (await db.collection("bbapp_settings").doc("pinsales").get()).data() || {};
    const pinSale = Number((ps.pins || {})[pin6] || 0);
    // Owner 15-Oct: CITY-wise sales (pincode-wise was too narrow).
    const ck = cityKey(cust.bookingPlace);
    const destSale = Object.entries(ps.dests || {}).filter(([k]) => ck && k === ck)
      .reduce((t, [, v]) => t + Number(v || 0), 0);
    // Owner 14-Oct 10:00: never auto-approve unverified places — GST or an
    // Aadhaar address must confirm the details (PAN has no address).
    const clean = !kyc.some((x) => String(x).startsWith("⚠️"));
    const auto = india && destSale < 500000 && clean && (doc === "gst" || doc === "aadhaar") && (c.loc === undefined || !!validLoc(c.loc));
    const kycDocName = doc;
    const status = !india || auto ? "approved" : "pending";
    await ref.set({ status, kind: india ? "new" : "foreign", cust, kyc, kycDoc: kycDocName, abroadDirect, pinSale: india ? pinSale : null, destSale: india ? destSale : null,
      kycPath, verifiedAt: Date.now(), at: Date.now(),
      ...(auto ? { approvedAt: Date.now(), approvedBy: "bot (city sales under ₹5 lakh)" } : {}),
      log: admin.firestore.FieldValue.arrayUnion({ a: india ? "🆕 signed up" : "🌍 signed up", by: "app", at: Date.now() },
        ...(auto ? [{ a: `✅ auto-approved — ${String(cust.bookingPlace || "city").toUpperCase()} sales under ₹5 lakh`, by: "bot", at: Date.now() + 1 }] : [])) }, { merge: true });
    if (auto && kycPath) await admin.storage().bucket().file(kycPath).delete().catch(() => {});
    await saveLoc(ref, req, c.loc);
    await accPost(db, key);
    const devKey = await giveDevKey(db, key, null);
    if (india && (doc === "pan" || doc === "aadhaar" || doc === "gst")) {
      const id = doc === "gst" ? String(cust.taxId).toUpperCase().slice(2, 12) : String(cust.taxId).toUpperCase().replace(/[^A-Z0-9]/g, "");
      await db.collection("bbapp_idcheck").doc(key).set({ req: Date.now(), done: null,
        pan: doc === "aadhaar" ? "" : id, aadhaar: doc === "aadhaar" ? id : "" });
    }
    // Owner 14-Oct: an existing business without GST sends its shop card —
    // shown under the sign-up message in the group.
    if (card.length > 1000) {
      try {
        const path = `cards/${key}.jpg`;
        await admin.storage().bucket().file(path).save(Buffer.from(card, "base64"), { contentType: "image/jpeg" });
        await ref.set({ cardPath: path }, { merge: true });
        const m = ((await ref.get()).data() || {}).msg;
        if (m && m.chat) {
          const fd = new FormData();
          fd.append("chat_id", String(m.chat));
          fd.append("reply_to_message_id", String(m.id));
          fd.append("caption", `📎 Business proof — ${cust.billName}${cust.bizNote ? "\n" + cust.bizNote : ""}`);
          fd.append("photo", new Blob([Buffer.from(card, "base64")], { type: "image/jpeg" }), "card.jpg");
          await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendPhoto`, { method: "POST", body: fd });
        }
      } catch (e) { logger.warn("card photo", { key, error: e.message }); }
    }
    // Owner 15-Oct: ID photos into the group too (Aadhaar / PAN).
    for (const [b64, label] of [[img, doc === "pan" ? "PAN" : "Aadhaar"], [String(c.kycImage2 || ""), "Aadhaar (other side)"], [String(c.panImage || ""), "PAN"]]) {
      if (!india || auto || b64.length < 1000) continue; // auto-approved: nothing to decide
      try {
        const m = ((await ref.get()).data() || {}).msg;
        if (!m || !m.chat) continue;
        const fd = new FormData();
        fd.append("chat_id", String(m.chat));
        fd.append("reply_to_message_id", String(m.id));
        fd.append("caption", `🪪 ${label} — ${cust.billName} (deleted from here after approve / decline)`);
        fd.append("photo", new Blob([Buffer.from(b64, "base64")], { type: "image/jpeg" }), "id.jpg");
        const r = await (await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendPhoto`, { method: "POST", body: fd })).json();
        if (r && r.ok && r.result) {
          await ref.set({ idMsgs: admin.firestore.FieldValue.arrayUnion({ chat: m.chat, id: r.result.message_id }) }, { merge: true });
        }
      } catch (e) { logger.warn("id photo tg", { key, error: e.message }); }
    }
    if (videoOk) {
      try {
        await ref.set({ proofVideo }, { merge: true });
        const m = ((await ref.get()).data() || {}).msg;
        if (m && m.chat) {
          const [buf] = await admin.storage().bucket().file(proofVideo).download();
          const fd = new FormData();
          fd.append("chat_id", String(m.chat));
          fd.append("reply_to_message_id", String(m.id));
          fd.append("caption", `🎥 Business proof — ${cust.billName}${cust.bizNote ? "\n" + cust.bizNote : ""}`);
          fd.append("video", new Blob([buf], { type: "video/mp4" }), "proof.mp4");
          let r = await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendVideo`, { method: "POST", body: fd });
          if (!r.ok) {
            // iPhone records .mov — if Telegram refuses it as a video, send it as a file.
            logger.warn("proof video tg", { status: r.status, body: (await r.text()).slice(0, 200) });
            const fd2 = new FormData();
            fd2.append("chat_id", String(m.chat));
            fd2.append("reply_to_message_id", String(m.id));
            fd2.append("caption", `🎥 Business proof (video file) — ${cust.billName}`);
            fd2.append("document", new Blob([buf], { type: "video/quicktime" }), "proof.mov");
            r = await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendDocument`, { method: "POST", body: fd2 });
            if (!r.ok) logger.warn("proof video tg doc", { status: r.status, body: (await r.text()).slice(0, 200) });
          }
          if (auto) { // nobody will tap approve -> the cloud copy goes now
            await admin.storage().bucket().file(proofVideo).delete().catch(() => {});
            await ref.set({ proofVideo: null }, { merge: true });
          }
        }
      } catch (e) { logger.warn("proof video", { key, error: e.message }); }
    }
    // Owner 15-Oct: a dotted line after the last photo / video — this
    // customer's sign-up ends here; the next one starts below.
    try {
      const m = ((await ref.get()).data() || {}).msg;
      if (m && m.chat) {
        await fetch(`https://api.telegram.org/bot${TG_TOKEN.value()}/sendMessage`, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ chat_id: m.chat, text: "• • • • • • • • • •", disable_notification: true }),
        });
      }
    } catch (e) { logger.warn("signup end line", { key, error: e.message }); }
    return res.json({ ok: true, status, devKey });
  },
);

/** App: on every open — still allowed? */
exports.accountStatus = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const key = accKey(req.body && req.body.mobile);
    if (!key) return res.status(400).json({ ok: false });
    const ref = admin.firestore().collection("bbapp_accounts").doc(key);
    const a = (await ref.get()).data();
    // Owner 14-Oct: every app open is counted (Google Sheet: who looks, who orders).
    if (a) {
      await ref.set({ opens: admin.firestore.FieldValue.increment(1), lastOpen: Date.now(),
        ...(String(a.lastOpenDay || "") !== new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10)
          ? { openDays: admin.firestore.FieldValue.increment(1), lastOpenDay: new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10) } : {}) },
      { merge: true });
    }
    return res.json({ ok: true, status: (a && a.status) || "none", kind: (a && a.kind) || null,
      party: (a && a.party) || null, cust: (a && a.cust) || null });
  },
);


/** Pincodes of existing Tally customers (parties.json, Sundry Debtors). */
let PINSET = null;
function tallyPincodes() {
  if (PINSET) return PINSET;
  PINSET = new Set();
  try {
    if (!PARTIES) PARTIES = require("./parties.json");
    for (const list of Object.values(PARTIES)) {
      for (const x of list || []) {
        const pin = String((x && x.pincode) || "").replace(/\D/g, "");
        if (pin.length === 6) PINSET.add(pin);
      }
    }
  } catch (e) { logger.warn("pincodes", { error: e.message }); }
  return PINSET;
}

/** Owner 14-Oct: cross-check the ID against what the customer typed.
 *  Returns short lines for the approvals group ("✅ …" / "⚠️ …"). */
async function kycCheck(db, cust, doc, text) {
  const out = [];
  const T = String(text || "").toUpperCase();
  const flat = T.replace(/[^A-Z0-9]/g, "");
  const words = (x) => String(x || "").toUpperCase().split(/[^A-Z]+/).filter((w) => w.length >= 3);
  const nameHit = (name) => {
    const w = words(name);
    if (!w.length) return null;
    const hit = w.filter((x) => T.includes(x)).length;
    return hit / w.length;
  };
  const pin = String(cust.pincode || "").replace(/\D/g, "");
  const city = String(cust.bookingPlace || "").toUpperCase().trim();
  if (doc === "gst") {
    const g = String(cust.taxId || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    const c = (await db.collection("bbapp_gst").doc(g).get()).data();
    const info = c && c.info;
    if (!info) return ["⚠️ GST could not be verified on the GST portal"];
    out.push(`✅ GST verified: ${info.tradeName || info.legalName || "-"}${info.status ? " (" + info.status + ")" : ""}`);
    const n = Math.max(nameHit(info.tradeName) || 0, nameHit(info.legalName) || 0);
    const bill = words(cust.billName);
    const billHit = bill.filter((x) => `${info.tradeName || ""} ${info.legalName || ""}`.toUpperCase().includes(x)).length;
    out.push(billHit >= Math.max(1, Math.ceil(bill.length / 2)) || n >= 0.5 ? "✅ Bill name matches the GST name" : `⚠️ Bill name "${cust.billName}" ≠ GST name`);
    if (info.pin) out.push(String(info.pin) === pin ? "✅ Pincode matches the GST address" : `⚠️ Pincode ${pin} ≠ GST address ${info.pin}`);
    return out;
  }
  if (!T || T.length < 20) return [`⚠️ The ${doc === "pan" ? "PAN" : "Aadhaar"} photo could not be read — please look at it`];
  if (doc === "pan") {
    const pan = String(cust.taxId || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    out.push(flat.includes(pan) ? "✅ PAN number matches the photo" : "⚠️ PAN number NOT found on the photo");
  } else {
    const last4 = String(cust.taxId || "").replace(/\D/g, "").slice(-4);
    out.push(last4 && T.replace(/\D/g, "").includes(String(cust.taxId || "").replace(/\D/g, ""))
      ? "✅ Aadhaar number matches the photo"
      : (last4 && T.includes(last4) ? "✅ Aadhaar last 4 digits match the photo" : "⚠️ Aadhaar number NOT found on the photo"));
    const f = cardFacts(text);
    if (pin) {
      out.push(T.replace(/\D/g, " ").split(/\s+/).includes(pin) ? "✅ Pincode matches the Aadhaar address"
        : `⚠️ Pincode ${pin} not on the Aadhaar — Aadhaar shows ${f.pin || "no readable pincode"}`);
    }
    if (city) {
      out.push(T.includes(city) ? `✅ City ${city} is on the Aadhaar`
        : `⚠️ City ${city} not on the Aadhaar — Aadhaar address: ${f.addr || "not readable"}`);
    }
  }
  if (cust.contact || doc === "pan") {
    const n = Math.max(nameHit(cust.contact) || 0, nameHit(cust.billName) || 0);
    out.push(n >= 0.5 ? "✅ Name matches the card" : "⚠️ Name on the card does not match the name typed");
  }
  if (doc === "pan") out.push("ℹ️ PAN has no address — place not checked");
  const nm = cardFacts(text).name;
  out.push(`🪪 Name on ${doc === "pan" ? "PAN" : "Aadhaar"}: ${nm || (doc === "pan" ? "not readable on the photo" : "not on this side of the card")}`);
  return out;
}


/** Owner 14-Oct: the Google Sheet (Apps Script, PC key) — every account with
 *  its usage; and bulk block / unblock from the sheet. */
exports.accountsList = onRequest(
  { region: "asia-south1", secrets: [PC_KEY], timeoutSeconds: 60, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    const b = req.body || {};
    if (Array.isArray(b.block) || Array.isArray(b.unblock)) {
      const by = String(b.by || "Google Sheet").slice(0, 40);
      const done = [];
      for (const [list, st] of [[b.block || [], "blocked"], [b.unblock || [], "approved"]]) {
        for (const raw of list.slice(0, 500)) {
          const k = accKey(raw);
          if (!k) continue;
          await db.collection("bbapp_accounts").doc(k).set({ status: st,
            log: admin.firestore.FieldValue.arrayUnion({ a: st === "blocked" ? "🚫 blocked (sheet)" : "↩️ unblocked (sheet)", by, at: Date.now() }) },
          { merge: true });
          done.push(k);
        }
      }
      return res.json({ ok: true, changed: done.length });
    }
    const snap = await db.collection("bbapp_accounts").get();
    const rows = snap.docs.map((x) => {
      const a = x.data();
      const c = a.cust || {};
      return { mobile: x.id, party: a.party || c.billName || "", city: c.bookingPlace || "", pincode: c.pincode || "",
        country: c.country || "India", kind: a.kind || "", status: a.status || "", signedUp: a.at || a.verifiedAt || null,
        approvedBy: a.approvedBy || "", opens: a.opens || 0, openDays: a.openDays || 0, lastOpen: a.lastOpen || null,
        orders: a.orders || 0, lastOrderAt: a.lastOrderAt || null };
    });
    return res.json({ ok: true, rows });
  },
);


/** Shop PC (pincode_sales.py, weekly): sales per pincode, last 6 months. */
exports.pinSalesUpload = onRequest(
  { region: "asia-south1", secrets: [PC_KEY], timeoutSeconds: 60, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const pins = (req.body && req.body.pins) || {};
    const clean = {};
    for (const [k, v] of Object.entries(pins)) if (/^\d{6}$/.test(k)) clean[k] = Math.round(Number(v) || 0);
    const dests = {};
    for (const [k, v] of Object.entries((req.body && req.body.dests) || {})) if (/^[A-Z0-9]{2,40}$/.test(k)) dests[k] = Math.round(Number(v) || 0);
    await admin.firestore().collection("bbapp_settings").doc("pinsales").set({ pins: clean, dests,
      since: String((req.body && req.body.since) || ""), at: Date.now() });
    // Owner 15-Oct: party-wise 6-month sales (shown on the LOGIN message).
    const parties = {};
    for (const [k, v] of Object.entries((req.body && req.body.parties) || {})) {
      const name = String(k).trim().toUpperCase().slice(0, 200);
      if (name) parties[name] = Math.round(Number(v) || 0);
    }
    if (Object.keys(parties).length) {
      await admin.firestore().collection("bbapp_settings").doc("partysales").set({ sales: parties,
        since: String((req.body && req.body.since) || ""), at: Date.now() });
    }
    return res.json({ ok: true, pins: Object.keys(clean).length });
  },
);


/** Owner 14-Oct: "✅ GST verified" when everything matches; else only the ⚠️
 *  lines. Then "<DESTINATION> ₹<6-month sales of that pincode>". */
function kycLines(a, c) {
  const out = [""];
  const warn = (a.kyc || []).filter((x) => String(x).startsWith("⚠️"));
  const doc = String(a.kycDoc || c.kycDoc || "").toUpperCase();
  if (a.kind !== "foreign") {
    const info = (a.kyc || []).filter((x) => String(x).startsWith("🪪") || String(x).startsWith("🎥"));
    if (warn.length) out.push(...warn.map((x) => escH(x)));
    else if (doc) out.push(`✅ ${doc === "AADHAAR" ? "Aadhaar" : doc} verified`);
    out.push(...info.map((x) => escH(x)));
    if (a.destSale != null) out.push(`📊 ${escH(String(c.bookingPlace || "").toUpperCase())} sales last 6 months: ${inr(a.destSale)}`);
    else if (a.pinSale != null) out.push(`📊 Pincode sales last 6 months: ${inr(a.pinSale)}`);
  }
  return out;
}


/** Owner 14-Oct: every day 9 PM — "New designs are in — check DAILY UPDATE",
 *  ONLY to approved accounts (never pending / declined / blocked). */
exports.dailyDesignPush = onSchedule(
  { region: "asia-south1", schedule: "0 21 * * *", timeZone: "Asia/Kolkata", secrets: [APNS_KEY], timeoutSeconds: 300, memory: "256MiB" },
  async () => {
    const db = admin.firestore();
    // Owner 15-Oct: tell how many designs came today (Daily Update history);
    // no push on a day with nothing new.
    let today = 0;
    try {
      const f = await (await fetch(`https://aknzone-afk.github.io/akn-zone-data/app/daily-feed.json?t=${Date.now()}`)).json();
      const ymd = new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10);
      today = ((f.days || []).find((x) => x.d === ymd) || { items: [] }).items.length;
    } catch (e) { logger.warn("daily feed", { error: e.message }); today = -1; }
    if (today === 0) { logger.info("daily design push: nothing new today"); return; }
    const text = today > 0 ? `🆕 ${today} new design${today === 1 ? "" : "s"} today — tap to see DAILY UPDATE` : "🆕 New designs are in — check DAILY UPDATE";
    const snap = await db.collection("bbapp_accounts").where("status", "==", "approved").get();
    let n = 0;
    for (const d of snap.docs) {
      await pushTo(db, d.id, text, "daily");
      n++;
    }
    logger.info("daily design push", { accounts: n });
  },
);


/* ---------- Owner 14-Oct: Google Sheet "AKN Zone app customers" ---------- */
const SHEET_HEAD = ["Mobile", "Party / bill name", "City", "Pincode", "Status", "Signed up", "Approved by",
  "App opens", "Days opened", "Last open", "Orders", "Last order", "Inactive days", "Action (type BLOCK / UNBLOCK)"];

async function sheetToken() {
  const r = await fetch("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token?scopes=https://www.googleapis.com/auth/spreadsheets,https://www.googleapis.com/auth/drive.metadata.readonly",
    { headers: { "Metadata-Flavor": "Google" } });
  return (await r.json()).access_token;
}

async function sheetApi(tok, id, path, method = "GET", body) {
  const r = await fetch(`https://sheets.googleapis.com/v4/spreadsheets/${id}${path}`, { method,
    headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`sheets ${r.status} ${JSON.stringify(j).slice(0, 200)}`);
  return j;
}

const istDate = (ms) => ms ? new Date(ms + 19800000).toISOString().slice(0, 16).replace("T", " ") : "";
const lastActive = (a) => Math.max(a.lastOpen || 0, a.lastOrderAt || 0, a.at || a.verifiedAt || 0);

async function setAccStatus(db, key, st, by) {
  await db.collection("bbapp_accounts").doc(key).set({ status: st,
    log: admin.firestore.FieldValue.arrayUnion({ a: st === "blocked" ? "🚫 blocked (sheet)" : "↩️ unblocked (sheet)", by, at: Date.now() }) },
  { merge: true });
}

exports.sheetSync = onSchedule(
  { region: "asia-south1", schedule: "every 15 minutes", timeZone: "Asia/Kolkata", secrets: [TG_TOKEN], timeoutSeconds: 120, memory: "256MiB" },
  async () => {
    const db = admin.firestore();
    const cfgRef = db.collection("bbapp_settings").doc("sheet");
    let cfg = (await cfgRef.get()).data() || {};
    const tok = await sheetToken();
    // Adopt the newest sheet named "AKN Zone…" that someone shared with us.
    try {
      const q = encodeURIComponent("mimeType='application/vnd.google-apps.spreadsheet' and name contains 'AKN Zone' and trashed=false");
      const r = await fetch(`https://www.googleapis.com/drive/v3/files?q=${q}&orderBy=createdTime desc&pageSize=5&fields=files(id,name,createdTime)`,
        { headers: { Authorization: `Bearer ${tok}` } });
      const f = ((await r.json()).files || [])[0];
      if (f && f.id !== cfg.id) {
        await cfgRef.set({ id: f.id, name: f.name, styled: false, adoptedAt: Date.now(), prev: cfg.id || null }, { merge: true });
        cfg = { ...cfg, id: f.id, styled: false };
        logger.info("sheet adopted", { name: f.name });
      }
    } catch (e) { logger.warn("sheet adopt", { error: e.message }); }
    if (!cfg.id) return;
    const meta = await sheetApi(tok, cfg.id, "?fields=sheets.properties");
    const tab = meta.sheets[0].properties;
    const range = encodeURIComponent(`'${tab.title}'!A1:N2000`);
    const cur = (await sheetApi(tok, cfg.id, `/values/${range}`)).values || [];

    // 1. Row actions typed by the owner.
    for (const row of cur.slice(3)) {
      const act = String(row[13] || "").trim().toUpperCase();
      const key = accKey(row[0]);
      if (!key || !act) continue;
      const a = (await db.collection("bbapp_accounts").doc(key).get()).data();
      if (!a) continue;
      if (act.startsWith("BLOCK") && a.status !== "blocked") await setAccStatus(db, key, "blocked", "Sheet");
      if (act.startsWith("UNBLOCK") && a.status === "blocked") await setAccStatus(db, key, "approved", "Sheet");
    }

    const snap = await db.collection("bbapp_accounts").get();
    const accs = snap.docs.map((d) => ({ key: d.id, ...d.data() }));

    // 2. "Block inactive N months" (B1) → confirm in the approvals group.
    const months = Number(String((cur[0] || [])[1] || "").replace(/[^\d.]/g, ""));
    let note = "";
    if (months >= 1) {
      const cut = Date.now() - months * 30.4 * 86400000;
      const list = accs.filter((a) => a.status === "approved" && lastActive(a) < cut);
      const chat = await approvalsChat(db);
      if (!list.length) note = `Nobody inactive for ${months} months.`;
      else if (!chat) note = "Approvals group not connected.";
      else {
        const id = String(Date.now());
        await db.collection("bbapp_settings").doc("sheetblock").set({ id, months, keys: list.map((a) => a.key), at: Date.now() });
        const names = list.slice(0, 40).map((a) => `• ${escH(a.party || (a.cust || {}).billName || a.key)} (${a.key})`).join("\n");
        await tg("sendMessage", { chat_id: chat, parse_mode: "HTML",
          text: `📋 Sheet: block ${list.length} customers inactive ${months}+ months?\n${names}${list.length > 40 ? "\n…" : ""}`,
          reply_markup: { inline_keyboard: [[{ text: `🚫 Block ${list.length}`, callback_data: `sb|ok|${id}` }, { text: "❌ Cancel", callback_data: `sb|no|${id}` }]] } });
        note = `Asked in "Akn zone app" group: block ${list.length}?`;
      }
    }

    // 3. Rewrite the sheet.
    const now = Date.now();
    accs.sort((x, y) => lastActive(y) - lastActive(x));
    const rows = accs.map((a) => {
      const c = a.cust || {};
      const la = lastActive(a);
      return [a.key, a.party || c.billName || "", c.bookingPlace || "", String(c.pincode || ""), String(a.status || "").toUpperCase(),
        istDate(a.at || a.verifiedAt), a.approvedBy || "", a.opens || 0, a.openDays || 0, istDate(a.lastOpen), a.orders || 0,
        istDate(a.lastOrderAt), la ? Math.floor((now - la) / 86400000) : "", ""];
    });
    const values = [
      ["BLOCK INACTIVE (type months) →", "", note || "Type e.g. 6 in B1 — a ✅/❌ question comes in the Akn zone app group.", "", "", "", "", "", "", "", "", "", "Updated", istDate(now)],
      [],
      SHEET_HEAD,
      ...rows,
    ];
    await sheetApi(tok, cfg.id, `/values/${range}:clear`, "POST", {});
    await sheetApi(tok, cfg.id, `/values/${encodeURIComponent(`'${tab.title}'!A1`)}?valueInputOption=RAW`, "PUT", { values });
    if (!cfg.styled) {
      await sheetApi(tok, cfg.id, ":batchUpdate", "POST", { requests: [
        { updateSheetProperties: { properties: { sheetId: tab.sheetId, title: "App customers", gridProperties: { frozenRowCount: 3 } }, fields: "title,gridProperties.frozenRowCount" } },
        { repeatCell: { range: { sheetId: tab.sheetId, startRowIndex: 2, endRowIndex: 3 }, cell: { userEnteredFormat: { textFormat: { bold: true }, backgroundColor: { red: 0.95, green: 0.9, blue: 0.82 } } }, fields: "userEnteredFormat(textFormat,backgroundColor)" } },
        { repeatCell: { range: { sheetId: tab.sheetId, startRowIndex: 0, endRowIndex: 1, startColumnIndex: 0, endColumnIndex: 2 }, cell: { userEnteredFormat: { textFormat: { bold: true }, backgroundColor: { red: 1, green: 0.96, blue: 0.8 } } }, fields: "userEnteredFormat(textFormat,backgroundColor)" } },
        { autoResizeDimensions: { dimensions: { sheetId: tab.sheetId, dimension: "COLUMNS", startIndex: 0, endIndex: 14 } } },
      ] });
      await db.collection("bbapp_settings").doc("sheet").set({ styled: true }, { merge: true });
    }
    logger.info("sheet sync", { rows: rows.length, months });
  },
);

async function sheetBlockTap(db, q, act, id) {
  const ref = db.collection("bbapp_settings").doc("sheetblock");
  const p = (await ref.get()).data();
  if (!p || p.id !== id || p.done) {
    await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Already handled." });
    return;
  }
  const by = [q.from && q.from.first_name, q.from && q.from.last_name].filter(Boolean).join(" ") || "staff";
  let n = 0;
  if (act === "ok") {
    for (const k of p.keys || []) {
      const a = (await db.collection("bbapp_accounts").doc(k).get()).data();
      if (a && a.status === "approved") { await setAccStatus(db, k, "blocked", `${by} (sheet, ${p.months}m inactive)`); n++; }
    }
  }
  await ref.set({ done: true, act, by, n }, { merge: true });
  await tg("answerCallbackQuery", { callback_query_id: q.id, text: act === "ok" ? `Blocked ${n}` : "Cancelled" });
  if (q.message) {
    await tg("editMessageText", { chat_id: q.message.chat.id, message_id: q.message.message_id,
      text: act === "ok" ? `🚫 Blocked ${n} inactive customers (${p.months}+ months) — ${by}` : `❌ Cancelled — ${by}` });
  }
}


/* Owner 14-Oct: shape checks for GST / PAN / Aadhaar numbers. */
const GST_CH = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
function idGstOk(g) {
  g = String(g || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (!/^\d{2}[A-Z]{3}[PCHFATBLJG][A-Z]\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(g)) return false;
  const st = Number(g.slice(0, 2));
  if (!((st >= 1 && st <= 38) || st === 97 || st === 99)) return false;
  let sum = 0;
  for (let i = 0; i < 14; i++) {
    const v = GST_CH.indexOf(g[i]) * (i % 2 ? 2 : 1);
    sum += Math.floor(v / 36) + (v % 36);
  }
  return GST_CH[(36 - (sum % 36)) % 36] === g[14];
}
const idPanOk = (p) => /^[A-Z]{3}[PCHFATBLJG][A-Z]\d{4}[A-Z]$/.test(String(p || "").toUpperCase().replace(/[^A-Z0-9]/g, ""));
const VD = [[0,1,2,3,4,5,6,7,8,9],[1,2,3,4,0,6,7,8,9,5],[2,3,4,0,1,7,8,9,5,6],[3,4,0,1,2,8,9,5,6,7],[4,0,1,2,3,9,5,6,7,8],
  [5,9,8,7,6,0,4,3,2,1],[6,5,9,8,7,1,0,4,3,2],[7,6,5,9,8,2,1,0,4,3],[8,7,6,5,9,3,2,1,0,4],[9,8,7,6,5,4,3,2,1,0]];
const VP = [[0,1,2,3,4,5,6,7,8,9],[1,5,7,6,2,8,3,0,9,4],[5,8,0,3,7,9,6,1,4,2],[8,9,1,6,0,4,3,5,2,7],[9,4,5,3,1,2,6,8,7,0],
  [4,2,8,6,5,7,3,9,0,1],[2,7,9,3,8,0,6,4,1,5],[7,0,4,6,9,1,3,2,5,8]];
function idAadhaarOk(a) {
  a = String(a || "").replace(/\D/g, "");
  if (!/^[2-9]\d{11}$/.test(a)) return false;
  let c = 0;
  a.split("").reverse().forEach((d, i) => { c = VD[c][VP[i % 8][Number(d)]]; });
  return c === 0;
}
function idValid(doc, id) {
  return doc === "gst" ? idGstOk(id) : doc === "pan" ? idPanOk(id) : idAadhaarOk(id);
}


/** Owner 15-Oct: the party's sales over the last 6 months (PC upload, daily). */
async function partySale(db, name) {
  try {
    const d = (await db.collection("bbapp_settings").doc("partysales").get()).data();
    if (!d || !d.sales) return null;
    return Number(d.sales[String(name || "").trim().toUpperCase()] || 0);
  } catch (e) { return null; }
}

/** Owner 15-Oct: the shop's location (phone GPS, optional). Not shared ->
 *  the city the internet connection shows (approximate). */
function validLoc(l) {
  const lat = Number(l && l.lat), lng = Number(l && l.lng);
  if (!isFinite(lat) || !isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) return null;
  return { lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6, acc: Math.max(0, Math.min(99999, Math.round(Number(l.acc) || 0))) };
}
async function saveLoc(ref, req, raw) {
  if (raw === undefined || raw === null) return; // older app: never asked
  const loc = validLoc(raw);
  if (loc) return ref.set({ loc: { ...loc, at: Date.now() }, locNew: true, locIp: admin.firestore.FieldValue.delete() }, { merge: true });
  let city = "";
  const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
  try {
    const j = await (await fetch(`https://ipwho.is/${encodeURIComponent(ip)}?fields=success,city,region`, { signal: AbortSignal.timeout(5000) })).json();
    if (j && j.success) city = [j.city, j.region].filter(Boolean).join(", ");
  } catch (e) { /* approximate only */ }
  return ref.set({ loc: null, locNew: false, locIp: city.slice(0, 80) }, { merge: true });
}

/** Owner 14-Oct: is the caller's network in India? "IN" | "ABROAD" | null. */
async function ipCountry(req) {
  const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
  if (!ip) return null;
  try {
    const r = await fetch(`https://ipwho.is/${encodeURIComponent(ip)}?fields=success,country_code`, { signal: AbortSignal.timeout(6000) });
    const j = await r.json();
    if (j && j.success && j.country_code) return j.country_code === "IN" ? "IN" : "ABROAD";
  } catch (e) { logger.warn("ipCountry", { error: e.message }); }
  return null;
}


/** Store review: a key for THIS device, kept on the account (several devices ok). */
async function giveDevKey(db, key, a) {
  const k = require("crypto").randomBytes(16).toString("hex");
  await db.collection("bbapp_accounts").doc(key).set({ devKeys: admin.firestore.FieldValue.arrayUnion(k) }, { merge: true });
  return k;
}

/** App: "Delete my account" (Apple 5.1.1(v)). Needs the device key. Orders
 *  stay (bills / GST records); details, ID / card photos and keys go. */
exports.accountDelete = onRequest(
  { region: "asia-south1", secrets: [TG_TOKEN], timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    const key = accKey(req.body && req.body.mobile);
    const dk = String((req.body && req.body.devKey) || "");
    if (!key || dk.length < 16) return res.json({ ok: false, error: "Please log in again, then delete." });
    const ref = db.collection("bbapp_accounts").doc(key);
    const a = (await ref.get()).data();
    if (!a) return res.json({ ok: true, deleted: true });
    if (!(a.devKeys || []).includes(dk)) return res.json({ ok: false, error: "Please log in again, then delete." });
    for (const p of [a.kycPath, a.cardPath]) if (p) await admin.storage().bucket().file(p).delete().catch(() => {});
    const blocked = a.status === "blocked";
    await ref.delete();
    if (blocked) await ref.set({ status: "blocked", deletedAt: Date.now() }); // a block survives deletion
    const chat = await approvalsChat(db);
    if (chat) await tg("sendMessage", { chat_id: chat, text: `🗑️ ${key} (${a.party || (a.cust || {}).billName || "-"}) deleted their app account.` }).catch(() => {});
    return res.json({ ok: true, deleted: true });
  },
);


/** Shop PC (tally_lookup.py, every few seconds): numbers waiting for a live
 *  Tally check; also its heartbeat (no heartbeat -> the cloud does not wait). */
exports.lookupQueue = onRequest(
  { region: "asia-south1", secrets: [PC_KEY, TG_TOKEN], timeoutSeconds: 20, memory: "256MiB", maxInstances: 1, invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST" || !pcOk(req)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    const b = req.body || {};
    for (const r of (b.results || []).slice(0, 20)) {
      const key = accKey(r.key);
      if (!key) continue;
      await db.collection("bbapp_lookup").doc(key).set({ done: Date.now(), ok: !!r.ok,
        parties: (r.parties || []).slice(0, 10).map((x) => ({ name: String(x.name || ""), address: String(x.address || ""),
          dest: String(x.dest || ""), pincode: String(x.pincode || ""), gstin: String(x.gstin || ""), transport: String(x.transport || "") })) }, { merge: true });
    }
    for (const r of (b.idres || []).slice(0, 20)) {
      const key = accKey(r.key);
      if (!key) continue;
      await db.collection("bbapp_idcheck").doc(key).set({ done: Date.now(), hits: (r.hits || []).slice(0, 5) }, { merge: true });
      // Owner 16-Oct: same PAN / Aadhaar / GST on ONE Tally customer ledger ->
      // it IS that party: link the account to it (no new ledger), approve.
      if ((r.hits || []).length === 1) {
        try {
          const ref = db.collection("bbapp_accounts").doc(key);
          const a = (await ref.get()).data() || {};
          if (a.kind === "new" && a.status !== "blocked" && a.status !== "declined" && !a.held) {
            const name = String(r.hits[0]);
            let h = null;
            try {
              if (!PARTIES) PARTIES = require("./parties.json");
              for (const lst of Object.values(PARTIES)) { h = (lst || []).find((x) => x.name === name); if (h) break; }
            } catch (e) { /* saved list missing */ }
            const c = a.cust || {};
            const wasPending = a.status !== "approved";
            await ref.set({ kind: "existing", party: name, status: "approved", ...(wasPending ? { approvedAt: Date.now(), approvedBy: "bot (same ID in Tally)" } : {}),
              cust: { ...c, billName: name, ...(h ? { address: h.address || c.address, pincode: h.pincode || c.pincode,
                bookingPlace: h.dest || c.bookingPlace, transport: h.transport || c.transport, taxId: h.gstin || c.taxId } : {}), kind: "old" },
              log: admin.firestore.FieldValue.arrayUnion({ a: `🔗 linked to Tally party ${name} (same ${r.what || "ID"})`, by: "bot", at: Date.now() }) }, { merge: true });
            const fresh = (await ref.get()).data() || {};
            if (fresh.msg && fresh.msg.id) {
              await tg("editMessageText", { chat_id: fresh.msg.chat, message_id: fresh.msg.id, text: accText(key, fresh),
                parse_mode: "HTML", reply_markup: accKeyboard(key, fresh.status) }).catch(() => {});
            }
            if (wasPending) await pushTo(db, key, "✅ Your B.B Synthetics account is approved — now you can open the app and start ordering.");
            continue; // no "same PAN" warning: it is handled
          }
        } catch (e) { logger.warn("idcheck link", { key, error: e.message }); }
      }
      if ((r.hits || []).length) {
        const a = (await db.collection("bbapp_accounts").doc(key).get()).data() || {};
        const chat = await approvalsChat(db);
        if (chat) {
          await tg("sendMessage", { chat_id: chat, ...(a.msg && a.msg.id ? { reply_to_message_id: a.msg.id } : {}),
            text: `⚠️ ${(a.cust || {}).billName || key}: same ${r.what || "PAN / Aadhaar"} already in Tally — ${r.hits.join(", ")}` }).catch(() => {});
        }
      }
    }
    // Owner 18-Oct: bill settled in Tally -> 💰 Payment received by itself.
    for (const r of (b.payres || []).slice(0, 10)) {
      const ref = String(r.key || "").replace(/[^A-Z0-9-]/gi, "").slice(0, 40);
      if (!ref) continue;
      const oref = db.collection("bbapp_orders").doc(ref);
      await oref.set({ payChk: Date.now(), payOk: !!r.ok, payOpen: (r.open || []).slice(0, 10).map(String),
        ...(r.ok && r.balance != null ? { payBal: Math.round(Number(r.balance) || 0) } : {}) }, { merge: true });
      const d = (await oref.get()).data() || {};
      if (r.ok && r.paid && d.status === "bill_sent" && !d.cancelled) {
        await autoStep(db, ref, "y", "Tally (bill settled)", { paidTally: Date.now() });
      } else if (r.ok && d.chat && d.msg) {
        // redraw: the closing balance line / wait button
        await tg("editMessageText", { chat_id: d.chat, message_id: d.msg, text: statusText(d, ""), parse_mode: "HTML",
          disable_web_page_preview: true, reply_markup: statusKeyboard(ref, d) }).catch(() => {});
      }
    }
    await db.collection("bbapp_settings").doc("lookup").set({ at: Date.now() });
    const q = await db.collection("bbapp_lookup").where("done", "==", null).get();
    const keys = q.docs.filter((d) => Date.now() - (d.get("req") || 0) < 3 * 60e3).map((d) => d.id);
    const iq = await db.collection("bbapp_idcheck").where("done", "==", null).get();
    const ids = iq.docs.filter((d) => Date.now() - (d.get("req") || 0) < 24 * 3600e3)
      .map((d) => ({ key: d.id, pan: d.get("pan") || "", aadhaar: d.get("aadhaar") || "" }));
    const pay = [];
    try {
      const h = Number(new Date().toLocaleString("en-US", { timeZone: "Asia/Kolkata", hour: "numeric", hour12: false }));
      const mi = Number(new Date().toLocaleString("en-US", { timeZone: "Asia/Kolkata", minute: "numeric" }));
      const day = (h > 10 || (h === 10 && mi >= 30)) && (h < 20 || (h === 20 && mi <= 30)); // no Tally reads at night
      if (day) {
        const bs = await db.collection("bbapp_orders").where("status", "==", "bill_sent").get();
        for (const doc of bs.docs) {
          const d = doc.data();
          if (!d.tallyBillNo || d.cancelled || d.hold) continue;
          if (Date.now() - Number(d.payChk || 0) < 15 * 60e3) continue;
          const acc = (await db.collection("bbapp_accounts").doc(accKey(d.mobile) || "-").get()).data() || {};
          const party = String(d.ledgerName || (acc.kind === "existing" && acc.party) || d.billName || "").trim();
          if (!party) continue;
          await doc.ref.set({ payChk: Date.now() }, { merge: true });
          pay.push({ key: doc.id, party, bill: String(d.tallyBillNo) });
          if (pay.length >= 3) break;
        }
      }
    } catch (e) { logger.warn("pay queue", { error: e.message }); }
    return res.json({ ok: true, keys, ids, pay });
  },
);


/* ---------- Store reviewers: fixed demo login (Google Play rejected 3.1.15) ---------- */
const DEMO_KEY = "9999900001";
const DEMO_PARTY = { name: "DEMO REVIEWER — IGNORE", address: "Demo account for app store review", dest: "SURAT",
  pincode: "395002", gstin: "", transport: "COURIER" };

exports.accountDemo = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const ip = String(req.get("x-forwarded-for") || req.ip || "").split(",")[0].trim();
    if (limited("d:" + ip)) return res.status(429).json({ ok: false, error: "Too many tries — wait a minute." });
    const db = admin.firestore();
    const cfg = (await db.collection("bbapp_settings").doc("demo").get()).data() || {};
    const user = String((req.body && req.body.user) || "").trim().toLowerCase();
    const pass = String((req.body && req.body.pass) || "").trim();
    if (!cfg.user || user !== String(cfg.user).toLowerCase() || pass !== String(cfg.pass)) {
      return res.json({ ok: false, error: "Wrong user ID or password." });
    }
    const cust = { billName: DEMO_PARTY.name, address: DEMO_PARTY.address, pincode: DEMO_PARTY.pincode,
      bookingPlace: DEMO_PARTY.dest, transport: DEMO_PARTY.transport, taxId: "", mobile: DEMO_KEY, country: "India", kind: "old" };
    await db.collection("bbapp_accounts").doc(DEMO_KEY).set({ status: "approved", kind: "existing", demo: true,
      party: DEMO_PARTY.name, cust, verifiedAt: Date.now(),
      log: admin.firestore.FieldValue.arrayUnion({ a: "🧪 demo login (store review)", by: "app", at: Date.now() }) }, { merge: true });
    const devKey = await giveDevKey(db, DEMO_KEY, null);
    return res.json({ ok: true, mobile: DEMO_KEY, india: true, status: "approved", kind: "existing",
      party: DEMO_PARTY.name, cust, devKey });
  },
);


/** Owner 15-Oct: what an Aadhaar / PAN photo actually says (phone OCR text):
 *  the pincode, the address line with it, and the holder's name. */
function cardFacts(text) {
  const lines = String(text || "").split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const up = lines.map((l) => l.toUpperCase());
  let pin = "", addr = "";
  for (let i = up.length - 1; i >= 0 && !pin; i--) {
    const m = up[i].replace(/(\d{4})\s(\d{4})\s(\d{4})/g, "").match(/(?<!\d)([1-9]\d{2}\s?\d{3})(?!\d)/);
    if (m) {
      pin = m[1].replace(/\s/g, "");
      addr = [lines[i - 2], lines[i - 1], lines[i]].filter(Boolean).join(", ").replace(/^.*?ADDRESS\s*:?\s*/i, "").replace(/,\s*,/g, ",").slice(0, 160);
    }
  }
  const skip = /GOVERNMENT|INDIA|INCOME|TAX|DEPARTMENT|AADHAAR|UNIQUE|AUTHORITY|PERMANENT|ACCOUNT|NUMBER|CARD|SIGNATURE|ADDRESS|DOB|BIRTH|MALE|FEMALE|^\d|VID|ENROL|HELP|WWW|@/;
  const isName = (l) => /^[A-Z][A-Z .']{2,40}$/.test(l) && !skip.test(l) && l.split(" ").length <= 5;
  let name = "";
  const dob = up.findIndex((l) => /DOB|DATE OF BIRTH|YEAR OF BIRTH|\bMALE\b|\bFEMALE\b|जन्म/.test(l));
  for (let i = dob - 1; dob > 0 && i >= Math.max(0, dob - 3) && !name; i--) if (isName(up[i])) name = up[i];
  if (!name) {
    const nIdx = up.findIndex((l) => /^NAME\b|\/ NAME$|^नाम/.test(l));
    if (nIdx >= 0) for (let i = nIdx + 1; i < Math.min(up.length, nIdx + 3) && !name; i++) if (isName(up[i])) name = up[i];
  }
  if (!name) {
    const to = up.findIndex((l) => /^TO\b/.test(l));
    if (to >= 0 && isName(up[to + 1] || "")) name = up[to + 1];
  }
  if (!name) {
    const so = up.findIndex((l) => /\b[SDWC]\/O\b/.test(l));
    if (so > 0 && isName(up[so - 1])) name = up[so - 1];
  }
  return { pin, addr, name: name.replace(/\s+/g, " ").trim() };
}


/** Owner 15-Oct: city / destination key — same as the shop PC's city_key(). */
function cityKey(x) {
  return String(x || "").toUpperCase().replace(/\(.*?(\)|$)/g, " ").replace(/[^A-Z0-9]/g, "");
}


/** App: a one-time link to upload the business-proof VIDEO (owner 15-Oct).
 *  Needs the WhatsApp-verified code; the file is proof/<mobile>-<time>.mp4. */
exports.proofUploadUrl = onRequest(
  { region: "asia-south1", timeoutSeconds: 20, memory: "256MiB", maxInstances: 3, invoker: "public", cors: true },
  async (req, res) => {
    if (req.method !== "POST" || !appOk(req)) return res.status(403).json({ ok: false });
    const db = admin.firestore();
    const key = await verifiedKey(db, req.body && req.body.code);
    if (!key) return res.json({ ok: false, error: "Please verify your number on WhatsApp again." });
    const path = `proof/${key}-${Date.now()}.mp4`;
    const [url] = await admin.storage().bucket().file(path).getSignedUrl({
      version: "v4", action: "write", expires: Date.now() + 15 * 60e3, contentType: "video/mp4" });
    return res.json({ ok: true, url, path });
  },
);

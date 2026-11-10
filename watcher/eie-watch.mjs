#!/usr/bin/env node
/**
 * EIE Watch — watches the Elliott Impulse Engine [WillyAlgoTrader] indicator on your
 * TradingView Desktop chart (via tradingview-mcp / Chrome DevTools on localhost:9222),
 * sends macOS notifications on wave events, and audits repainting live.
 *
 * Usage:
 *   node eie-watch.mjs                         # watch the active chart
 *   node eie-watch.mjs --rotate "OANDA:XAUUSD,TVC:USOIL" --dwell 20
 *   node eie-watch.mjs --interval 2 --risk 25 --buffer 0.30 --no-notify
 *   node eie-watch.mjs --ntfy my-secret-topic-123 # also push to your phone (free ntfy app)
 *   node eie-watch.mjs --ui                    # + Operation Aurum dashboard at http://localhost:8787
 *   node eie-watch.mjs --demo                  # dashboard with a synthetic feed (no TradingView needed)
 *   node eie-watch.mjs --ui --trade paper      # + auto-trade a built-in paper account (log: trades.csv)
 *   OANDA_TOKEN=… OANDA_ACCOUNT=… node eie-watch.mjs --ui --trade oanda   # OANDA practice (demo) account
 *   node eie-watch.mjs --ui --trade tv-dry     # TradingView Paper Trading: fill the order dialog, don't click Place
 *   node eie-watch.mjs --ui --trade tv         # TradingView Paper Trading: place the order (Paper accounts only)
 *   node eie-watch.mjs --tv-test               # place ONE test order in TradingView Paper Trading (add --dry to only fill the dialog)
 *   node eie-watch.mjs --ui --mc-paths 500000  # Monte Carlo War Room size (also --mc-from "EIE PRO", --mc-risk, --mc-perday, --mc-off)
 *   node eie-watch.mjs --selftest              # offline logic test, no TradingView needed
 *
 * Files (in ~/eie-watch/): events.jsonl (every event), ledger.json (repaint ledger),
 * report.txt (repaint audit summary, rewritten every 10 min and on exit).
 *
 * Unofficial: reads only your own locally running app. Check TradingView's Terms of Use.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { Worker } from 'node:worker_threads';
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

// ── args ────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf(k); return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : d; };
const flag = (k) => argv.includes(k);
const CFG = {
  interval: Number(arg('--interval', 2)) * 1000,
  rotate: (arg('--rotate', '') || '').split(',').map(s => s.trim()).filter(Boolean),
  dwell: Number(arg('--dwell', 20)) * 1000,
  riskUsd: Number(arg('--risk', 25)),          // $ risk per trade (0.5% of a 5K account)
  stopBuffer: Number(arg('--buffer', 0)),       // price buffer beyond point 0 for the stop
  entryFib: Number(arg('--entry', 0.618)),      // W2 limit entry as retracement of leg 0→1
  rr: Number(arg('--rr', 2)),
  wantTf: arg('--tf', '1'),
  notify: !flag('--no-notify'),
  filter: arg('--study', 'Elliott Impulse'),
  skFilter: arg('--sk', 'SK Sequence'),
  ntfy: arg('--ntfy', ''),
  ui: flag('--ui') || flag('--demo'),
  demo: flag('--demo'),
  port: Number(arg('--port', 8787)),
  vendor: arg('--vendor', path.join(SCRIPT_DIR, 'node_modules')),
  trade: arg('--trade', ''),                                   // '' | paper | oanda
  tradeFrom: arg('--trade-from', 'EIE PRO,SK SEQ').split(',').map(x => x.trim()),
  balance: Number(arg('--balance', 5000)),
  spread: Number(arg('--spread', 0.35)),                      // round-trip cost per unit for the paper account
  maxTradesDay: Number(arg('--max-trades', 5)),
  maxLossDay: Number(arg('--max-losses', 2)),
  stateAlerts: flag('--state-alerts'),   // also notify every EIE state change / zone touch (noisy)
  dir: arg('--dir', path.join(os.homedir(), 'eie-watch', ...(argv.includes('--demo') ? ['demo'] : []))),   // demo never touches real logs
  tvMcp: path.resolve(arg('--tvmcp', path.join(os.homedir(), 'tradingview-mcp'))),
};
if (flag('--selftest')) { CFG.dir = fs.mkdtempSync(path.join(os.tmpdir(), 'eie-selftest-')); CFG.notify = false; }
fs.mkdirSync(CFG.dir, { recursive: true });
const EVENTS = path.join(CFG.dir, 'events.jsonl');
const LEDGER = path.join(CFG.dir, 'ledger.json');
const REPORT = path.join(CFG.dir, 'report.txt');

// ── helpers ─────────────────────────────────────────────────────────────────
const WAVE_RE = /^([0-5]|A|B|C)(~?)$/;           // real wave labels ("2", "3~"); ghosts are "2?"
const ORDER = ['0', '1', '2', '3', '4', '5', 'A', 'B', 'C'];
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const now = () => new Date().toISOString();
const r2 = (x) => (x == null || Number.isNaN(x) ? null : Math.round(x * 100000) / 100000);

const UI = { connected: false, demo: false, symbol: null, tf: null, last: null, bars: [], panels: {}, events: [], sync: null, overlays: null, tele: null };
const TELE = { start: Date.now(), reads: 0, readMs: 0, feed: [], evTimes: [], lastSettings: 0, lastDraw: 0, fp: {}, changedAt: {} };
function teleLine(s) { TELE.feed.push(new Date().toISOString().slice(11, 23) + '  ' + s); if (TELE.feed.length > 60) TELE.feed.shift(); }
function fp(obj) { let h = 2166136261; const str = JSON.stringify(obj); for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(16).padStart(8, '0'); }
function log(evt) {
  const line = { ts: now(), ...evt };
  UI.events.push({ ts: line.ts, type: evt.type, symbol: evt.symbol || '', msg: evt.msg || '' });
  TELE.evTimes.push(Date.now());
  if (UI.events.length > 200) UI.events.splice(0, UI.events.length - 200);
  fs.appendFileSync(EVENTS, JSON.stringify(line) + '\n');
  const tag = evt.type.padEnd(18);
  console.log(`${line.ts.slice(11, 19)}  ${tag} ${evt.symbol || ''} ${evt.msg || ''}`);
  return line;
}
function notify(title, body, loud = false) {
  if (!CFG.notify || process.platform !== 'darwin') return;
  const esc = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const script = `display notification "${esc(body)}" with title "${esc(title)}"${loud ? ' sound name "Glass"' : ''}`;
  execFile('osascript', ['-e', script], () => {});
  if (CFG.ntfy) {   // free phone push via https://ntfy.sh (install the ntfy app, subscribe to the same topic)
    fetch('https://ntfy.sh/', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ topic: CFG.ntfy, title, message: body, priority: loud ? 4 : 3 }) }).catch(() => {});
  }
}

// ── readers (real = TradingView Desktop via CDP) ─────────────────────────────
async function makeRealReader() {
  const core = await import(path.join(CFG.tvMcp, 'src/core/index.js'));
  const conn = await import(path.join(CFG.tvMcp, 'src/connection.js'));
  const bars = 'window.TradingViewApi._activeChartWidgetWV.value()._chartWidget.model().mainSeries().bars()';
  return {
    async snapshot() {
      const st = await core.chart.getState();
      const [lab, box, tab, meta] = await Promise.all([
        core.data.getPineLabels({ study_filter: CFG.filter, verbose: true, max_labels: 500 }),
        core.data.getPineBoxes({ study_filter: CFG.filter, verbose: true }),
        core.data.getPineTables({ study_filter: CFG.filter }),
        conn.evaluate(`(function(){var b=${bars};var e=b.lastIndex();var v=b.valueAt(e);
           return {last:e, first:b.firstIndex(), t:v?v[0]:null, c:v?v[4]:null, h:v?v[2]:null, l:v?v[3]:null};})()`),
      ]);
      const xs = new Set((lab.studies?.[0]?.labels || []).map(l => l.x).filter(x => x != null && x <= meta.last));
      const times = xs.size ? await conn.evaluate(`(function(){var b=${bars};var o={};
           ${JSON.stringify([...xs])}.forEach(function(x){var v=b.valueAt(x);o[x]=v?v[0]:null;});return o;})()`) : {};
      const skTab = await core.data.getPineTables({ study_filter: CFG.skFilter }).catch(() => ({ studies: [] }));
      const rowsOf = (t) => (t.studies || []).flatMap(x => (x.tables || []).flatMap(tb => tb.rows || []));
      return {
        panels: { 'EIE PRO': rowsOf(tab), 'SK SEQ': rowsOf(skTab) },
        symbol: st.symbol, tf: String(st.resolution),
        studyFound: (lab.studies || []).length > 0 || (tab.studies || []).length > 0,
        labels: (lab.studies?.[0]?.labels || []).map(l => ({ ...l, time: times[l.x] ?? null })),
        boxes: box.studies?.[0]?.all_boxes || [],
        table: (tab.studies || []).flatMap(st => (st.tables || []).flatMap(t => t.rows || [])),   // EIE dashboard + watermark + PRO table
        bar: meta,
      };
    },
    async setSymbol(sym) { await core.chart.setSymbol({ symbol: sym }); },
    async ohlcv() { const r = await core.data.getOhlcv({ count: 500 }); return r.bars || []; },
    // settings of EIE PRO and SK SEQ (names + values) for the SYNC strip
    async settings() {
      return conn.evaluate(`(function(){ var api = window.TradingViewApi._activeChartWidgetWV.value(); var out = [];
        (api.getAllStudies() || []).forEach(function(s){
          if (!/Elliott Impulse|SK Sequence/.test(s.name || '')) return;
          var st = api.getStudyById(s.id); var vals = [], info = [], names = {};
          try { vals = st.getInputValues() || []; } catch (e) {}
          try { info = st.getInputsInfo() || []; } catch (e) {}
          info.forEach(function(i){ names[i.id] = i.name; });
          out.push({ id: s.id, name: s.name, inputs: vals.filter(function(v){ return typeof v.value !== 'string' || v.value.length < 200; })
            .map(function(v){ return { id: v.id, name: names[v.id] || v.id, value: v.value }; }) });
        }); return out; })()`);
    },
    // raw drawings (text, prices, bar positions) from both indicators for the dashboard chart
    async drawings() {
      const js = (coll, key) => `(function(){ var m = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget.model();
        var src = m.model().dataSources(); var bars = m.mainSeries().bars(); var res = [];
        for (var i = 0; i < src.length; i++) { var s = src[i]; if (!s.metaInfo) continue; var nm = ''; try { nm = s.metaInfo().description || ''; } catch (e) {}
          if (!/Elliott Impulse|SK Sequence/.test(nm)) continue; var g = s._graphics; if (!g || !g._primitivesCollection) continue;
          try { var o = g._primitivesCollection.${coll}; var inner = o && o.get('${key}'); var c = inner && inner.get(false);
            if (c && c._primitivesDataById) c._primitivesDataById.forEach(function(v){
              var t1 = v.x != null ? bars.valueAt(v.x) : (v.x1 != null ? bars.valueAt(v.x1) : null);
              res.push({ src: /SK/.test(nm) ? 'SK' : 'EIE', t: v.t || '', y: v.y, y1: v.y1, y2: v.y2, x: v.x, x1: v.x1, x2: v.x2, time: t1 ? t1[0] : null }); });
          } catch (e) {} }
        return res; })()`;
      const [labels, boxes] = await Promise.all([conn.evaluate(js('dwglabels', 'labels')), conn.evaluate(js('dwgboxes', 'boxes'))]);
      return { labels: labels || [], boxes: boxes || [] };
    },
    async health() { return core.health.healthCheck(); },
  };
}

// ── parsing ─────────────────────────────────────────────────────────────────
function parseDash(rows) {
  const d = {};
  for (const r of rows) {
    const [k, ...v] = r.split(' | ');
    d[k.trim()] = v.join(' | ').trim();
  }
  return {
    state: d['State'] || null, dir: d['Direction'] || null,
    invalid: d['Invalidation'] && d['Invalidation'] !== '—' ? Number(d['Invalidation'].replace(/,/g, '')) : null,
    lastReset: d['Last Reset'] || null, tf: d['TF'] || null,
  };
}
function wavePoints(labels) {
  const pts = {};
  for (const l of labels) {
    const m = WAVE_RE.exec((l.text || '').trim());
    if (!m || l.price == null) continue;
    const key = m[1];
    if (!pts[key] || l.x > pts[key].x) pts[key] = { key, soft: m[2] === '~', price: l.price, x: l.x, time: l.time };
  }
  return pts;
}
const chochs = (labels) => labels.filter(l => (l.text || '').trim() === 'CHoCH' && (l.time != null || l.x != null))
  .map(l => ({ time: l.time ?? l.x, price: l.price, real: l.time != null }));   // raw x fallback is never used for repaint checks

// ── per-symbol tracker ──────────────────────────────────────────────────────
const ledger = fs.existsSync(LEDGER) ? JSON.parse(fs.readFileSync(LEDGER, 'utf8')) : { points: [], chochs: [], stats: {} };
const saveLedger = () => fs.writeFileSync(LEDGER, JSON.stringify(ledger, null, 1));
const S = (k) => (ledger.stats[k] = ledger.stats[k] || { newPoints: 0, expectedRepos: 0, unexpected: 0, lagBars: {}, resets: 0, reloadChecks: 0, reloadMismatch: 0 });

const trackers = new Map();
function tracker(key) {
  if (!trackers.has(key)) trackers.set(key, { prev: null, countId: 0, flags: {} });
  return trackers.get(key);
}

function tradePlan(pts, dir) {
  if (!pts['0'] || !pts['1'] || !dir) return null;
  const p0 = pts['0'].price, p1 = pts['1'].price, L = p1 - p0;      // L>0 long, <0 short
  const entry = p1 - CFG.entryFib * L;
  const stop = p0 - Math.sign(L) * CFG.stopBuffer;
  const risk = Math.abs(entry - stop);
  const tp = entry + Math.sign(L) * CFG.rr * risk;
  const w3lo = p1 + 0.5 * L, w3hi = p1 + 0.618 * L;                  // EIE point-3 range (-0.5…-0.618)
  return { side: L > 0 ? 'LONG' : 'SHORT', entry: r2(entry), stop: r2(stop), tp: r2(tp), riskPerUnit: r2(risk),
    unitsFor$Risk: risk > 0 ? r2(CFG.riskUsd / risk) : null, w3Zone: [r2(Math.min(w3lo, w3hi)), r2(Math.max(w3lo, w3hi))],
    tpInsideOrBeforeW3: L > 0 ? tp <= Math.max(w3lo, w3hi) : tp >= Math.min(w3lo, w3hi) };
}

function process1(snap) {
  const key = `${snap.symbol}|${snap.tf}`;
  const T = tracker(key), st = S(key);
  const dash = parseDash(snap.table);
  const pts = wavePoints(snap.labels);
  const ch = chochs(snap.labels);
  const sym = snap.symbol;
  const out = [];

  if (!snap.studyFound) { if (!T.flags.noStudy) out.push(log({ type: 'NO_INDICATOR', symbol: sym, msg: `EIE not found on chart (filter "${CFG.filter}")` })); T.flags.noStudy = true; return out; }
  T.flags.noStudy = false;
  if (snap.tf !== CFG.wantTf && !T.flags.tfWarn) { out.push(log({ type: 'TF_WARNING', symbol: sym, msg: `chart TF is ${snap.tf}, expected ${CFG.wantTf}` })); T.flags.tfWarn = true; }

  const P = T.prev;
  // Reload / history-shift detection → compare live-recorded CHoCHs with recomputed history
  const reloaded = P && (snap.bar.first !== P.bar.first || snap.bar.last < P.bar.last);
  if (!P || reloaded) {
    const recorded = ledger.chochs.filter(c => c.key === key && c.run === RUN_ID && c.real && c.time >= (ch.find(h => h.real)?.time ?? Infinity));
    if (P && recorded.length) {
      st.reloadChecks++;
      const missing = recorded.filter(c => !ch.some(h => h.time === c.time && Math.abs(h.price - c.price) < 1e-6));
      if (missing.length) { st.reloadMismatch += missing.length; out.push(log({ type: 'REPAINT_SUSPECT', symbol: sym, msg: `${missing.length}/${recorded.length} live-recorded CHoCH not reproduced after reload`, missing })); notify('EIE repaint suspect', `${sym}: ${missing.length} CHoCH changed after reload`, true); }
      else out.push(log({ type: 'RELOAD_CHECK_OK', symbol: sym, msg: `${recorded.length} live CHoCH reproduced exactly after reload` }));
    }
    T.prev = { ...snap, dash, pts, ch }; saveLedger();
    if (!P) out.push(log({ type: 'START', symbol: sym, msg: `tf=${snap.tf} state=${dash.state} dir=${dash.dir} invalid=${dash.invalid}` }));
    return out;
  }

  // New CHoCH labels (record live for later reload comparison)
  for (const c of ch) if (!P.ch.some(h => h.time === c.time)) {
    if (c.real) ledger.chochs.push({ key, time: c.time, price: c.price, real: true, run: RUN_ID, seen: now() });
  }

  // State machine changes (from EIE dashboard)
  if (dash.state !== P.dash.state || dash.dir !== P.dash.dir) {
    const plan = tradePlan(pts, dash.dir === 'Long' || dash.dir === 'Short' ? dash.dir : null);
    if (P.dash.state === 'Scanning' || P.dash.state === null) T.countId++;
    out.push(log({ type: 'STATE', symbol: sym, msg: `${P.dash.state} → ${dash.state} (${dash.dir}) invalid=${dash.invalid}`, plan }));
    if (dash.state === 'Wave 2' && plan) {
      CFG.stateAlerts && notify(`EIE ${sym} 1m: ${plan.side} setup (W2)`, `Limit ${plan.entry} SL ${plan.stop} TP ${plan.tp} (${CFG.rr}R). Cancel if INVALID breaks.`, true);
    } else if (dash.state === 'Scanning') {
      CFG.stateAlerts && notify(`EIE ${sym}: count reset`, `Reason: ${dash.lastReset}. Cancel pending orders.`, true);
    } else CFG.stateAlerts && notify(`EIE ${sym}: ${dash.state}`, `${dash.dir} · invalid ${dash.invalid}`);
  }
  if (dash.lastReset !== P.dash.lastReset && dash.lastReset && dash.lastReset !== '—') {
    st.resets++; T.flags = {}; out.push(log({ type: 'RESET', symbol: sym, msg: `reason=${dash.lastReset}` }));
  }

  // Zone touches (wick) — W2 OTE and W4 box, once per count
  const box = snap.boxes.filter(b => b.high != null).sort((a, b) => (b.x1 ?? 0) - (a.x1 ?? 0))[0];
  if (box && snap.bar.h != null) {
    const touched = snap.bar.l <= box.high && snap.bar.h >= box.low;
    const zone = dash.state === 'Wave 2' ? 'W2_OTE' : dash.state === 'Wave 4' ? 'W4_BOX' : null;
    if (zone && touched && !T.flags[zone + T.countId]) {
      T.flags[zone + T.countId] = true;
      out.push(log({ type: 'ZONE_TOUCH', symbol: sym, msg: `${zone} ${box.low}–${box.high} price=${snap.bar.c}` }));
      CFG.stateAlerts && notify(`EIE ${sym}: price in ${zone}`, `${box.low} – ${box.high} · last ${snap.bar.c}`, true);
    }
  }

  // Repaint audit on wave points
  const latestKey = ORDER.filter(k => pts[k]).pop();
  const prevLatest = ORDER.filter(k => P.pts[k]).pop();
  for (const k of ORDER) {
    const a = P.pts[k], b = pts[k];
    if (b && !a) {
      const lag = snap.bar.last - b.x;
      st.newPoints++; (st.lagBars[k] = st.lagBars[k] || []).push(lag);
      ledger.points.push({ key, count: T.countId, wave: k, price: b.price, time: b.time, firstSeen: now(), lagBars: lag });
      out.push(log({ type: 'NEW_POINT', symbol: sym, msg: `point ${k}${b.soft ? '~' : ''} @ ${b.price} (appeared ${lag} bars after the swing)` }));
    } else if (a && b && (a.x !== b.x || Math.abs(a.price - b.price) > 1e-9)) {
      // EIE by design repositions only the newest point (1 until 2 locks, 2 until 1 breaks, 3 during W4,
      // 4 until 3 breaks, 5 during correction, A until B, B until C). Point 0 and older points never move.
      const allowed = k !== '0' && (k === latestKey || k === prevLatest);
      if (allowed) st.expectedRepos++; else st.unexpected++;
      out.push(log({ type: allowed ? 'REPOSITION' : 'UNEXPECTED_MOVE', symbol: sym,
        msg: `point ${k}: ${a.price}@${a.time} → ${b.price}@${b.time}` }));
      if (!allowed) notify('EIE repaint suspect', `${sym}: locked point ${k} moved`, true);
    } else if (a && !b && dash.state === P.dash.state && dash.lastReset === P.dash.lastReset) {
      st.unexpected++;
      out.push(log({ type: 'UNEXPECTED_REMOVE', symbol: sym, msg: `point ${k} vanished without a reset` }));
    }
  }
  T.prev = { ...snap, dash, pts, ch };
  return out;
}

function writeReport() {
  const lines = [`EIE repaint audit — ${now()}`, ''];
  for (const [k, s] of Object.entries(ledger.stats)) {
    const lag = Object.entries(s.lagBars).map(([w, a]) => `${w}:${(a.reduce((x, y) => x + y, 0) / a.length).toFixed(1)}`).join(' ');
    lines.push(`${k}`, `  new wave points ......... ${s.newPoints}`, `  avg confirmation lag (bars) ${lag || '-'}`,
      `  expected repositions .... ${s.expectedRepos}  (by design: newest point refines)`,
      `  UNEXPECTED moves/removes  ${s.unexpected}  (should be 0)`,
      `  resets .................. ${s.resets}`,
      `  reload checks / mismatches ${s.reloadChecks} / ${s.reloadMismatch}  (mismatch > 0 = true repaint)`, '');
  }
  lines.push('Verdict rule: UNEXPECTED = 0 and reload mismatches = 0 over several sessions → no true repainting;',
    'lag = how many 1m bars after the real swing each label appears (trade on first appearance, not on the drawn position).');
  fs.writeFileSync(REPORT, lines.join('\n') + '\n');
}

// ══════════════════════════════════════════════════════════════════════════
// AUTO-TRADER (demo only): acts on PLACE / MOVE / CANCEL signals from the panels.
//   --trade paper   built-in paper account, prices sampled from your chart
//   --trade oanda   OANDA *practice* account via the official v20 REST API
//                   (env OANDA_TOKEN + OANDA_ACCOUNT; the live server is never used)
// Guards: one order/position at a time · max trades/day · stop after N losses/day ·
//         fixed $ risk · skips when SK reports an EIE × SK CONFLICT.
// Every trade is appended to ~/eie-watch/trades.csv and shown on the dashboard.
// ══════════════════════════════════════════════════════════════════════════
// ── TradingView Desktop order placer (Paper Trading only) ────────────────────
// Fills TradingView's own order dialog over the local debug port and clicks Place.
// Safety: refuses unless the account manager is "Paper"; reads every field back and checks the
// Place-button summary (side · qty · symbol · price · LIMIT) before clicking; verifies the Orders
// count rises afterwards. --trade tv-dry fills the dialog but never clicks Place.
const tvRequire = createRequire(path.join(CFG.tvMcp, 'package.json'));
const TV_PORT = Number(process.env.TV_CDP_PORT || 9222);
const tvWait = (ms) => new Promise(r => setTimeout(r, ms));
const TV_HELPERS = `
  var vis = function(el){ if (!el) return false; var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  var D = document.querySelector('[data-name="order-dialog-popup"]');
  var txt = function(el){ return ((el && (el.innerText || el.getAttribute('aria-label'))) || '').trim().replace(/\\s+/g, ' '); };
  var labelOf = function(el){ var p = el, t = ''; for (var i = 0; i < 4 && p && !t; i++, p = p.parentElement) t = (p.innerText || '').trim(); return t; };
  var inputs = function(){ return D ? Array.from(D.querySelectorAll('input')).filter(vis) : []; };
  var btn = function(re, sel){ return D ? Array.from(D.querySelectorAll(sel || 'button,[role=button],[role=tab]')).filter(vis).find(function(b){ return re.test(txt(b)); }) : null; };
`;
async function tvClient() {
  const CDP = tvRequire('chrome-remote-interface');
  const list = await CDP.List({ host: '127.0.0.1', port: TV_PORT });
  const match = new RegExp(process.env.TV_PAGE_MATCH || 'tradingview\\.com/chart');
  const t = list.find(x => x.type === 'page' && match.test(x.url || ''));
  if (!t) throw new Error('TradingView chart page not found on the debug port');
  return CDP({ host: '127.0.0.1', port: TV_PORT, target: t.id });
}
async function tvEval(c, body) {
  const r = await c.Runtime.evaluate({ expression: `(function(){ ${TV_HELPERS} ${body} })()`, returnByValue: true });
  if (r.exceptionDetails) throw new Error('page script: ' + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
  return r.result.value;
}
async function tvType(c, findJs, value) {      // focus + select the field in-page, then type with trusted input events
  const ok = await tvEval(c, `var el = (function(){ ${findJs} })(); if (!el) return false; el.focus(); el.select && el.select(); return true;`);
  if (!ok) return false;
  await c.Input.insertText({ text: String(value) });
  await c.Input.dispatchKeyEvent({ type: 'keyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  await c.Input.dispatchKeyEvent({ type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  await tvWait(250);
  return true;
}
const num = (s) => Number(String(s).replace(/,/g, ''));
async function tvOpenDialog(c) {
  if (await tvEval(c, 'return !!D && vis(D);')) return true;
  // TradingView hotkey for the order panel (Shift+T); focus is moved off any text field first
  await tvEval(c, 'if (document.activeElement) document.activeElement.blur(); return true;');
  await c.Input.dispatchKeyEvent({ type: 'keyDown', key: 'T', code: 'KeyT', modifiers: 8, windowsVirtualKeyCode: 84 });
  await c.Input.dispatchKeyEvent({ type: 'keyUp', key: 'T', code: 'KeyT', modifiers: 8, windowsVirtualKeyCode: 84 });
  await tvWait(900);
  return tvEval(c, 'return !!D && vis(D);');
}
async function tvPlaceOrder({ side, units, entry, sl, tp, symbol, dry }) {
  const c = await tvClient();
  try {
    // 1. Paper Trading only
    const acct = await tvEval(c, `var paper = !!document.querySelector('[data-name^="Paper."]');
      var other = Array.from(document.querySelectorAll('[data-name$=".orders-table"]')).map(function(e){ return e.getAttribute('data-name'); }).filter(function(n){ return !/^Paper\\./.test(n); });
      return { paper: paper, other: other };`);
    if (!acct.paper || acct.other.length) throw new Error(`account is not Paper Trading (found ${JSON.stringify(acct.other)}) — refusing`);
    // 2. Order dialog
    if (!(await tvOpenDialog(c))) throw new Error('order dialog not open — right-click chart → Trade → Create limit order, then leave it open');
    const ordersBefore = await tvEval(c, `var t = Array.from(document.querySelectorAll('[role=tab]')).find(function(b){ return /^Orders/.test(txt(b)); }); var m = t && txt(t).match(/(\\d+)/); return m ? +m[1] : 0;`);
    // 3. Side + Limit
    const sideOk = await tvEval(c, `var b = D.querySelector('[data-name="side-control-${side === 1 ? 'buy' : 'sell'}"]'); if (!b) return false; b.click(); return true;`);
    if (!sideOk) throw new Error('Buy/Sell control not found');
    await tvWait(200);
    const limOk = await tvEval(c, `var t = btn(/^Limit$/, '[role=tab]'); if (!t) return false; t.click(); return true;`);
    if (!limOk) throw new Error('Limit tab not found');
    await tvWait(250);
    // 4. Price
    if (!(await tvType(c, `return inputs().find(function(i){ return /priceInput/.test(i.className); });`, entry.toFixed(3)))) throw new Error('price field not found');
    // 5. Quantity in units (switch from "USD margin" if needed)
    const qtyMode = await tvEval(c, `var q = inputs().find(function(i){ return /units|margin|quantity|lots/i.test((i.getAttribute('aria-label') || '') + ' ' + labelOf(i)) && !/priceInput/.test(i.className) && i.type !== 'checkbox'; });
      return q ? (q.getAttribute('aria-label') || labelOf(q)) : null;`);
    if (!qtyMode) throw new Error('quantity field not found');
    if (!/units/i.test(qtyMode) || /margin/i.test(qtyMode)) {
      // Open the quantity-type menu (the "USD margin ⌄" heading or the "0 units ⌄" chip), then pick "Units"
      const pickUnits = `var vis2 = function(e){ var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
        var items = Array.from(document.querySelectorAll('[role=option],[role=menuitem],[role=menuitemradio],[data-role=menuitem],[data-name*=menu] div,[class*=menu] div,[class*=item]'))
          .filter(vis2).filter(function(e){ return /^(units|quantity)$/i.test((e.innerText || '').trim()); });
        if (items.length) { items[0].click(); return true; } return false;`;
      for (const opener of [`btn(/^USD margin$/i)`, `btn(/^\\d[\\d,.]*\\s*units$/i) || btn(/^units$/i)`]) {
        const opened = await tvEval(c, `var b = ${opener}; if (b) b.click(); return !!b;`);
        if (!opened) continue;
        await tvWait(400);
        if (await tvEval(c, pickUnits)) { await tvWait(400); break; }
        await c.Input.dispatchKeyEvent({ type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });   // close an unrelated menu
        await c.Input.dispatchKeyEvent({ type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
        await tvWait(200);
      }
    }
    const qOk = await tvType(c, `return inputs().find(function(i){ var a = (i.getAttribute('aria-label') || '') + ' ' + labelOf(i); return /units/i.test(a) && !/margin/i.test(i.getAttribute('aria-label') || '') && !/priceInput/.test(i.className) && i.type !== 'checkbox'; });`, units);
    if (!qOk) throw new Error('could not switch quantity to units — set the order panel quantity to "units" once by hand');
    // 6. Take profit / stop loss (enable checkbox, then the price input right after it)
    for (const [re, val] of [['Take profit', tp], ['Stop loss', sl]]) {
      await tvEval(c, `var all = inputs(); var cb = all.find(function(i){ return i.type === 'checkbox' && new RegExp('${re}', 'i').test(labelOf(i)); }); if (cb && !cb.checked) cb.click(); return !!cb;`);
      await tvWait(200);
      const ok = await tvType(c, `var all = inputs(); var k = all.findIndex(function(i){ return i.type === 'checkbox' && new RegExp('${re}', 'i').test(labelOf(i)); }); return k >= 0 ? all[k + 1] : null;`, val.toFixed(3));
      if (!ok) throw new Error(`${re} field not found`);
    }
    // 7. Read everything back and check the Place-button summary before clicking
    const rb = await tvEval(c, `var all = inputs(); var tpI = all.findIndex(function(i){ return i.type === 'checkbox' && /Take profit/i.test(labelOf(i)); });
      var slI = all.findIndex(function(i){ return i.type === 'checkbox' && /Stop loss/i.test(labelOf(i)); });
      var p = D.querySelector('[data-name="place-and-modify-button"]');
      return { place: txt(p), tp: tpI >= 0 ? all[tpI + 1].value : null, sl: slI >= 0 ? all[slI + 1].value : null, tpOn: tpI >= 0 && all[tpI].checked, slOn: slI >= 0 && all[slI].checked };`);
    const m = rb.place.match(/^(Buy|Sell)\s+([\d,.]+)\s+(\S+)\s+@\s+([\d,.]+)\s+LIMIT/i);
    const ticker = String(symbol).split(':').pop().toUpperCase();
    const problems = [];
    if (!m) problems.push(`unexpected Place button text "${rb.place}"`);
    else {
      if ((m[1].toLowerCase() === 'buy' ? 1 : -1) !== side) problems.push('side mismatch');
      if (num(m[2]) !== units) problems.push(`qty ${m[2]} ≠ ${units}`);
      if (m[3].toUpperCase() !== ticker) problems.push(`symbol ${m[3]} ≠ ${ticker}`);
      if (Math.abs(num(m[4]) - entry) > 0.011) problems.push(`price ${m[4]} ≠ ${entry}`);
    }
    if (!rb.tpOn || Math.abs(num(rb.tp) - tp) > 0.011) problems.push(`take profit ${rb.tp} ≠ ${tp}`);
    if (!rb.slOn || Math.abs(num(rb.sl) - sl) > 0.011) problems.push(`stop loss ${rb.sl} ≠ ${sl}`);
    if (problems.length) throw new Error('dialog check failed, NOT placed: ' + problems.join('; '));
    if (dry) return { placed: false, summary: rb.place };
    // 8. Place and verify
    await tvEval(c, `var p = D.querySelector('[data-name="place-and-modify-button"]'); p.click(); return true;`);
    // TradingView lists a bracket as 3 rows (limit + stop loss + take profit) and can update the count slowly
    let ordersAfter = ordersBefore;
    for (let i = 0; i < 16 && ordersAfter <= ordersBefore; i++) {
      await tvWait(500);
      ordersAfter = await tvEval(c, `var t = Array.from(document.querySelectorAll('[role=tab]')).find(function(b){ return /^Orders/.test(txt(b)); }); var m = t && txt(t).match(/(\\d+)/); return m ? +m[1] : 0;`);
    }
    return { placed: true, verified: ordersAfter > ordersBefore, summary: rb.place, ordersBefore, ordersAfter };
  } finally { try { await c.close(); } catch {} }
}

const TRADES_CSV = path.join(CFG.dir, 'trades.csv');
function csvAppend(t) {
  if (!fs.existsSync(TRADES_CSV)) fs.writeFileSync(TRADES_CSV, 'opened,closed,mode,source,symbol,side,entry,stop,target,units,exit,pnl,R,reason\n');
  const row = [t.opened, t.closed, t.mode, t.src, t.symbol, t.side, t.entry, t.sl, t.tp, t.units, t.exit, t.pnl, t.R, t.reason]
    .map(v => (v == null ? '' : String(v).replace(/,/g, ';'))).join(',');
  fs.appendFileSync(TRADES_CSV, row + '\n');
}
const parseLv = (lv) => { const n = (String(lv).match(/-?\d+(?:\.\d+)?/g) || []).map(Number); return n.length >= 3 ? { entry: n[0], sl: n[1], tp: n[2] } : null; };
const dayKey = () => new Date().toLocaleDateString('en-CA', { timeZone: 'America/New_York' });

function makeBroker(mode) {
  const st = { mode, balance: CFG.balance, start: CFG.balance, order: null, pos: null, trades: [], day: dayKey(), dayTrades: 0, dayLosses: 0, note: '' };
  const oa = mode === 'oanda' ? {
    host: 'https://api-fxpractice.oanda.com/v3', token: process.env.OANDA_TOKEN, acct: process.env.OANDA_ACCOUNT,
  } : null;
  if (oa && (!oa.token || !oa.acct)) { console.error('OANDA mode needs OANDA_TOKEN and OANDA_ACCOUNT environment variables (practice account).'); process.exit(1); }
  const api = async (method, p, body) => {
    const r = await fetch(oa.host + p, { method, headers: { Authorization: `Bearer ${oa.token}`, 'Content-Type': 'application/json', 'Accept-Datetime-Format': 'RFC3339' }, body: body ? JSON.stringify(body) : undefined });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`OANDA ${r.status}: ${j.errorMessage || JSON.stringify(j).slice(0, 200)}`);
    return j;
  };
  const instr = (sym) => /XAU|GOLD/i.test(sym) ? 'XAU_USD' : /WTI|USOIL|CL1|MCL/i.test(sym) ? 'WTICO_USD' : null;
  const px = (x) => Number(x).toFixed(3);
  const rollDay = () => { const d = dayKey(); if (d !== st.day) Object.assign(st, { day: d, dayTrades: 0, dayLosses: 0 }); };
  const closeTrade = (exit, reason, pnlOverride) => {
    const p = st.pos; if (!p) return;
    const gross = (exit - p.entry) * p.side * p.units;
    const pnl = pnlOverride != null ? pnlOverride : gross - CFG.spread * p.units;
    const R = pnl / (Math.abs(p.entry - p.sl) * p.units);
    st.balance += pnl;
    const t = { ...p, closed: now(), exit: +exit.toFixed(3), pnl: +pnl.toFixed(2), R: +R.toFixed(2), reason, mode, side: p.side === 1 ? 'LONG' : 'SHORT' };
    st.trades.push(t); if (st.trades.length > 50) st.trades.shift();
    if (pnl < 0) st.dayLosses++;
    csvAppend(t);
    log({ type: 'BOT_CLOSED', symbol: p.symbol, msg: `${t.side} ${reason} @ ${t.exit} · ${t.pnl >= 0 ? '+' : ''}${t.pnl} (${t.R}R) · balance ${st.balance.toFixed(2)}` });
    notify(`BOT ${mode}: ${reason}`, `${t.side} ${p.symbol} ${t.pnl >= 0 ? '+' : ''}${t.pnl} (${t.R}R)`, true);
    st.pos = null;
  };
  return {
    state: () => ({ mode, balance: +st.balance.toFixed(2), pnl: +(st.balance - st.start).toFixed(2), order: st.order, pos: st.pos,
      trades: st.trades.slice(-10), dayTrades: st.dayTrades, dayLosses: st.dayLosses, note: st.note }),
    async place(src, snap, sig, lv) {
      rollDay();
      const lvls = parseLv(lv); const side = /LONG/i.test(sig) ? 1 : /SHORT/i.test(sig) ? -1 : 0;
      const skip = (why) => { st.note = why; log({ type: 'BOT_SKIP', symbol: snap.symbol, msg: `${src}: ${why}` }); };
      if (!CFG.tradeFrom.includes(src)) return;
      if (!lvls || !side) return skip('could not read levels');
      if (st.busy) return skip('another order is being placed');
      if (st.order || st.pos) return skip('already have an order/position');
      if (st.dayLosses >= CFG.maxLossDay) return skip(`daily loss limit (${CFG.maxLossDay}) reached`);
      if (st.dayTrades >= CFG.maxTradesDay) return skip(`max trades/day (${CFG.maxTradesDay}) reached`);
      if (/CONFLICT/.test((kv(snap.panels?.['SK SEQ'] || [])['Filters']) || '')) return skip('EIE × SK conflict');
      const dist = Math.abs(lvls.entry - lvls.sl);
      const units = Math.floor(CFG.riskUsd / dist);
      if (units < 1) return skip(`stop ${dist.toFixed(2)} too wide for $${CFG.riskUsd} risk`);
      const o = { src, symbol: snap.symbol, side, ...lvls, units, opened: now() };
      if (mode === 'oanda') {
        const ins = instr(snap.symbol); if (!ins) return skip(`no OANDA instrument for ${snap.symbol}`);
        try {
          const j = await api('POST', `/accounts/${oa.acct}/orders`, { order: { type: 'LIMIT', instrument: ins, units: String(side * units), price: px(lvls.entry), timeInForce: 'GTC',
            stopLossOnFill: { price: px(lvls.sl) }, takeProfitOnFill: { price: px(lvls.tp) }, clientExtensions: { tag: 'eie-watch', comment: src } } });
          o.id = j.orderCreateTransaction?.id; o.ins = ins;
          if (j.orderFillTransaction) { st.pos = { ...o, tradeId: j.orderFillTransaction.tradeOpened?.tradeID, fill: Number(j.orderFillTransaction.price) }; st.dayTrades++; }
          else st.order = o;
        } catch (e) { return skip(e.message); }
      } else if (mode === 'tv' || mode === 'tv-dry') {
        st.busy = true;
        try {
          const r = await tvPlaceOrder({ side, units, entry: lvls.entry, sl: lvls.sl, tp: lvls.tp, symbol: snap.symbol, dry: mode === 'tv-dry' });
          if (!r.placed) { st.note = `dry run OK: "${r.summary}" (not placed)`; log({ type: 'BOT_DRYRUN', symbol: snap.symbol, msg: `TradingView dialog filled and verified: ${r.summary}` });
            notify('BOT tv-dry: dialog filled', r.summary, true); return; }
          o.tvSummary = r.summary; st.order = o;
          if (!r.verified) {
            st.note = `order clicked but not confirmed in the Orders tab (${r.ordersBefore} → ${r.ordersAfter}) — CHECK TradingView; no further orders until it is cleared`;
            notify('BOT tv: CHECK ORDERS TAB', st.note, true);
          }
        } catch (e) { notify('BOT tv: order NOT placed', e.message, true); return skip(e.message); }
        finally { st.busy = false; }
      } else st.order = o;
      st.note = '';
      log({ type: 'BOT_ORDER', symbol: snap.symbol, msg: `${mode}: ${side === 1 ? 'BUY' : 'SELL'} LIMIT ${units} @ ${lvls.entry} · SL ${lvls.sl} · TP ${lvls.tp} (${src})` });
      if (mode === 'tv') csvAppend({ opened: o.opened, closed: '', mode, src, symbol: o.symbol, side: side === 1 ? 'LONG' : 'SHORT', entry: lvls.entry, sl: lvls.sl, tp: lvls.tp, units, exit: '', pnl: '', R: '', reason: 'ORDER PLACED in TradingView Paper' });
      notify(`BOT ${mode}: order placed`, `${side === 1 ? 'BUY' : 'SELL'} ${units} ${snap.symbol} @ ${lvls.entry} · SL ${lvls.sl} · TP ${lvls.tp}`, true);
    },
    async move(src, snap, lv) {
      const o = st.order; const lvls = parseLv(lv); if (!o || o.src !== src || !lvls) return;
      if (mode === 'tv') { st.note = `move your TradingView order to ${lvls.entry} · SL ${lvls.sl} · TP ${lvls.tp}`;
        log({ type: 'BOT_MOVE_MANUAL', symbol: snap.symbol, msg: st.note }); notify('BOT tv: MOVE ORDER (manual)', st.note, true); Object.assign(o, lvls); return; }
      const units = Math.floor(CFG.riskUsd / Math.abs(lvls.entry - lvls.sl)); if (units < 1) return this.cancel(src, snap, 'stop too wide after update');
      if (mode === 'oanda') {
        try { const j = await api('PUT', `/accounts/${oa.acct}/orders/${o.id}`, { order: { type: 'LIMIT', instrument: o.ins, units: String(o.side * units), price: px(lvls.entry), timeInForce: 'GTC',
          stopLossOnFill: { price: px(lvls.sl) }, takeProfitOnFill: { price: px(lvls.tp) }, clientExtensions: { tag: 'eie-watch', comment: src } } });
          o.id = j.orderCreateTransaction?.id || o.id; } catch (e) { st.note = e.message; return; }
      }
      Object.assign(o, lvls, { units });
      log({ type: 'BOT_MOVE', symbol: snap.symbol, msg: `${mode}: limit moved → ${lvls.entry} · SL ${lvls.sl} · TP ${lvls.tp} · ${units} units` });
    },
    async cancel(src, snap, why = 'signal cancelled') {
      const o = st.order; if (!o || o.src !== src) return;
      if (mode === 'oanda') { try { await api('PUT', `/accounts/${oa.acct}/orders/${o.id}/cancel`); } catch (e) { st.note = e.message; } }
      if (mode === 'tv' && /^setup finished/.test(why)) { st.order = null; log({ type: 'BOT_DONE', symbol: snap.symbol, msg: 'tv: setup finished — TradingView manages the bracket (check Order history)' }); return; }
      if (mode === 'tv') notify('BOT tv: CANCEL ORDER (manual)', `Cancel ${o.side === 1 ? 'BUY' : 'SELL'} ${o.units} @ ${o.entry} in TradingView's Orders tab — ${why}`, true);
      st.order = null;
      log({ type: 'BOT_CANCEL', symbol: snap.symbol, msg: `${mode}: order cancelled (${why})` });
      notify(`BOT ${mode}: order cancelled`, `${o.symbol} ${why}`);
    },
    lastPoll: 0,
    async tick(snap) {
      rollDay();
      if (mode === 'paper') {
        const c = snap.bar?.c; if (c == null || snap.symbol !== (st.order || st.pos || {}).symbol) return;
        if (st.order) {
          const o = st.order;
          if (o.side === 1 ? c <= o.entry : c >= o.entry) {        // limit touched → filled at the limit
            st.pos = { ...o, fill: o.entry }; st.order = null; st.dayTrades++;
            log({ type: 'BOT_FILLED', symbol: o.symbol, msg: `paper: ${o.side === 1 ? 'LONG' : 'SHORT'} ${o.units} @ ${o.entry}` });
            notify('BOT paper: filled', `${o.side === 1 ? 'LONG' : 'SHORT'} ${o.units} ${o.symbol} @ ${o.entry}`, true);
          }
        }
        const p = st.pos;
        if (p) {
          if (p.side === 1 ? c <= p.sl : c >= p.sl) closeTrade(p.side === 1 ? Math.min(c, p.sl) : Math.max(c, p.sl), 'STOP');   // stops fill at the worse price
          else if (p.side === 1 ? c >= p.tp : c <= p.tp) closeTrade(p.tp, 'TARGET');
        }
      } else if (mode === 'oanda' && Date.now() - this.lastPoll > 10000 && (st.order || st.pos)) {
        this.lastPoll = Date.now();
        try {
          if (st.order) {
            const j = await api('GET', `/accounts/${oa.acct}/orders/${st.order.id}`);
            if (j.order?.state === 'FILLED') {
              st.pos = { ...st.order, tradeId: j.order.tradeOpenedID }; st.order = null; st.dayTrades++;
              log({ type: 'BOT_FILLED', symbol: st.pos.symbol, msg: `oanda: trade ${st.pos.tradeId} opened` });
              notify('BOT oanda: filled', `${st.pos.symbol} trade ${st.pos.tradeId}`, true);
            } else if (j.order && j.order.state !== 'PENDING') { log({ type: 'BOT_CANCEL', symbol: st.order.symbol, msg: `oanda: order ${j.order.state}` }); st.order = null; }
          } else if (st.pos?.tradeId) {
            const j = await api('GET', `/accounts/${oa.acct}/trades/${st.pos.tradeId}`);
            if (j.trade?.state === 'CLOSED') {
              const exit = Number(j.trade.averageClosePrice || 0); const pnl = Number(j.trade.realizedPL || 0);
              closeTrade(exit, pnl >= 0 ? 'TARGET/CLOSED' : 'STOP/CLOSED', pnl);
            }
          }
        } catch (e) { st.note = e.message; }
      }
    },
  };
}
const BROKER = ['paper', 'oanda', 'tv', 'tv-dry'].includes(CFG.trade) ? makeBroker(CFG.trade) : null;

// ── Operation Aurum dashboard server ─────────────────────────────────────────
const VENDOR = {
  'react.js': 'react/umd/react.production.min.js',
  'react-dom.js': 'react-dom/umd/react-dom.production.min.js',
  'htm.js': 'htm/dist/htm.umd.js',
  'lightweight-charts.js': 'lightweight-charts/dist/lightweight-charts.standalone.production.js',
};
function kvAll(panels) { const o = {}; for (const [n, rows] of Object.entries(panels || {})) o[n] = kv(rows); return o; }
function startUi() {
  const uiFile = path.join(SCRIPT_DIR, 'ui.html');
  const server = http.createServer((req, res) => {
    const url = (req.url || '/').split('?')[0];
    if (url === '/' || url === '/index.html') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return fs.createReadStream(uiFile).on('error', () => res.end('ui.html missing')).pipe(res);
    }
    if (url.startsWith('/vendor/') && VENDOR[url.slice(8)]) {
      res.writeHead(200, { 'Content-Type': 'application/javascript; charset=utf-8', 'Cache-Control': 'max-age=86400' });
      return fs.createReadStream(path.join(CFG.vendor, VENDOR[url.slice(8)])).on('error', () => res.end('// vendor file missing: run npm install in ~/eie-watch')).pipe(res);
    }
    if (url === '/api/state') { res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify(UI)); }
    if (url === '/api/stream') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
      const send = () => res.write(`data: ${JSON.stringify(UI)}\n\n`);
      send();
      const id = setInterval(send, 1000);
      req.on('close', () => clearInterval(id));
      return;
    }
    res.writeHead(404); res.end('not found');
  });
  server.listen(CFG.port, '127.0.0.1', () => console.log(`Operation Aurum dashboard: http://localhost:${CFG.port}`));
  server.on('error', (e) => console.error('dashboard server error:', e.message));
}


// ══════════════════════════════════════════════════════════════════════════
// MONTE CARLO WAR ROOM — multi-core, real-time prop-firm simulation on this Mac
// Reads the live Results rows of the SK / EIE panels, runs paths on (cores − 1) worker threads in
// batches, merges the results and publishes them to the dashboard once a second. Restarts when the
// results change, idles when the target number of paths is reached (no constant CPU burn).
// ══════════════════════════════════════════════════════════════════════════
const MCW = {
  on: !flag('--mc-off') && CFG.ui,
  from: arg('--mc-from', 'SK SEQ'),
  target: Number(arg('--mc-paths', 200000)),
  batch: 5000,
  P: { risk: Number(arg('--mc-risk', 0.5)), target: Number(arg('--mc-target', 8)), maxLoss: Number(arg('--mc-max', 10)),
       dailyLoss: Number(arg('--mc-daily', 5)), perDay: Number(arg('--mc-perday', 4)), horizon: Number(arg('--mc-horizon', 150)),
       costR: Number(arg('--mc-cost', 0.08)), bayes: !flag('--mc-no-bayes'), sample: 12 },
  pool: [], busy: new Set(), key: '', gen: 0, seed: 1,
  agg: null, reservoir: [], live: [], conv: [], t0: 0, lastPub: 0, src: null,
};
function mcParse(rowText) {
  const m = String(rowText || '').match(/(\d+)\s*·\s*([\d.]+)%\s*·\s*([+-]?[\d.]+)R/);
  return m ? { n: +m[1], wr: +m[2] / 100, avgR: +m[3] } : null;
}
function mcSource(panels) {
  const pick = (name, rows) => { for (const [row, label] of rows) { const r = mcParse((panels[name] || {})[row]); if (r && r.n >= 20) return { ...r, label: `${name} · ${label}` }; } return null; };
  const sk = [['Results (filtered)', 'filtered'], ['Results (RAW)', 'RAW']];
  const eie = [['Results PRO', 'PRO'], ['Results RAW', 'RAW']];
  return MCW.from === 'EIE PRO' ? (pick('EIE PRO', eie) || pick('SK SEQ', sk)) : (pick('SK SEQ', sk) || pick('EIE PRO', eie));
}
function mcStartPool() {
  if (MCW.pool.length) return;
  const nWorkers = Math.max(1, os.cpus().length - 1);
  for (let i = 0; i < nWorkers; i++) {
    const w = new Worker(path.join(SCRIPT_DIR, 'mc-worker.mjs'));
    w.on('message', (msg) => mcMerge(w, msg));
    w.on('error', (e) => { console.error('mc worker:', e.message); MCW.busy.delete(w); });
    MCW.pool.push(w);
  }
}
function mcReset(src) {
  MCW.gen++;
  MCW.src = src;
  MCW.agg = { done: 0, pass: 0, breach: 0, daily: 0, open: 0, ttpSum: 0, ddBins: new Array(41).fill(0), stBins: new Array(31).fill(0) };
  MCW.reservoir = []; MCW.live = []; MCW.conv = []; MCW.t0 = Date.now(); MCW.tDone = 0; MCW.vizDone = 0;
}
function mcMerge(w, msg) {
  MCW.busy.delete(w);
  if (msg.id !== MCW.gen || !MCW.agg) return;                    // result from an outdated scenario
  MCW.batches = (MCW.batches || 0) + 1;
  if (typeof teleLine === 'function') teleLine(`[mc] core ${MCW.pool.indexOf(w) + 1} · ${msg.viz ? 'live' : 'batch'} #${MCW.batches} · ${msg.n.toLocaleString()} paths · ${w._t0 ? Date.now() - w._t0 : '?'} ms · pass ${(100 * msg.pass / msg.n).toFixed(1)}% · breach ${(100 * msg.breach / msg.n).toFixed(1)}%`);
  if (msg.viz) {                                                  // visual refresh only: new live paths, stats unchanged
    for (const sp of msg.sampled) MCW.live.push(sp);
    if (MCW.live.length > 36) MCW.live.splice(0, MCW.live.length - 36);
    MCW.vizDone = (MCW.vizDone || 0) + msg.n;
    return;
  }
  const a = MCW.agg;
  a.done += msg.n; a.pass += msg.pass; a.breach += msg.breach; a.daily += msg.daily; a.open += msg.open; a.ttpSum += msg.ttpSum;
  msg.ddBins.forEach((v, i) => { a.ddBins[i] += v; });
  msg.stBins.forEach((v, i) => { a.stBins[i] += v; });
  for (const s of msg.sampled) { MCW.reservoir.push(s); MCW.live.push(s); }
  if (MCW.reservoir.length > 800) MCW.reservoir.splice(0, MCW.reservoir.length - 800);
  if (MCW.live.length > 36) MCW.live.splice(0, MCW.live.length - 36);
  if (a.done >= MCW.target && !MCW.tDone) MCW.tDone = Date.now();
  MCW.conv.push([a.done, a.pass / a.done]);
  if (MCW.conv.length > 200) MCW.conv.splice(0, MCW.conv.length - 200);
  mcDispatch();
}
function mcDispatch() {
  if (!MCW.agg || !MCW.src) return;
  for (const w of MCW.pool) {
    if (MCW.busy.has(w)) continue;
    const queued = MCW.agg.done + MCW.busy.size * MCW.batch;
    if (queued >= MCW.target) break;
    MCW.busy.add(w); w._t0 = Date.now();
    w.postMessage({ id: MCW.gen, n: MCW.batch, seed: (MCW.seed = (MCW.seed * 1103515245 + 12345) >>> 0), P: MCW.P2 });
  }
}
function mcTick(panels) {
  if (!MCW.on) return;
  const src = mcSource(panels || {});
  const key = src ? `${src.label}|${src.n}|${src.wr}|${src.avgR}` : '';
  if (key !== MCW.key) {
    MCW.key = key;
    if (src) {
      mcStartPool();
      const L = -(1 + MCW.P.costR);
      const p = Math.min(0.99, Math.max(0.01, src.wr));
      const W = Math.min(10, Math.max(0.2, (src.avgR - (1 - p) * L) / p));   // average winner implied by win rate and average R
      const wins = Math.round(src.wr * src.n);
      MCW.P2 = { ...MCW.P, W, L, wins, losses: src.n - wins };
      mcReset(src);
      mcDispatch();
    } else { MCW.src = null; MCW.agg = null; }
  }
  // after a full run, keep the War Room alive: 1,000 fresh paths every 1.5 s for the animation only
  if (MCW.agg && MCW.agg.done >= MCW.target && Date.now() - (MCW.lastViz || 0) > 1500) {
    const w = MCW.pool.find((x) => !MCW.busy.has(x));
    if (w) { MCW.busy.add(w); w._t0 = Date.now(); MCW.lastViz = Date.now(); w.postMessage({ id: MCW.gen, viz: true, n: 1000, seed: (MCW.seed = (MCW.seed * 1103515245 + 12345) >>> 0), P: { ...MCW.P2, sample: 24 } }); }
  }
  if (Date.now() - MCW.lastPub < 1000) return;
  MCW.lastPub = Date.now();
  if (!MCW.agg) { UI.mc = { status: 'waiting', note: 'needs 20+ trades in the SK or EIE Results rows', cores: MCW.pool.length || Math.max(1, os.cpus().length - 1) }; return; }
  const a = MCW.agg, H = MCW.P.horizon;
  const bands = [5, 25, 50, 75, 95].map(() => new Array(H + 1).fill(0));
  const R = MCW.reservoir;
  if (R.length >= 20) {
    const col = new Array(R.length);
    for (let k = 0; k <= H; k++) {
      for (let i = 0; i < R.length; i++) col[i] = R[i].e[k];
      col.sort((x, y) => x - y);
      [5, 25, 50, 75, 95].forEach((pc, j) => { bands[j][k] = col[Math.min(R.length - 1, Math.floor(pc / 100 * R.length))]; });
    }
  }
  const secs = Math.max(0.001, ((MCW.tDone || Date.now()) - MCW.t0) / 1000);
  UI.mc = {
    status: a.done >= MCW.target ? 'complete' : 'running', source: MCW.src, model: { W: MCW.P2.W, L: MCW.P2.L, wins: MCW.P2.wins, losses: MCW.P2.losses, bayes: MCW.P.bayes },
    rules: MCW.P, cores: MCW.pool.length, done: a.done, target: MCW.target, pps: a.done / secs,
    pass: a.pass / (a.done || 1), breach: a.breach / (a.done || 1), daily: a.daily / (a.done || 1), open: a.open / (a.done || 1),
    ttp: a.pass ? a.ttpSum / a.pass : null, ddBins: a.ddBins, stBins: a.stBins, bands, live: MCW.live.slice(-24), conv: MCW.conv, elapsed: secs, viz: MCW.vizDone || 0,
  };
}

// ── SYNC strip, chart overlays and telemetry for the dashboard ─────────────
async function syncTick(reader, snap) {
  const now = Date.now();
  if (reader.settings && now - TELE.lastSettings > 15000) {
    TELE.lastSettings = now;
    const studies = await reader.settings().catch(() => null);
    if (studies) {
      const out = [];
      for (const st of studies) {
        const key = st.name.replace(/ v\d+.*$/, '');
        const vals = Object.fromEntries(st.inputs.map(i => [i.name, i.value]));
        const f = fp(vals);
        const prev = TELE.fp[key];
        if (prev && prev.f !== f) {
          const changed = Object.keys(vals).filter(k => JSON.stringify(vals[k]) !== JSON.stringify(prev.vals[k]));
          TELE.changedAt[key] = now;
          log({ type: 'SETTINGS_CHANGED', symbol: snap.symbol, msg: `${key}: ${changed.slice(0, 4).map(k => `${k} ${JSON.stringify(prev.vals[k])}→${JSON.stringify(vals[k])}`).join(' · ')}${changed.length > 4 ? ` · +${changed.length - 4} more` : ''}` });
          teleLine(`[sync] ${key} settings changed · fingerprint ${prev.f} → ${f}`);
        }
        TELE.fp[key] = { f, vals };
        out.push({ name: st.name, ver: (st.name.match(/ v(\d+)/) || [])[1] || '?', fp: f, n: st.inputs.length, changedAt: TELE.changedAt[key] || null });
      }
      UI.sync = { studies: out, checkedAt: now };
      teleLine(`[sync] ${out.length} indicators verified · ${out.map(o => o.name.split(' (')[0] + ' #' + o.fp).join(' · ')}`);
    }
  }
  if (UI.sync) Object.assign(UI.sync, { panelsAt: now, readMs: TELE.readMs, chart: `${snap.symbol} · ${snap.tf}m` });
  if (reader.drawings && now - TELE.lastDraw > 5000) {
    TELE.lastDraw = now;
    const d = await reader.drawings().catch(() => null);
    if (d) {
      const markers = [];
      for (const l of d.labels) {
        const t = String(l.t || '').trim();
        if (l.time == null || l.y == null) continue;
        const wave = l.src === 'EIE' && /^([0-5]|A|B|C)~?$/.test(t);
        const sk = l.src === 'SK' && /^SK|^✖/.test(t);
        const choch = t === 'CHoCH';
        if (!(wave || sk || choch)) continue;
        markers.push({ time: Math.floor(l.time > 1e12 ? l.time / 1000 : l.time), text: t, src: l.src, price: l.y });
      }
      const zones = d.boxes.filter(b => b.y1 != null && b.y2 != null).sort((a, b) => (b.x1 || 0) - (a.x1 || 0)).slice(0, 6)
        .map(b => ({ top: Math.max(b.y1, b.y2), bot: Math.min(b.y1, b.y2), text: String(b.t || '').split('·')[0].trim() || (b.src + ' zone'), src: b.src }));
      const trail = (String((UI.panels['SK SEQ'] || {})['SuperTrend AI'] || '').match(/trail ([\d.]+)/) || [])[1];
      UI.overlays = { markers: markers.sort((a, b) => a.time - b.time).slice(-80), zones, trail: trail ? Number(trail) : null };
      teleLine(`[draw] ${markers.length} chart labels · ${zones.length} zones${trail ? ' · ST trail ' + trail : ''} mirrored to the dashboard`);
    }
  }
  TELE.evTimes = TELE.evTimes.filter(t => now - t < 60000);
  const mu = process.memoryUsage();
  UI.tele = { uptime: (now - TELE.start) / 1000, reads: TELE.reads, readMs: TELE.readMs, rssMB: mu.rss / 1048576, heapMB: mu.heapUsed / 1048576,
    evPerMin: TELE.evTimes.length, workers: MCW.pool.length, busy: [...MCW.pool].map(w => MCW.busy.has(w)), batches: MCW.batches || 0, feed: TELE.feed.slice(-40) };
}

// ── trade signals from the EIE PRO / SK SEQ compact panels (no TradingView alerts needed) ──
const RUN_ID = Date.now();
const sigPrev = new Map();
let chartKey = null, chartChangedAt = 0;
let SETTLE_MS = argv.includes('--selftest') ? 0 : 15000;   // after a symbol / timeframe change, panels show stale then historical states: never act on those
function kv(rows) {
  const m = {};
  for (const r of rows || []) { const [k, ...v] = r.split(' | '); if (k && v.length) m[k.trim()] = v.join(' | ').trim(); }
  return m;
}
function processSignals(snap) {
  const out = [];
  const ck = `${snap.symbol}|${snap.tf}`;
  if (ck !== chartKey) {
    if (chartKey !== null) out.push(log({ type: 'CHART_CHANGED', symbol: snap.symbol, msg: `now ${snap.tf}m · ignoring signals for ${SETTLE_MS / 1000}s while indicators recalculate` }));
    chartKey = ck; chartChangedAt = Date.now();
  }
  for (const [name, rows] of Object.entries(snap.panels || {})) {
    const p = kv(rows);
    const sig = p['Signal'];
    if (!sig) continue;
    const lv = p['Entry · SL · TP'] || '—';
    const key = `${name}|${snap.symbol}|${snap.tf}`;
    const prev = sigPrev.get(key);
    sigPrev.set(key, { sig, lv });
    if (Date.now() - chartChangedAt < SETTLE_MS) continue;   // settling after a chart change: record state only
    if (!prev) { out.push(log({ type: 'SIGNAL_START', symbol: snap.symbol, msg: `${name}: ${sig} ${lv !== '—' ? '· ' + lv : ''}` })); continue; }
    const isLimit = (x) => /limit placed|^LIMIT/i.test(x);
    const isTrade = (x) => /in trade/i.test(x);
    const head = `${name} ${snap.symbol} ${snap.tf}m`;
    if (sig !== prev.sig) {
      if (isLimit(sig)) {
        if (BROKER) BROKER.place(name, snap, sig, lv).catch(e => console.error('bot:', e.message));
        out.push(log({ type: 'PLACE_LIMIT', symbol: snap.symbol, msg: `${name}: ${sig} · Entry·SL·TP ${lv}` }));
        notify(`${head}: PLACE LIMIT`, `${sig}\nEntry · SL · TP: ${lv}\nRisk $25 → lots = 25 ÷ (stop distance × 100)`, true);
      } else if (isTrade(sig)) {
        out.push(log({ type: 'FILLED', symbol: snap.symbol, msg: `${name}: ${sig} · ${lv}` }));
        notify(`${head}: FILLED`, `${sig} · ${lv}\nDon't touch it: stop or target.`, true);
      } else if (isLimit(prev.sig)) {
        if (BROKER && !isTrade(sig)) BROKER.cancel(name, snap).catch(e => console.error('bot:', e.message));
        out.push(log({ type: 'CANCEL_LIMIT', symbol: snap.symbol, msg: `${name}: limit no longer valid → ${sig}` }));
        notify(`${head}: CANCEL LIMIT`, `Cancel the pending order (${prev.lv}). Now: ${sig}`, true);
      } else if (isTrade(prev.sig)) {
        if (BROKER) BROKER.cancel(name, snap, 'setup finished before the bot was filled').catch(e => console.error('bot:', e.message));
        const res = p['Results PRO'] || p['Results (filtered)'] || '';
        out.push(log({ type: 'TRADE_CLOSED', symbol: snap.symbol, msg: `${name}: closed · results ${res}` }));
        notify(`${head}: trade closed`, `Results: ${res}`);
      } else {
        out.push(log({ type: 'SIGNAL', symbol: snap.symbol, msg: `${name}: ${prev.sig} → ${sig}` }));
      }
    } else if (isLimit(sig) && lv !== prev.lv) {
      if (BROKER) BROKER.move(name, snap, lv).catch(e => console.error('bot:', e.message));
      out.push(log({ type: 'MOVE_LIMIT', symbol: snap.symbol, msg: `${name}: levels updated ${prev.lv} → ${lv}` }));
      notify(`${head}: MOVE LIMIT`, `New Entry · SL · TP: ${lv}`, true);
    }
  }
  return out;
}

// ── main loop ───────────────────────────────────────────────────────────────
async function main(reader) {
  const h = await reader.health().catch(e => ({ success: false, error: e.message }));
  if (!h?.cdp_connected) {
    console.error('Cannot reach TradingView on port 9222. Launch it with:\n  open -a TradingView --args --remote-debugging-port=9222');
    process.exit(1);
  }
  console.log(`EIE Watch running · interval ${CFG.interval / 1000}s · logs in ${CFG.dir} · Ctrl+C to stop`);
  if (CFG.ui) startUi();
  if (BROKER) console.log(`Auto-trader: ${CFG.trade} · risk $${CFG.riskUsd}/trade · max ${CFG.maxTradesDay} trades & ${CFG.maxLossDay} losses/day · log ${TRADES_CSV}`);
  UI.demo = CFG.demo;
  let lastBars = 0;
  let stop = false; const end = () => { stop = true; };
  process.on('SIGINT', end); process.on('SIGTERM', end);
  let lastReport = Date.now(), rotIdx = 0, rotAt = 0;
  while (!stop) {
    try {
      if (CFG.rotate.length && Date.now() - rotAt > CFG.dwell) {
        const sym = CFG.rotate[rotIdx++ % CFG.rotate.length];
        await reader.setSymbol(sym); rotAt = Date.now(); await sleep(3000);
      }
      const tRead = Date.now();
      const snap = await reader.snapshot();
      TELE.reads++; TELE.readMs = Date.now() - tRead;
      if (TELE.reads % 15 === 1) teleLine(`[cdp] chart snapshot ${TELE.readMs} ms · ${snap.labels.length} EIE labels · ${(snap.table || []).length} panel rows · ${snap.symbol} ${snap.tf}m`);
      process1(snap);
      processSignals(snap);
      if (BROKER) { await BROKER.tick(snap); UI.broker = BROKER.state(); }
      if (CFG.ui) {
        const symChanged = snap.symbol !== UI.symbol || snap.tf !== UI.tf;
        Object.assign(UI, { connected: true, symbol: snap.symbol, tf: snap.tf, last: snap.bar?.c ?? UI.last, panels: kvAll(snap.panels) });
        mcTick(UI.panels);
        await syncTick(reader, snap);
        if (symChanged || Date.now() - lastBars > 5000) { UI.bars = await reader.ohlcv().catch(() => UI.bars); lastBars = Date.now(); }
      }
    } catch (e) {
      UI.connected = false;
      if (!/CDP|ECONNREFUSED|loading/i.test(e.message)) console.error('error:', e.message);
      await sleep(2000);
    }
    if (Date.now() - lastReport > 600000) { writeReport(); saveLedger(); lastReport = Date.now(); }
    await sleep(CFG.interval);
  }
  writeReport(); saveLedger();
  console.log(`\nStopped. Repaint audit written to ${REPORT}`);
  process.exit(0);
}

// ── demo feed for the dashboard (synthetic random walk, cycling signals) ───────
function makeDemoReader() {
  let t = Math.floor(Date.now() / 60000) * 60 - 499 * 60, px = 4125, i = 0;
  const bars = [];
  const step = () => { const o = px; px += (Math.random() - 0.5) * 2.4 + Math.sin(t / 5400) * 0.35; const h = Math.max(o, px) + Math.random() * 0.9, l = Math.min(o, px) - Math.random() * 0.9;
    bars.push({ time: t, open: o, high: h, low: l, close: px }); t += 60; if (bars.length > 500) bars.shift(); };
  for (let k = 0; k < 500; k++) step();
  const phases = [
    ['Wave 2', 'Short', 'setup valid · arming', '—', 'B phase', 'watching entry zone', '—'],
    ['Wave 2', 'Short', 'LIMIT SHORT placed', 'E · S · T', 'B phase', 'B SHORT limit placed', 'E2 · S2 · T2'],
    ['Wave 3', 'Short', 'IN TRADE SHORT', 'E · S · T', 'activated → C', 'B SHORT in trade', 'E2 · S2 · T2'],
    ['Scanning', '—', 'waiting for wave 2', '—', 'C reached', 'C reached · WCL watch', '—'],
  ];
  return {
    async health() { return { cdp_connected: true }; },
    async setSymbol() {},
    async ohlcv() { return bars.slice(); },
    async settings() {
      const entry = i > 60 ? 0.618 : 0.559;   // demo: one setting changes after ~2 minutes
      return [{ id: 'eie', name: 'Elliott Impulse Engine PRO v9 (personal fork of WillyAlgoTrader EIE)', inputs: [{ id: 'in_0', name: 'Swing Detection Length', value: 10 }, { id: 'in_1', name: 'Point Confirmation, bars', value: 5 }] },
              { id: 'sk', name: 'SK Sequence Engine v15 (personal implementation)', inputs: [{ id: 'in_0', name: 'Pivot length (bars each side)', value: 5 }, { id: 'in_1', name: 'Entry level', value: entry }, { id: 'in_2', name: 'ATR length', value: 21 }] }];
    },
    async drawings() {
      const n = bars.length, at = (k) => bars[Math.max(0, n - k)];
      const lab = (k, t, src, y) => ({ src, t, y: y ?? at(k).close, time: at(k).time });
      const hi = Math.max(...bars.slice(-60).map(b => b.high)), lo = Math.min(...bars.slice(-60).map(b => b.low)), L = hi - lo;
      return { labels: [lab(70, 'CHoCH', 'EIE'), lab(58, '0', 'EIE', hi), lab(40, '1', 'EIE', lo + 0.3 * L), lab(28, '2~', 'EIE', hi - 0.15 * L), lab(12, '3~', 'EIE', lo),
                        lab(60, 'SK0', 'SK', hi + 0.1), lab(38, 'SKA', 'SK', lo + 0.25 * L), lab(25, 'SKB', 'SK', hi - 0.2 * L)],
               boxes: [{ src: 'EIE', t: 'W4 ZONE · optional SELL (manual)', y1: lo + 0.45 * L, y2: lo + 0.6 * L, x1: n - 10 },
                       { src: 'SK', t: 'SK C TARGET 161.8–200% · TAKE PROFIT here', y1: lo - 0.05 * L, y2: lo + 0.08 * L, x1: n - 20 }] };
    },
    async snapshot() {
      i++; if (i % 3 === 0) step();
      const ph = phases[Math.floor(i / 20) % phases.length];
      const hi = Math.max(...bars.slice(-60).map(b => b.high)), lo = Math.min(...bars.slice(-60).map(b => b.low));
      const L = hi - lo, e = (lo + 0.618 * L).toFixed(2), s = (hi + 0.4).toFixed(2), tp = (e - 2 * (s - e)).toFixed(2);
      const e2 = (lo + 0.559 * L).toFixed(2), s2 = (hi + 0.5).toFixed(2), t2 = (e2 - 2 * (s2 - e2)).toFixed(2);
      const sub = (x) => x.replace('E2', e2).replace('S2', s2).replace('T2', t2).replace('E', e).replace('S', s).replace('T', tp);
      const last = bars[bars.length - 1];
      return {
        symbol: 'OANDA:XAUUSD', tf: '1', studyFound: true, labels: [], boxes: [],
        table: [`State | ${ph[0]}`, `Direction | ${ph[1]}`, `Invalidation | ${(hi + 0.4).toFixed(2)}`, `Last Reset | BELOW_0`],
        bar: { first: 0, last: 1000 + i, c: last.close, h: last.high, l: last.low },
        panels: {
          'EIE PRO': ['◆ EIE PRO | OANDA:XAUUSD · 1', `State | ${ph[0]}`, `Direction | ${ph[1]}`, `Invalidation | ${(hi + 0.4).toFixed(2)}`, 'Last Reset | BELOW_0',
            `Signal | ${ph[2]}`, `Entry · SL · TP | ${sub(ph[3])}`, 'P(fill) · P(win) · EV | 61% · 47% · +0.18R', 'Filters | 7/8 ✗ ER',
            'Results PRO | 9 · 55.6% · +0.41R', 'Results RAW | 31 · 42.0% · +0.22R', 'Learner | 31/30 · gating · skill +0.04',
            `Count check | ${i % 40 < 20 ? '✓ no W1/W4 overlap' : '⚠ wave 4 overlaps wave 1: count suspect'}`],
          'SK SEQ': ['◆ SK SEQ | OANDA:XAUUSD · 1', `Sequence | ${ph[4]} · bear`, `0 · A | ${hi.toFixed(2)} · ${lo.toFixed(2)}`,
            `B · C | ${(lo + 0.55 * L).toFixed(2)} · ${(hi - 1.618 * L * 0.5).toFixed(2)}–${(hi - 2 * L * 0.5).toFixed(2)}`,
            `Signal | ${ph[5]}`, `Entry · SL · TP | ${sub(ph[6])}`, 'P(fill) · P(win) · EV | 68% · 44% · +0.12R', `Filters | HTF ▼ · VR 1.06 · time ✓ · EIE ${i % 60 < 40 ? '▼' : '▲ ⚠ CONFLICT'}`,
            'Results (filtered) | 6 · 50% · +0.35R', 'Results (RAW) | 22 · 40.9% · +0.15R', 'Learner | 22/30 · learning · skill —',
            `SuperTrend AI | ▼ DOWN · trail ${(hi + 0.3).toFixed(2)} · factor 4.0 · vol med · strength 0.31 · votes`],
        },
      };
    },
  };
}

// ── offline self-test (no TradingView) ───────────────────────────────────────
async function selftest() {
  const base = { symbol: 'OANDA:XAUUSD', tf: '1', studyFound: true, boxes: [] };
  const tbl = (s, d, inv, r = '—') => [`◆ EIE`, `State | ${s}`, `Direction | ${d}`, `Invalidation | ${inv}`, `Last Reset | ${r}`, `TF | 1`];
  const L = (t, p, x) => ({ text: t, price: p, x, time: 1e9 + x * 60 });
  const snaps = [
    { ...base, labels: [L('CHoCH', 4100, 90)], table: tbl('Scanning', '—', '—'), bar: { first: 0, last: 100, c: 4101, h: 4102, l: 4100 } },
    { ...base, labels: [L('CHoCH', 4100, 90), L('CHoCH', 4095, 97), L('0', 4090, 95)], table: tbl('CHoCH · wait 1', 'Long', '4090'), bar: { first: 0, last: 101, c: 4105, h: 4106, l: 4104 } },
    { ...base, labels: [L('CHoCH', 4100, 90), L('0', 4090, 95), L('1', 4110, 100)], boxes: [{ high: 4100, low: 4096, x1: 100 }], table: tbl('Wave 2', 'Long', '4090'), bar: { first: 0, last: 105, c: 4104, h: 4105, l: 4103 } },
    { ...base, labels: [L('CHoCH', 4100, 90), L('0', 4090, 95), L('1', 4112, 103)], boxes: [{ high: 4101, low: 4097, x1: 103 }], table: tbl('Wave 2', 'Long', '4090'), bar: { first: 0, last: 107, c: 4099, h: 4103, l: 4098 } },
    { ...base, labels: [L('CHoCH', 4100, 90), L('0', 4091, 96), L('1', 4112, 103)], boxes: [], table: tbl('Wave 2', 'Long', '4090'), bar: { first: 0, last: 108, c: 4099, h: 4100, l: 4098 } },
    { ...base, labels: [L('CHoCH', 4100, 90), L('✖', 4089, 110)], table: tbl('Scanning', '—', '—', 'BELOW_0'), bar: { first: 0, last: 110, c: 4089, h: 4092, l: 4088 } },
    { ...base, labels: [L('CHoCH', 4100.5, 90)], table: tbl('Scanning', '—', '—', '—'), bar: { first: 5, last: 115, c: 4089, h: 4090, l: 4088 } },
  ];
  const types = [];
  for (const s of snaps) for (const e of process1(s)) types.push(e.type);
  const sp = (sig, lv) => ({ symbol: 'OANDA:XAUUSD', tf: '1', panels: { 'SK SEQ': [`Signal | ${sig}`, `Entry · SL · TP | ${lv}`] } });
  for (const x of [sp('watching entry zone', '—'), sp('B SHORT limit placed', '4131 · 4140 · 4113'), sp('B SHORT limit placed', '4132 · 4140 · 4115'),
                   sp('B SHORT in trade', '4132 · 4140 · 4115'), sp('scanning for 0 / A', '—'), sp('B LONG limit placed', '1 · 0 · 3'), sp('watching entry zone', '—')])
    for (const e of processSignals(x)) types.push(e.type);
  SETTLE_MS = 15000;
  const before = types.length;
  for (const e of processSignals({ symbol: 'OANDA:XAUUSD', tf: '30', panels: { 'SK SEQ': ['Signal | waiting', 'Entry · SL · TP | —'] } })) types.push(e.type);
  for (const e of processSignals({ symbol: 'OANDA:XAUUSD', tf: '30', panels: { 'SK SEQ': ['Signal | B LONG limit placed', 'Entry · SL · TP | 1 · 0 · 3'] } })) types.push(e.type);
  const settleOk = types.slice(before).includes('CHART_CHANGED') && !types.slice(before).includes('PLACE_LIMIT');
  console.log('settle after chart change suppresses orders:', settleOk);
  if (!settleOk) { console.log('SELFTEST FAIL (settle)'); process.exit(1); }
  const expect = ['PLACE_LIMIT', 'MOVE_LIMIT', 'FILLED', 'TRADE_CLOSED', 'CANCEL_LIMIT', 'START', 'STATE', 'NEW_POINT', 'STATE', 'NEW_POINT', 'REPOSITION', 'ZONE_TOUCH', 'UNEXPECTED_MOVE', 'STATE', 'RESET', 'REPAINT_SUSPECT'];
  const ok = expect.every(t => types.includes(t));
  console.log('\nevents:', types.join(', '));
  console.log(ok ? 'SELFTEST PASS' : 'SELFTEST FAIL (missing: ' + expect.filter(t => !types.includes(t)).join(',') + ')');
  process.exit(ok ? 0 : 1);
}

// ── one-off test order: BUY 1 unit, limit 2% below market (should not fill), Paper Trading only ──
async function tvTestOrder() {
  let price = Number(arg('--price', NaN)), symbol = arg('--symbol', '');
  if (!Number.isFinite(price) || !symbol) {
    const snap = await (await makeRealReader()).snapshot();
    price = snap.bar?.c; symbol = snap.symbol;
  }
  if (!Number.isFinite(price)) throw new Error('could not read the current price from the chart');
  const entry = +(price * 0.98).toFixed(2), sl = +(entry * 0.995).toFixed(2), tp = +(entry * 1.01).toFixed(2);
  const dry = flag('--dry');
  console.log(`Test order: BUY 1 ${symbol} LIMIT ${entry} · SL ${sl} · TP ${tp}  (2% below ${price}, should not fill)${dry ? '  [dry run]' : ''}`);
  const r = await tvPlaceOrder({ side: 1, units: 1, entry, sl, tp, symbol, dry });
  if (r.placed) {
    csvAppend({ opened: now(), closed: '', mode: 'tv-test', src: 'test', symbol, side: 'LONG', entry, sl, tp, units: 1, exit: '', pnl: '', R: '', reason: 'TEST ORDER placed in TradingView Paper' });
    console.log(r.verified
      ? `PLACED ✓  "${r.summary}" · Orders tab ${r.ordersBefore} → ${r.ordersAfter} (a bracket shows as 3 rows). Cancel it in TradingView (Orders tab → ✕).`
      : `CLICKED Place for "${r.summary}" but the Orders count did not change within 8 s (${r.ordersBefore} → ${r.ordersAfter}). It may still have been placed — check the Orders tab before running again.`);
  } else console.log(`Dialog filled and verified, not placed (dry run): "${r.summary}"`);
}

if (flag('--selftest')) selftest();
else if (flag('--tv-test')) tvTestOrder().then(() => process.exit(0)).catch((e) => { console.error('Test order NOT placed: ' + e.message); process.exit(1); });
else main(CFG.demo ? makeDemoReader() : await makeRealReader());

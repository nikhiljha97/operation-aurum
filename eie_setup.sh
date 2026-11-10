#!/bin/bash
# EIE desk setup for macOS — installs the TradingView Desktop bridge (tradesdontlie/tradingview-mcp),
# the EIE watcher, connects Claude Code, and relaunches TradingView with the local debug port.
# Run:  bash ~/Downloads/eie_setup.sh
set -euo pipefail
[[ "$(uname)" == "Darwin" ]] || { echo "This script is for macOS."; exit 1; }
say(){ printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }

say "1/6 Checking Node.js and git"
if ! command -v git >/dev/null 2>&1; then echo "git missing: a dialog will offer Apple's command line tools. Install them, then re-run this script."; xcode-select --install || true; exit 1; fi
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 18 ]; then
  if command -v brew >/dev/null 2>&1; then brew install node; else
    echo "Node.js 18+ is required. Install the LTS .pkg from https://nodejs.org then re-run this script."; open https://nodejs.org; exit 1; fi
fi
echo "node $(node -v), git ok"

say "2/6 Installing the TradingView Desktop bridge into ~/tradingview-mcp"
if [ -d "$HOME/tradingview-mcp/.git" ]; then git -C "$HOME/tradingview-mcp" pull --ff-only
else git clone https://github.com/tradesdontlie/tradingview-mcp.git "$HOME/tradingview-mcp"; fi
(cd "$HOME/tradingview-mcp" && npm install --no-audit --no-fund)

say "3/6 Writing the EIE watcher into ~/eie-watch"
mkdir -p "$HOME/eie-watch"
cat > "$HOME/eie-watch/eie-watch.mjs" <<'EOF_WATCH'
#!/usr/bin/env node
/**
 * EIE Watch — watches the Elliott Impulse Engine [WillyAlgoTrader] indicator on your
 * TradingView Desktop chart (via tradingview-mcp / Chrome DevTools on localhost:9222),
 * sends macOS notifications on wave events, and audits repainting live.
 *
 * Usage:
 *   node eie-watch.mjs                         # watch the active chart
 *   node eie-watch.mjs --rotate "OANDA:XAUUSD,OANDA:WTICOUSD,BITSTAMP:BTCUSD" --dwell 20   # gold · WTI crude · Bitcoin
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
  spread: arg('--spread', '') === '' ? null : Number(arg('--spread', '')),   // round-trip cost per unit (default: by asset, see ASSETS)
  maxTradesDay: Number(arg('--max-trades', 5)),
  maxLossDay: Number(arg('--max-losses', 2)),
  stateAlerts: flag('--state-alerts'),   // also notify every EIE state change / zone touch (noisy)
  dir: arg('--dir', path.join(os.homedir(), 'eie-watch', ...(argv.includes('--demo') ? ['demo'] : []))),   // demo never touches real logs
  tvMcp: path.resolve(arg('--tvmcp', path.join(os.homedir(), 'tradingview-mcp'))),
};
if (flag('--selftest')) { CFG.dir = fs.mkdtempSync(path.join(os.tmpdir(), 'eie-selftest-')); CFG.notify = false; }
fs.mkdirSync(CFG.dir, { recursive: true });
const EVENTS = path.join(CFG.dir, 'events.jsonl');

// ── supported assets: gold, WTI crude, Bitcoin (anything else gets the generic profile) ──
// step = smallest order size in units; spread = round-trip cost per unit in price (paper P&L only).
const ASSETS = [
  { name: 'GOLD',  re: /XAU|GOLD|^GC|^MGC/i,             step: 1,     spread: () => 0.35,       oanda: 'XAU_USD' },
  { name: 'CRUDE', re: /WTI|USOIL|UKOIL|OIL|^CL|^MCL/i,  step: 1,     spread: () => 0.04,       oanda: 'WTICO_USD' },
  { name: 'BTC',   re: /BTC|XBT/i,                       step: 0.001, spread: (px) => px * 0.0003, oanda: 'BTC_USD' },
];
const GENERIC = { name: 'OTHER', step: 1, spread: (px) => px * 0.0002, oanda: null };
function assetOf(symbol) { const t = String(symbol || '').split(':').pop(); return ASSETS.find(a => a.re.test(t)) || GENERIC; }
function sizeUnits(symbol, riskUsd, stopDist) {
  const a = assetOf(symbol), dec = (String(a.step).split('.')[1] || '').length;
  return +(Math.floor(riskUsd / stopDist / a.step + 1e-9) * a.step).toFixed(dec);
}
const costPerUnit = (symbol, px) => CFG.spread != null ? CFG.spread : assetOf(symbol).spread(px);
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
      if (Math.abs(num(m[2]) - units) > 1e-9) problems.push(`qty ${m[2]} ≠ ${units}`);
      if (m[3].toUpperCase() !== ticker) problems.push(`symbol ${m[3]} ≠ ${ticker}`);
      if (Math.abs(num(m[4]) - entry) > Math.max(0.011, Math.abs(entry) * 2e-6)) problems.push(`price ${m[4]} ≠ ${entry}`);
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
  const instr = (sym) => assetOf(sym).oanda;
  const px = (x) => Number(x).toFixed(3);
  const rollDay = () => { const d = dayKey(); if (d !== st.day) Object.assign(st, { day: d, dayTrades: 0, dayLosses: 0 }); };
  const closeTrade = (exit, reason, pnlOverride) => {
    const p = st.pos; if (!p) return;
    const gross = (exit - p.entry) * p.side * p.units;
    const pnl = pnlOverride != null ? pnlOverride : gross - costPerUnit(p.symbol, p.entry) * p.units;
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
      const units = sizeUnits(snap.symbol, CFG.riskUsd, dist);
      if (!(units > 0)) return skip(`stop ${dist.toFixed(2)} too wide for $${CFG.riskUsd} risk (min size ${assetOf(snap.symbol).step} ${assetOf(snap.symbol).name})`);
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
  // multi-asset sizing: $25 risk → gold 3.2 stop = 7 units · WTI 0.30 stop = 83 units · BTC 450 stop = 0.055 BTC
  const sz = [['OANDA:XAUUSD', 3.2, 7, 'GOLD'], ['TVC:USOIL', 0.30, 83, 'CRUDE'], ['BITSTAMP:BTCUSD', 450, 0.055, 'BTC'], ['COINBASE:BTCUSD', 30000, 0, 'BTC']];
  const sizeOk = sz.every(([sym, d, u, a]) => sizeUnits(sym, 25, d) === u && assetOf(sym).name === a);
  console.log('asset sizing (gold / crude / BTC):', sizeOk, sz.map(([sym, d]) => `${assetOf(sym).name} ${sizeUnits(sym, 25, d)}`).join(' · '));
  if (!sizeOk) { console.log('SELFTEST FAIL (sizing)'); process.exit(1); }
  const expect = ['PLACE_LIMIT', 'MOVE_LIMIT', 'FILLED', 'TRADE_CLOSED', 'CANCEL_LIMIT', 'START', 'STATE', 'NEW_POINT', 'STATE', 'NEW_POINT', 'REPOSITION', 'ZONE_TOUCH', 'UNEXPECTED_MOVE', 'STATE', 'RESET', 'REPAINT_SUSPECT'];
  const ok = expect.every(t => types.includes(t));
  console.log('\nevents:', types.join(', '));
  console.log(ok ? 'SELFTEST PASS' : 'SELFTEST FAIL (missing: ' + expect.filter(t => !types.includes(t)).join(',') + ')');
  process.exit(ok ? 0 : 1);
}

// ── one-off test order: BUY the asset's smallest size, limit 2% below market (should not fill), Paper Trading only ──
async function tvTestOrder() {
  let price = Number(arg('--price', NaN)), symbol = arg('--symbol', '');
  if (!Number.isFinite(price) || !symbol) {
    const snap = await (await makeRealReader()).snapshot();
    price = snap.bar?.c; symbol = snap.symbol;
  }
  if (!Number.isFinite(price)) throw new Error('could not read the current price from the chart');
  const entry = +(price * 0.98).toFixed(2), sl = +(entry * 0.995).toFixed(2), tp = +(entry * 1.01).toFixed(2);
  const dry = flag('--dry'), units = assetOf(symbol).step;
  console.log(`Test order: BUY ${units} ${symbol} LIMIT ${entry} · SL ${sl} · TP ${tp}  (2% below ${price}, should not fill)${dry ? '  [dry run]' : ''}`);
  const r = await tvPlaceOrder({ side: 1, units, entry, sl, tp, symbol, dry });
  if (r.placed) {
    csvAppend({ opened: now(), closed: '', mode: 'tv-test', src: 'test', symbol, side: 'LONG', entry, sl, tp, units, exit: '', pnl: '', R: '', reason: 'TEST ORDER placed in TradingView Paper' });
    console.log(r.verified
      ? `PLACED ✓  "${r.summary}" · Orders tab ${r.ordersBefore} → ${r.ordersAfter} (a bracket shows as 3 rows). Cancel it in TradingView (Orders tab → ✕).`
      : `CLICKED Place for "${r.summary}" but the Orders count did not change within 8 s (${r.ordersBefore} → ${r.ordersAfter}). It may still have been placed — check the Orders tab before running again.`);
  } else console.log(`Dialog filled and verified, not placed (dry run): "${r.summary}"`);
}

if (flag('--selftest')) selftest();
else if (flag('--tv-test')) tvTestOrder().then(() => process.exit(0)).catch((e) => { console.error('Test order NOT placed: ' + e.message); process.exit(1); });
else main(CFG.demo ? makeDemoReader() : await makeRealReader());
EOF_WATCH
cat > "$HOME/eie-watch/CLAUDE.md" <<'EOF_MD'
# EIE desk — instructions for AI agents on this computer

You are assisting a prop-firm trader (gold XAUUSD, WTI crude and Bitcoin BTCUSD) who trades the
EIE PRO and SK SEQ indicators (EIE PRO is a fork of **Elliott Impulse Engine [WillyAlgoTrader]**)
on 1m–15m TradingView Desktop charts.
Think like a quant and an Elliott-wave practitioner: evidence over narrative.

## Tools
- MCP server `tradingview` (tradesdontlie/tradingview-mcp) reads the live chart over localhost:9222.
  Always pass `study_filter: "Elliott Impulse"` to `data_get_pine_labels`, `data_get_pine_boxes`,
  `data_get_pine_lines`, `data_get_pine_tables`. The EIE dashboard table gives State, Direction,
  Invalidation, Last Reset.
- The watcher `eie-watch.mjs` runs separately and writes `events.jsonl`, `ledger.json`, `report.txt` here.
  Read those files before answering questions about signals or repainting.
- Do not change the chart's symbol or timeframe while the watcher runs unless the user asks
  (it would interrupt monitoring). Never place, modify or cancel orders.

## Setup
For installation, health checks and troubleshooting, follow the repo's `.claude/skills/operation-aurum/SKILL.md`,
or run `node ~/eie-watch/doctor.mjs`.

## Facts about EIE (audited from its source, v0.9.0-dev)
- No lookahead / no request.security; pivots used only on confirmed bars; CHoCH and (Close mode)
  invalidation need a confirmed bar close → no true repaint of confirmed structure.
- Labels are drawn at the true swing but appear 5 bars (wave points) / 10 bars (structure) later.
- Only the newest wave point may reposition until the next point locks; point 0 never moves.
- Dead and completed counts are wiped from the chart → never judge accuracy by scrolling history;
  use events.jsonl / a strategy backtest.
- Keep input "Breaks: Invalidation Mode" = Close.

## Trading rules to apply in every plan
- Risk 0.5% per trade ($25 on a 5K account), strict 1:2 R:R, stop just beyond point 0
  (the INVALID level in wave 2), limit entry inside the W2 OTE box (default 0.618 of leg 0→1).
- Max 3–5 trades/day, stop after 2 losses; one open trade at a time across all assets.
- No new entries 30 min before high-impact news (CPI, NFP, FOMC; crude: EIA Wed 10:30 ET, OPEC).
  Bitcoin trades 24/7: weekend liquidity is thin, so treat weekend setups with extra caution.
- Costs per asset (round trip): gold ~0.35, WTI ~0.04, BTC ~0.03% of price. The indicators use these automatically.
- On 1m, cost (spread + slippage) is ~10–20% of R: reject setups whose stop is < 5× the spread.
- Prefer setups aligned with the 15m/1H direction.

When an event arrives, report: symbol, side, entry/stop/target, R:R, distance to INVALID,
spread-to-stop ratio, higher-TF alignment, and a go / no-go with the reason.
EOF_MD
cat > "$HOME/eie-watch/ui.html" <<'EOF_UI'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Operation Aurum</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Share+Tech+Mono&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #040706; --panel: #07100c; --panel2: #0a1611; --line: #123524; --line2: #1b4d34;
    --fg: #b8f5cf; --dim: #5f8f74; --mute: #33584a;
    --green: #39ff88; --amber: #ffb000; --red: #ff3b5c; --cyan: #3ad1ff; --violet: #b38cff;
    --glow: 0 0 6px rgba(57,255,136,.55), 0 0 18px rgba(57,255,136,.18);
    --mono: "JetBrains Mono", "Share Tech Mono", ui-monospace, Menlo, monospace;
    --display: "Share Tech Mono", "JetBrains Mono", ui-monospace, monospace;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; background: var(--bg); color: var(--fg); font-family: var(--mono); font-size: 13px; }
  body::before {            /* scanlines */
    content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 50;
    background: repeating-linear-gradient(to bottom, rgba(0,0,0,0) 0, rgba(0,0,0,0) 2px, rgba(0,0,0,.18) 3px);
  }
  body::after {             /* vignette */
    content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 49;
    background: radial-gradient(ellipse at center, rgba(0,0,0,0) 55%, rgba(0,0,0,.55) 100%);
  }
  .wrap { max-width: 1480px; margin: 0 auto; padding: 14px 16px 28px; }
  .banner { text-align: center; font-family: var(--display); letter-spacing: .35em; font-size: 11px; color: #120; background: var(--amber);
            padding: 3px 0; margin: -14px -16px 12px; }
  header { display: flex; flex-wrap: wrap; gap: 10px 22px; align-items: baseline; justify-content: space-between; border-bottom: 1px solid var(--line2); padding-bottom: 10px; }
  .title { font-family: var(--display); font-size: 22px; letter-spacing: .12em; color: var(--green); text-shadow: var(--glow); }
  .title .cur { animation: blink 1s steps(1) infinite; }
  .sub { color: var(--dim); font-size: 11px; letter-spacing: .2em; }
  .status { display: flex; flex-wrap: wrap; gap: 8px 18px; font-size: 12px; color: var(--dim); }
  .status b { color: var(--fg); font-weight: 600; }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; vertical-align: 1px; }
  .dot.on { background: var(--green); box-shadow: var(--glow); animation: pulse 1.6s infinite; }
  .dot.off { background: var(--red); }
  .dot.demo { background: var(--amber); }
  .price { font-size: 20px; font-weight: 700; color: var(--fg); transition: color .25s; }
  .price.up { color: var(--green); } .price.dn { color: var(--red); }
  .grid { display: grid; grid-template-columns: minmax(0, 1fr) 380px; gap: 14px; margin-top: 14px; }
  @media (max-width: 1100px) { .grid { grid-template-columns: minmax(0, 1fr); } }
  .card { background: linear-gradient(180deg, rgba(10,22,17,.66), rgba(7,16,12,.58)); border: 1px solid var(--line); position: relative; backdrop-filter: blur(1.5px); }
  .card::before, .card::after { content: ""; position: absolute; width: 10px; height: 10px; border-color: var(--green); border-style: solid; opacity: .7; }
  .card::before { top: -1px; left: -1px; border-width: 1px 0 0 1px; }
  .card::after { bottom: -1px; right: -1px; border-width: 0 1px 1px 0; }
  .card h2 { margin: 0; padding: 8px 12px; font-family: var(--display); font-weight: 400; font-size: 12px; letter-spacing: .25em; color: var(--dim);
             border-bottom: 1px solid var(--line); display: flex; justify-content: space-between; gap: 8px; }
  .card h2 span:last-child { color: var(--mute); }
  .trackcard { display: flex; flex-direction: column; }
  .chartbox { flex: 1; min-height: 470px; }
  @media (max-width: 700px) { .chartbox { min-height: 340px; } }
  .legend { display: flex; flex-wrap: wrap; gap: 6px 14px; padding: 8px 12px; border-top: 1px solid var(--line); font-size: 11px; color: var(--dim); }
  .legend i { display: inline-block; width: 14px; height: 2px; margin-right: 6px; vertical-align: 3px; }
  .kv { width: 100%; border-collapse: collapse; }
  .kv td { padding: 5px 12px; border-bottom: 1px dashed var(--line); vertical-align: top; }
  .kv td:first-child { color: var(--dim); width: 44%; white-space: nowrap; }
  .kv td:last-child { color: var(--fg); word-break: break-word; }
  .side { display: flex; flex-direction: column; gap: 14px; }
  .op { padding: 12px; }
  .op .state { font-family: var(--display); font-size: 18px; letter-spacing: .08em; }
  .op .state.long { color: var(--green); text-shadow: var(--glow); }
  .op .state.short { color: var(--red); text-shadow: 0 0 8px rgba(255,59,92,.5); }
  .op .state.idle { color: var(--dim); }
  .lv { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-top: 10px; }
  .lv div { border: 1px solid var(--line); padding: 6px 8px; }
  .lv small { display: block; color: var(--dim); font-size: 10px; letter-spacing: .2em; }
  .lv b { font-size: 15px; }
  .calc { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 10px; }
  .calc label { color: var(--dim); font-size: 10px; letter-spacing: .15em; display: block; margin-bottom: 3px; }
  .calc input { width: 100%; background: #020403; border: 1px solid var(--line2); color: var(--green); font-family: var(--mono); font-size: 14px; padding: 5px 7px; outline: none; }
  .calc input:focus { border-color: var(--green); box-shadow: var(--glow); }
  .out { margin-top: 10px; padding: 8px; border: 1px dashed var(--line2); color: var(--fg); }
  .out b { color: var(--amber); font-size: 16px; }
  .log { max-height: 300px; overflow: auto; padding: 6px 0; font-size: 12px; }
  .log div { padding: 3px 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; animation: type .5s steps(30) both; }
  .log time { color: var(--mute); margin-right: 10px; }
  .tag { display: inline-block; min-width: 128px; margin-right: 10px; }
  .t-place { color: var(--amber); } .t-fill { color: var(--cyan); } .t-cancel { color: var(--red); } .t-close { color: var(--green); }
  .t-move { color: var(--violet); } .t-warn { color: var(--red); } .t-info { color: var(--dim); }
  .warn { margin-top: 10px; padding: 7px 9px; border: 1px solid var(--red); color: var(--red); background: rgba(255,59,92,.08); font-size: 12px; letter-spacing: .06em; animation: pulse 1.6s infinite; }
  .warn.amber { border-color: var(--amber); color: var(--amber); background: rgba(255,176,0,.07); }
  .warroom { position: relative; }
  .wr-btn { background: transparent; border: 1px solid var(--line2); color: var(--green); font-family: var(--mono); font-size: 10px; letter-spacing: .15em; padding: 2px 8px; cursor: pointer; }
  .wr-btn:focus-visible { outline: 1px solid var(--green); }
  .blinkg { color: var(--green); font-weight: 400; animation: pulse 1.2s infinite; }
  .wr-head { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; padding: 10px 12px 6px; }
  .wr-head div { border-left: 2px solid var(--line2); padding-left: 8px; min-width: 0; }
  .wr-head small, .wr-tile small, .wr-sub { display: block; color: var(--dim); font-size: 10px; letter-spacing: .2em; }
  .wr-head b { display: block; color: var(--fg); font-size: 13px; overflow-wrap: anywhere; }
  .wr-head span, .wr-tile span { display: block; color: var(--mute); font-size: 11px; }
  .wr-prog { height: 3px; margin: 4px 12px 10px; background: var(--line); }
  .wr-prog i { display: block; height: 100%; background: var(--green); box-shadow: var(--glow); transition: width .4s; }
  .wr-tiles { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; padding: 0 12px 8px; }
  .wr-tile { border: 1px solid var(--line); padding: 8px 10px; background: rgba(0,0,0,.25); }
  .wr-tile b { font-size: 26px; font-family: var(--display); }
  .wr-bar { height: 3px; background: var(--line); margin: 6px 0 4px; }
  .wr-bar i { display: block; height: 100%; transition: width .5s; }
  .wr-legend { display: flex; flex-wrap: wrap; gap: 6px 14px; padding: 6px 12px; color: var(--dim); font-size: 11px; }
  .wr-legend i { display: inline-block; width: 12px; height: 2px; margin-right: 6px; vertical-align: 3px; }
  .wr-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; padding: 6px 12px 12px; }
  .wrap, header, .grid, .bottom, footer { position: relative; z-index: 1; }
  @media (max-width: 900px) { .wr-head, .wr-tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); } .wr-grid { grid-template-columns: minmax(0, 1fr); } }
  .bottom { margin-top: 14px; }
  .sync { display: flex; flex-wrap: wrap; gap: 6px 10px; margin-top: 10px; font-size: 11px; position: relative; z-index: 1; }
  .sync .pill { border: 1px solid var(--line2); padding: 3px 8px; background: rgba(0,0,0,.45); color: var(--dim); }
  .sync .pill b { color: var(--fg); font-weight: 600; }
  .sync .ok { color: var(--green); } .sync .warn { color: var(--amber); } .sync .bad { color: var(--red); }
  .tele-grid { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); gap: 12px; padding: 10px 12px 12px; }
  @media (max-width: 900px) { .tele-grid { grid-template-columns: minmax(0, 1fr); } }
  .term { height: 260px; overflow: auto; background: rgba(0,0,0,.72); border: 1px solid var(--line); padding: 8px 10px; font-size: 11.5px; line-height: 1.55; }
  .term div { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #8fe8b3; animation: type .45s steps(28) both; }
  .term .t-mc { color: var(--cyan); } .term .t-sync { color: var(--violet); } .term .t-draw { color: var(--amber); }
  .term .cursor { display: inline-block; width: 8px; height: 13px; background: var(--green); vertical-align: -2px; animation: blink 1s steps(1) infinite; }
  .cores { display: grid; gap: 6px; margin-bottom: 10px; }
  .core { display: grid; grid-template-columns: 58px 1fr 52px; align-items: center; gap: 8px; font-size: 11px; color: var(--dim); }
  .core .bar { height: 8px; background: var(--line); position: relative; overflow: hidden; }
  .core .bar i { position: absolute; inset: 0; width: 0; background: var(--cyan); }
  .core.busy .bar i { width: 100%; animation: corepulse .5s linear infinite; box-shadow: 0 0 8px var(--cyan); }
  @keyframes corepulse { 0% { opacity: .35; } 50% { opacity: 1; } 100% { opacity: .35; } }
  .tstat { display: grid; grid-template-columns: 1fr 1fr; gap: 6px 10px; font-size: 11px; }
  .tstat small { display: block; color: var(--dim); letter-spacing: .15em; font-size: 9.5px; }
  .tstat b { color: var(--fg); font-size: 13px; }
  .empty { padding: 14px 12px; color: var(--mute); }
  footer { margin-top: 18px; color: var(--mute); font-size: 11px; letter-spacing: .1em; text-align: center; }
  @keyframes blink { 50% { opacity: 0; } }
  @keyframes pulse { 50% { opacity: .35; } }
  @keyframes type { from { clip-path: inset(0 100% 0 0); } to { clip-path: inset(0 0 0 0); } }
  @media (prefers-reduced-motion: reduce) { * { animation: none !important; } }
</style>
</head>
<body>
<div id="root"></div>
<script src="/vendor/react.js"></script>
<script src="/vendor/react-dom.js"></script>
<script src="/vendor/htm.js"></script>
<script src="/vendor/lightweight-charts.js"></script>
<script>
const { useState, useEffect, useRef, useMemo } = React;
const html = htm.bind(React.createElement);
const C = { green: '#39ff88', red: '#ff3b5c', amber: '#ffb000', cyan: '#3ad1ff', violet: '#b38cff', dim: '#5f8f74', line: '#123524' };

const nums = (s) => (String(s || '').match(/-?\d+(?:\.\d+)?/g) || []).map(Number);
const fmt = (x, d = 2) => (x == null || Number.isNaN(x) ? '—' : Number(x).toFixed(d));
const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
};

// Decrypt-style text reveal for headings
function Decode({ text, speed = 28 }) {
  const [out, setOut] = useState(text);
  useEffect(() => {
    const glyphs = '█▓▒░<>/\\|#%&$@01';
    let i = 0;
    const id = setInterval(() => {
      i++;
      setOut(text.split('').map((ch, k) => (k < i || ch === ' ' ? ch : glyphs[(k * 7 + i) % glyphs.length])).join(''));
      if (i >= text.length) clearInterval(id);
    }, speed);
    return () => clearInterval(id);
  }, [text]);
  return out;
}

function Clock() {
  const [t, setT] = useState(new Date());
  useEffect(() => { const id = setInterval(() => setT(new Date()), 1000); return () => clearInterval(id); }, []);
  const ny = t.toLocaleTimeString('en-US', { timeZone: 'America/New_York', hour12: false });
  const utc = t.toISOString().slice(11, 19);
  return html`<span>NY <b>${ny}</b></span><span>UTC <b>${utc}</b></span>`;
}

// Parse levels the two panels publish
function levelsFrom(panels) {
  const eie = panels['EIE PRO'] || {}, sk = panels['SK SEQ'] || {};
  const L = [];
  const inv = nums(eie['Invalidation'])[0];
  if (inv) L.push({ price: inv, color: C.red, title: 'EIE INVALID', style: 2 });
  const [e1, s1, t1] = nums(eie['Entry · SL · TP']);
  if (e1) L.push({ price: e1, color: C.amber, title: 'EIE ENTRY', style: 0 }, { price: s1, color: C.red, title: 'EIE SL', style: 0 }, { price: t1, color: C.green, title: 'EIE TP', style: 0 });
  const [k0, kA] = nums(sk['0 · A']);
  const [kB, kC1, kC2] = nums(sk['B · C']);
  if (k0) L.push({ price: k0, color: C.violet, title: 'SK0', style: 1 });
  if (kA) L.push({ price: kA, color: C.violet, title: 'SKA', style: 1 });
  if (kB) L.push({ price: kB, color: C.violet, title: 'SKB', style: 1 });
  if (kC1) L.push({ price: kC1, color: C.cyan, title: 'SKC', style: 3 });
  if (kC2) L.push({ price: kC2, color: C.cyan, title: 'SKC 200%', style: 3 });
  const [e2, s2, t2] = nums(sk['Entry · SL · TP']);
  if (e2) L.push({ price: e2, color: C.amber, title: 'SK ENTRY', style: 0 }, { price: s2, color: C.red, title: 'SK SL', style: 0 }, { price: t2, color: C.green, title: 'SK TP', style: 0 });
  return L.filter(l => Number.isFinite(l.price));
}

function Chart({ bars, levels, ov }) {
  const box = useRef(null), chart = useRef(null), series = useRef(null), lines = useRef([]), zl = useRef([]), fitted = useRef(false);
  useEffect(() => {
    const ch = LightweightCharts.createChart(box.current, {
      autoSize: true,
      layout: { background: { color: 'transparent' }, textColor: C.dim, fontFamily: 'JetBrains Mono, monospace', fontSize: 11 },
      grid: { vertLines: { color: 'rgba(18,53,36,.6)' }, horzLines: { color: 'rgba(18,53,36,.6)' } },
      rightPriceScale: { borderColor: C.line }, timeScale: { borderColor: C.line, timeVisible: true, secondsVisible: false },
      crosshair: { vertLine: { color: C.green, labelBackgroundColor: '#0b2a1b' }, horzLine: { color: C.green, labelBackgroundColor: '#0b2a1b' } },
    });
    series.current = ch.addCandlestickSeries({ upColor: C.green, downColor: C.red, borderUpColor: C.green, borderDownColor: C.red, wickUpColor: C.green, wickDownColor: C.red });
    chart.current = ch;
    return () => ch.remove();
  }, []);
  useEffect(() => {
    if (!series.current || !bars?.length) return;
    const data = bars.map(b => ({ time: b.time > 1e12 ? Math.floor(b.time / 1000) : b.time, open: b.open, high: b.high, low: b.low, close: b.close }))
      .filter((b, i, a) => i === 0 || b.time > a[i - 1].time);
    series.current.setData(data);
    if (!fitted.current) { chart.current.timeScale().fitContent(); fitted.current = true; }
  }, [bars]);
  useEffect(() => {
    if (!series.current) return;
    lines.current.forEach(l => series.current.removePriceLine(l));
    lines.current = levels.map(l => series.current.createPriceLine({ price: l.price, color: l.color, lineWidth: l.title.includes('ENTRY') ? 2 : 1, lineStyle: l.style, axisLabelVisible: true, title: l.title }));
  }, [levels]);
  useEffect(() => {
    if (!series.current) return;
    const s = series.current;
    zl.current.forEach(l => s.removePriceLine(l)); zl.current = [];
    if (!ov) { try { s.setMarkers([]); } catch {} return; }
    const times = new Set((bars || []).map(b => (b.time > 1e12 ? Math.floor(b.time / 1000) : b.time)));
    const mk = (ov.markers || []).filter(m => times.has(m.time)).map(m => ({ time: m.time, position: /^(0|2|4|A|C|SK0|SKB)/.test(m.text) && m.src === 'EIE' ? 'aboveBar' : 'belowBar',
      color: m.src === 'SK' ? C.violet : m.text === 'CHoCH' ? C.amber : C.green, shape: m.src === 'SK' ? 'square' : 'circle', text: m.text }));
    try { s.setMarkers(mk); } catch {}
    (ov.zones || []).forEach((z) => {
      const col = z.src === 'SK' ? C.violet : C.amber, t = z.text.length > 26 ? z.text.slice(0, 26) + '…' : z.text;
      zl.current.push(s.createPriceLine({ price: z.top, color: col, lineWidth: 1, lineStyle: 1, axisLabelVisible: false, title: t }));
      zl.current.push(s.createPriceLine({ price: z.bot, color: col, lineWidth: 1, lineStyle: 1, axisLabelVisible: false, title: '' }));
    });
    if (ov.trail) zl.current.push(s.createPriceLine({ price: ov.trail, color: C.cyan, lineWidth: 2, lineStyle: 0, axisLabelVisible: true, title: 'ST TRAIL' }));
  }, [JSON.stringify(ov), bars && bars.length]);
  return html`<div class="chartbox" ref=${box}></div>`;
}

function Dossier({ name, rows }) {
  const keys = Object.keys(rows || {}).filter(k => !k.startsWith('◆'));
  return html`<section class="card">
    <h2><span>DOSSIER · ${name}</span><span>${keys.length ? 'LIVE' : 'NO SIGNAL'}</span></h2>
    ${keys.length ? html`<table class="kv"><tbody>${keys.map(k => html`<tr key=${k}><td>${k}</td><td>${rows[k]}</td></tr>`)}</tbody></table>`
                  : html`<div class="empty">Indicator not found on the active chart.</div>`}
  </section>`;
}

function Operation({ panels, last }) {
  const [risk, setRisk] = useState(store.get('aurum.risk', 25));
  const [units, setUnits] = useState(store.get('aurum.units', 100));
  useEffect(() => store.set('aurum.risk', risk), [risk]);
  useEffect(() => store.set('aurum.units', units), [units]);
  const pick = ['EIE PRO', 'SK SEQ'].map(n => ({ n, p: panels[n] || {} }))
    .find(x => /limit|in trade/i.test(x.p['Signal'] || '')) || { n: null, p: {} };
  const sig = pick.p['Signal'] || '';
  const [e, s, t] = nums(pick.p['Entry · SL · TP']);
  const side = /long/i.test(sig) ? 'long' : /short/i.test(sig) ? 'short' : 'idle';
  const dist = e && s ? Math.abs(e - s) : null;
  const rr = dist ? Math.abs(t - e) / dist : null;
  const lots = dist && units > 0 ? risk / (dist * units) : null;
  const toEntry = e && last ? last - e : null;
  const eie = panels['EIE PRO'] || {}, sk = panels['SK SEQ'] || {};
  const conflict = /CONFLICT/.test(sk['Filters'] || '');
  const suspect = /⚠/.test(eie['Count check'] || '');
  const noSource = /set source/.test(sk['Filters'] || '');
  return html`<section class="card">
    <h2><span>ACTIVE OPERATION</span><span>${pick.n || 'STANDBY'}</span></h2>
    <div class="op">
      <div class=${'state ' + side}>${side === 'idle' ? 'NO ACTIVE ORDER · STANDING BY' : sig.toUpperCase()}</div>
      ${conflict && html`<div class="warn">⚠ EIE × SK CONFLICT · opposite directions · STAND DOWN</div>`}
      ${suspect && html`<div class="warn amber">⚠ ELLIOTT COUNT SUSPECT · wave 4 overlaps wave 1 · trust SK structure, not the wave count</div>`}
      ${noSource && html`<div class="warn amber">SK "Require EIE agreement" is on but its source is not set to EIE PRO: EIE direction</div>`}
      ${side !== 'idle' && html`
        <div class="lv">
          <div><small>ENTRY</small><b style=${{ color: C.amber }}>${fmt(e)}</b></div>
          <div><small>STOP</small><b style=${{ color: C.red }}>${fmt(s)}</b></div>
          <div><small>TARGET</small><b style=${{ color: C.green }}>${fmt(t)}</b></div>
        </div>`}
      <div class="calc">
        <div><label for="risk">RISK PER TRADE ($)</label><input id="risk" type="number" min="1" step="1" value=${risk} onInput=${ev => setRisk(+ev.target.value || 0)} /></div>
        <div><label for="units">UNITS PER LOT</label><input id="units" type="number" min="1" step="1" value=${units} onInput=${ev => setUnits(+ev.target.value || 0)} /></div>
      </div>
      <div class="out">
        ${side === 'idle' ? html`Sizing appears when a limit is placed. Gold CFD: 100 units/lot · WTI: 1000 · BTC: sized in 0.001 BTC.`
          : html`Size <b>${fmt(dist ? risk / dist : null, 2)} units</b> (${fmt(lots, 3)} lots) · R:R ${fmt(rr, 2)} · stop ${fmt(dist)} · price ${toEntry == null ? '—' : (toEntry >= 0 ? '+' : '') + fmt(toEntry)} from entry
             ${dist && risk / dist < 1 ? html`<div style=${{ color: C.red, marginTop: '6px' }}>Stop too wide for $${risk} risk (under 1 unit): the bot skips this. Use a lower timeframe or raise risk.</div>` : null}`}
      </div>
    </div>
  </section>`;
}

function Bot({ b }) {
  if (!b) return null;
  const pos = b.pos, ord = b.order;
  return html`<section class="card">
    <h2><span>AUTO-TRADER · ${b.mode.toUpperCase()}</span><span>${b.pnl >= 0 ? '+' : ''}${fmt(b.pnl)}</span></h2>
    <table class="kv"><tbody>
      <tr><td>Balance</td><td>${fmt(b.balance)}</td></tr>
      <tr><td>Today</td><td>${b.dayTrades} trades · ${b.dayLosses} losses</td></tr>
      <tr><td>Working order</td><td>${ord ? `${ord.side === 1 ? 'BUY' : 'SELL'} ${ord.units} @ ${ord.entry} · SL ${ord.sl} · TP ${ord.tp}` : '—'}</td></tr>
      <tr><td>Position</td><td>${pos ? `${pos.side === 1 ? 'LONG' : 'SHORT'} ${pos.units} @ ${pos.entry} · SL ${pos.sl} · TP ${pos.tp}` : '—'}</td></tr>
      ${b.note && html`<tr><td>Note</td><td style=${{ color: C.amber }}>${b.note}</td></tr>`}
      ${(b.trades || []).slice().reverse().map((t, i) => html`<tr key=${i}><td>${(t.closed || '').slice(11, 19)} ${t.side}</td>
        <td style=${{ color: t.pnl >= 0 ? C.green : C.red }}>${t.reason} ${t.pnl >= 0 ? '+' : ''}${t.pnl} (${t.R}R)</td></tr>`)}
    </tbody></table>
  </section>`;
}


// ── Matrix rain background (pauses when the tab is hidden or reduced motion is preferred) ──
function MatrixRain({ on }) {
  const ref = useRef(null);
  useEffect(() => {
    if (!on) return;
    const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduce) return;
    const cv = ref.current, ctx = cv.getContext('2d');
    const glyphs = 'アカサタナハマヤラワ0123456789ΣΔπ$€¥£XAUOILR'.split('');
    let cols = [], raf = 0, last = 0, fs = 14;
    const size = () => { cv.width = window.innerWidth; cv.height = window.innerHeight; cols = new Array(Math.ceil(cv.width / fs)).fill(0).map(() => Math.random() * -50); };
    size(); window.addEventListener('resize', size);
    const draw = (t) => {
      raf = requestAnimationFrame(draw);
      if (document.hidden || t - last < 55) return;
      last = t;
      ctx.fillStyle = 'rgba(4,7,6,0.12)'; ctx.fillRect(0, 0, cv.width, cv.height);
      ctx.font = fs + 'px "Share Tech Mono", monospace';
      cols.forEach((y, i) => {
        const ch = glyphs[(Math.random() * glyphs.length) | 0];
        ctx.fillStyle = Math.random() < 0.06 ? '#d8ffe9' : Math.random() < 0.5 ? '#2bd673' : '#16884a';
        ctx.fillText(ch, i * fs, y * fs);
        cols[i] = y * fs > cv.height && Math.random() > 0.975 ? 0 : y + 1;
      });
    };
    raf = requestAnimationFrame(draw);
    return () => { cancelAnimationFrame(raf); window.removeEventListener('resize', size); ctx.clearRect(0, 0, cv.width, cv.height); };
  }, [on]);
  return html`<canvas ref=${ref} aria-hidden="true" style=${{ position: 'fixed', inset: 0, zIndex: 0, opacity: on ? 0.5 : 0, pointerEvents: 'none', transition: 'opacity .6s' }}></canvas>`;
}

function useCanvas(draw, deps) {
  const ref = useRef(null);
  useEffect(() => {
    const cv = ref.current; if (!cv) return;
    const paint = () => {
      const r = cv.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
      cv.width = Math.max(1, r.width * dpr); cv.height = Math.max(1, r.height * dpr);
      const ctx = cv.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      draw(ctx, r.width, r.height);
    };
    paint();
    const ro = new ResizeObserver(paint); ro.observe(cv);
    return () => ro.disconnect();
  }, deps);
  return ref;
}

const resColor = (r) => r === 1 ? C.green : r === -1 ? C.red : r === -2 ? C.amber : C.dim;

// Fan chart: percentile bands + target / breach lines + live paths that draw themselves in
function FanChart({ mc }) {
  const [prog, setProg] = useState(1);
  const liveKey = mc && mc.live ? mc.done + (mc.viz || 0) : 0;
  useEffect(() => {
    let raf, t0 = performance.now();
    const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduce) { setProg(1); return; }
    const step = (t) => { const p = Math.min(1, (t - t0) / 1100); setProg(p); if (p < 1) raf = requestAnimationFrame(step); };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [liveKey]);
  const ref = useCanvas((ctx, w, h) => {
    ctx.clearRect(0, 0, w, h);
    if (!mc || !mc.bands) return;
    const H = mc.rules.horizon, top = mc.rules.target + 1.5, bot = -mc.rules.maxLoss - 1.5;
    const X = (k) => 44 + (w - 56) * k / H, Y = (v) => 10 + (h - 34) * (top - v) / (top - bot);
    ctx.strokeStyle = 'rgba(18,53,36,.8)'; ctx.lineWidth = 1; ctx.font = '10px "JetBrains Mono", monospace'; ctx.fillStyle = C.dim;
    for (let v = Math.ceil(bot / 2) * 2; v <= top; v += 2) { ctx.beginPath(); ctx.moveTo(44, Y(v)); ctx.lineTo(w - 12, Y(v)); ctx.stroke(); ctx.fillText((v > 0 ? '+' : '') + v + '%', 4, Y(v) + 3); }
    for (let k = 0; k <= H; k += 25) ctx.fillText(k + '', X(k) - 6, h - 8);
    const band = (lo, hi, a) => { const b = mc.bands; ctx.beginPath(); for (let k = 0; k <= H; k++) ctx.lineTo(X(k), Y(b[hi][k])); for (let k = H; k >= 0; k--) ctx.lineTo(X(k), Y(b[lo][k])); ctx.closePath(); ctx.fillStyle = `rgba(57,255,136,${a})`; ctx.fill(); };
    band(0, 4, 0.07); band(1, 3, 0.13);
    ctx.beginPath(); mc.bands[2].forEach((v, k) => ctx.lineTo(X(k), Y(v))); ctx.strokeStyle = C.green; ctx.lineWidth = 1.5; ctx.stroke();
    const hline = (v, col, txt) => { ctx.setLineDash([6, 5]); ctx.beginPath(); ctx.moveTo(44, Y(v)); ctx.lineTo(w - 12, Y(v)); ctx.strokeStyle = col; ctx.lineWidth = 1.2; ctx.stroke(); ctx.setLineDash([]); ctx.fillStyle = col; ctx.fillText(txt, w - 140, Y(v) - 5); };
    hline(mc.rules.target, C.green, `TARGET +${mc.rules.target}%`); hline(-mc.rules.maxLoss, C.red, `MAX LOSS −${mc.rules.maxLoss}%`); hline(0, 'rgba(184,245,207,.35)', '');
    const kMax = Math.floor(H * prog);
    (mc.live || []).forEach((p) => {
      ctx.beginPath();
      for (let k = 0; k <= kMax; k++) ctx.lineTo(X(k), Y(p.e[k]));
      ctx.strokeStyle = resColor(p.r); ctx.globalAlpha = 0.55; ctx.lineWidth = 1; ctx.shadowColor = resColor(p.r); ctx.shadowBlur = 6; ctx.stroke();
      ctx.globalAlpha = 1; ctx.shadowBlur = 0;
    });
  }, [mc && mc.done, mc && mc.status, prog]);
  return html`<canvas ref=${ref} role="img" aria-label="Monte Carlo equity fan chart" style=${{ width: '100%', height: '320px', display: 'block' }}></canvas>`;
}

function Hist({ bins, label, unit, step, color }) {
  const ref = useCanvas((ctx, w, h) => {
    ctx.clearRect(0, 0, w, h);
    if (!bins) return;
    const tot = bins.reduce((a, b) => a + b, 0) || 1, mx = Math.max(...bins) || 1, n = bins.length, bw = (w - 8) / n;
    bins.forEach((v, i) => { const bh = (h - 22) * v / mx; ctx.fillStyle = color; ctx.globalAlpha = 0.35 + 0.65 * (v / mx); ctx.fillRect(4 + i * bw, h - 16 - bh, Math.max(1, bw - 1), bh); });
    ctx.globalAlpha = 1; ctx.fillStyle = C.dim; ctx.font = '10px "JetBrains Mono", monospace';
    [0, Math.floor(n / 2), n - 1].forEach((i, j) => ctx.fillText((i * step) + unit, j === 2 ? w - 30 : 4 + i * bw, h - 3));
    let c = 0, p95 = 0; for (let i = 0; i < n; i++) { c += bins[i]; if (c / tot >= 0.95) { p95 = i; break; } }
    ctx.strokeStyle = C.amber; ctx.setLineDash([4, 3]); ctx.beginPath(); ctx.moveTo(4 + (p95 + 0.5) * bw, 4); ctx.lineTo(4 + (p95 + 0.5) * bw, h - 16); ctx.stroke(); ctx.setLineDash([]);
    ctx.fillStyle = C.amber; ctx.fillText('95%: ' + (p95 * step) + unit, Math.min(w - 70, 8 + (p95 + 0.5) * bw), 12);
  }, [bins && bins.join(',')]);
  return html`<div><div class="wr-sub">${label}</div><canvas ref=${ref} role="img" aria-label=${label} style=${{ width: '100%', height: '120px', display: 'block' }}></canvas></div>`;
}

function Conv({ conv }) {
  const ref = useCanvas((ctx, w, h) => {
    ctx.clearRect(0, 0, w, h);
    if (!conv || conv.length < 2) return;
    const xs = conv.map(c => c[0]), ys = conv.map(c => c[1]);
    const xm = Math.max(...xs), lo = Math.max(0, Math.min(...ys) - 0.02), hi = Math.min(1, Math.max(...ys) + 0.02);
    ctx.beginPath(); conv.forEach(([x, y]) => ctx.lineTo(4 + (w - 8) * x / xm, h - 14 - (h - 22) * (y - lo) / ((hi - lo) || 1)));
    ctx.strokeStyle = C.cyan; ctx.lineWidth = 1.5; ctx.stroke();
    ctx.fillStyle = C.dim; ctx.font = '10px "JetBrains Mono", monospace';
    ctx.fillText((hi * 100).toFixed(1) + '%', 4, 10); ctx.fillText((lo * 100).toFixed(1) + '%', 4, h - 2);
  }, [conv && conv.length, conv && conv.length && conv[conv.length - 1][0]]);
  return html`<div><div class="wr-sub">PASS-RATE CONVERGENCE</div><canvas ref=${ref} role="img" aria-label="pass rate convergence" style=${{ width: '100%', height: '120px', display: 'block' }}></canvas></div>`;
}

function WarRoom({ mc, rain, setRain }) {
  if (!mc) return null;
  const pct = (x) => (x == null ? '—' : (100 * x).toFixed(1) + '%');
  const prog = mc.target ? Math.min(1, mc.done / mc.target) : 0;
  const tile = (name, v, col, note) => html`<div class="wr-tile"><small>${name}</small><b style=${{ color: col }}>${pct(v)}</b>
    <div class="wr-bar"><i style=${{ width: (100 * (v || 0)) + '%', background: col }}></i></div><span>${note}</span></div>`;
  return html`<section class="card bottom warroom">
    <h2><span>MONTE CARLO WAR ROOM · ${mc.status === 'running' ? html`<b class="blinkg">● SIMULATING</b>` : mc.status === 'complete' ? 'COMPLETE' : 'WAITING'}</span>
      <span><button class="wr-btn" onClick=${() => setRain(!rain)}>${rain ? 'RAIN ON' : 'RAIN OFF'}</button></span></h2>
    ${mc.status === 'waiting' ? html`<div class="empty">Waiting for data: ${mc.note}. ${mc.cores} cores standing by.</div>` : html`
    <div class="wr-head">
      <div><small>SOURCE</small><b>${mc.source.label}</b><span>${mc.source.n} trades · win ${pct(mc.source.wr)} · ${mc.source.avgR >= 0 ? '+' : ''}${mc.source.avgR}R avg</span></div>
      <div><small>MODEL</small><b>win +${mc.model.W.toFixed(2)}R · loss ${mc.model.L.toFixed(2)}R</b><span>${mc.model.bayes ? 'Bayesian win rate per path (small-sample honest)' : 'fixed win rate'}</span></div>
      <div><small>RULES</small><b>${mc.rules.risk}% risk · +${mc.rules.target}% / −${mc.rules.maxLoss}%</b><span>daily −${mc.rules.dailyLoss}% · ${mc.rules.perDay} trades/day · ${mc.rules.horizon} trades max</span></div>
      <div><small>ENGINE</small><b>${Math.round(mc.pps).toLocaleString()} paths/s · ${mc.cores} cores</b><span>${mc.done.toLocaleString()} / ${mc.target.toLocaleString()} paths · ${mc.elapsed.toFixed(1)} s${mc.viz ? ' · live +' + mc.viz.toLocaleString() : ''}</span></div>
    </div>
    <div class="wr-prog"><i style=${{ width: (100 * prog) + '%' }}></i></div>
    <div class="wr-tiles">
      ${tile('PASS (+target first)', mc.pass, C.green, mc.ttp ? `median ≈ ${Math.round(mc.ttp)} trades to pass` : '')}
      ${tile('BREACH (max loss)', mc.breach, C.red, 'static from starting balance')}
      ${tile('DAILY LIMIT HIT', mc.daily, C.amber, `−${mc.rules.dailyLoss}% in one day`)}
      ${tile('STILL OPEN', mc.open, C.dim, `after ${mc.rules.horizon} trades`)}
    </div>
    <${FanChart} mc=${mc} />
    <div class="wr-legend"><span><i style=${{ background: C.green }}></i>passed</span><span><i style=${{ background: C.red }}></i>breached</span><span><i style=${{ background: C.amber }}></i>daily limit</span><span><i style=${{ background: C.dim }}></i>undecided</span><span>bands: 5–95% and 25–75% of paths · line: median</span></div>
    <div class="wr-grid">
      <${Hist} bins=${mc.ddBins} label="MAX DRAWDOWN DISTRIBUTION" unit="%" step=${0.5} color=${C.red} />
      <${Hist} bins=${mc.stBins} label="LONGEST LOSING STREAK" unit="" step=${1} color=${C.violet} />
      <${Conv} conv=${mc.conv} />
    </div>`}
  </section>`;
}

function SyncStrip({ st }) {
  const sy = st.sync, now = Date.now();
  const ago = (t) => t == null ? '—' : Math.max(0, Math.round((now - t) / 1000)) + 's ago';
  const fresh = sy && sy.panelsAt && now - sy.panelsAt < 10000;
  const want = ['Elliott Impulse', 'SK Sequence'];
  return html`<div class="sync" aria-label="indicator sync status">
    <span class="pill">SYNC ${fresh ? html`<b class="ok">● LIVE</b>` : html`<b class="bad">● STALE</b>`} · panels ${sy ? ago(sy.panelsAt) : '—'} · read ${sy ? sy.readMs : '—'} ms</span>
    ${want.map((w) => { const x = sy && (sy.studies || []).find(o => o.name.indexOf(w) >= 0);
      return html`<span class="pill" key=${w}>${x ? html`<b class="ok">✓</b> ${x.name.split(' (')[0]} · settings #${x.fp} · ${x.changedAt ? html`<b class="warn">changed ${ago(x.changedAt)}</b>` : 'unchanged since start'}`
        : html`<b class="bad">✗</b> ${w} not found on chart`}</span>`; })}
    ${sy && sy.checkedAt ? html`<span class="pill">settings checked ${ago(sy.checkedAt)} (every 15 s)</span>` : null}
  </div>`;
}

function Telemetry({ tele, mc }) {
  const ref = useRef(null);
  useEffect(() => { if (ref.current) ref.current.scrollTop = ref.current.scrollHeight; }, [tele && tele.feed && tele.feed.length, tele && tele.feed && tele.feed[tele.feed.length - 1]]);
  if (!tele) return null;
  const cls = (l) => /\[mc\]/.test(l) ? 't-mc' : /\[sync\]/.test(l) ? 't-sync' : /\[draw\]/.test(l) ? 't-draw' : '';
  const up = tele.uptime, hh = Math.floor(up / 3600), mm = Math.floor(up / 60) % 60, ss = Math.floor(up) % 60;
  return html`<section class="card bottom">
    <h2><span>SYSTEM TELEMETRY · ENGINE LOG</span><span>${tele.workers} worker cores · ${tele.batches.toLocaleString()} batches</span></h2>
    <div class="tele-grid">
      <div class="term" ref=${ref} role="log" aria-live="off">
        ${tele.feed.map((l, i) => html`<div key=${l + i} class=${cls(l)}>${l}</div>`)}
        <div><span class="cursor"></span></div>
      </div>
      <div>
        <div class="cores">${(tele.busy || []).map((b, i) => html`<div class=${'core' + (b ? ' busy' : '')} key=${i}><span>CORE ${i + 1}</span><div class="bar"><i></i></div><span>${b ? 'BUSY' : 'idle'}</span></div>`)}</div>
        <div class="tstat">
          <div><small>UPTIME</small><b>${String(hh).padStart(2, '0')}:${String(mm).padStart(2, '0')}:${String(ss).padStart(2, '0')}</b></div>
          <div><small>CHART READS</small><b>${tele.reads.toLocaleString()}</b></div>
          <div><small>LAST READ</small><b>${tele.readMs} ms</b></div>
          <div><small>EVENTS / MIN</small><b>${tele.evPerMin}</b></div>
          <div><small>MEMORY</small><b>${tele.rssMB.toFixed(0)} MB</b></div>
          <div><small>HEAP</small><b>${tele.heapMB.toFixed(0)} MB</b></div>
          <div><small>MC PATHS</small><b>${mc && mc.done ? (mc.done + (mc.viz || 0)).toLocaleString() : '—'}</b></div>
          <div><small>MC SPEED</small><b>${mc && mc.pps ? Math.round(mc.pps).toLocaleString() + '/s' : '—'}</b></div>
        </div>
      </div>
    </div>
  </section>`;
}

const tagClass = (t) => /BOT_(ORDER|MOVE)|PLACE/.test(t) && !/SKIP/.test(t) ? 't-place' : /PLACE/.test(t) ? 't-place' : /FILL/.test(t) ? 't-fill' : /CANCEL|INVALID|SUSPECT|UNEXPECTED|NO_IND/.test(t) ? 't-cancel'
  : /CLOSED|WIN|OK/.test(t) ? 't-close' : /MOVE/.test(t) ? 't-move' : 't-info';

function Log({ events }) {
  return html`<section class="card bottom">
    <h2><span>INTERCEPT LOG</span><span>${events.length} RECORDS</span></h2>
    <div class="log" role="log" aria-live="polite">
      ${events.length ? events.slice().reverse().map((e, i) => html`<div key=${e.ts + i}>
        <time>${(e.ts || '').slice(11, 19)}</time><span class=${'tag ' + tagClass(e.type)}>${e.type}</span>${e.symbol ? e.symbol + ' · ' : ''}${e.msg || ''}</div>`)
        : html`<div class="empty">Awaiting intercepts…</div>`}
    </div>
  </section>`;
}

function App() {
  const [st, setSt] = useState({ connected: false, demo: false, panels: {}, bars: [], events: [] });
  const [dir, setDir] = useState('');
  const [rain, setRainS] = useState(store.get('aurum.rain', true));
  const setRain = (v) => { setRainS(v); store.set('aurum.rain', v); };
  const prev = useRef(null);
  useEffect(() => {
    let es;
    const apply = (s) => {
      if (prev.current != null && s.last != null && s.last !== prev.current) setDir(s.last > prev.current ? 'up' : 'dn');
      prev.current = s.last;
      setSt(s);
    };
    const poll = () => fetch('/api/state').then(r => r.json()).then(apply).catch(() => setSt(x => ({ ...x, connected: false })));
    try {
      es = new EventSource('/api/stream');
      es.onmessage = (m) => { try { apply(JSON.parse(m.data)); } catch {} };
      es.onerror = () => { es.close(); const id = setInterval(poll, 2000); es = { close: () => clearInterval(id) }; };
    } catch { poll(); }
    return () => es && es.close();
  }, []);
  const levels = useMemo(() => levelsFrom(st.panels || {}), [JSON.stringify(st.panels)]);
  const link = st.demo ? 'demo' : st.connected ? 'on' : 'off';
  return html`<${MatrixRain} on=${rain} /><div class="wrap">
    <div class="banner">CLASSIFIED // EYES ONLY // AURUM-7 // FICTIONAL TRAINING TERMINAL</div>
    <header>
      <div>
        <div class="title"><${Decode} text="OPERATION AURUM" /><span class="cur">_</span></div>
        <div class="sub">SIGNALS INTELLIGENCE TERMINAL · EIE PRO × SK SEQ</div>
      </div>
      <div class="status">
        <span><i class=${'dot ' + link}></i>${link === 'demo' ? 'DEMO FEED' : link === 'on' ? 'TV BRIDGE LINKED' : 'NO LINK'}</span>
        <span>TARGET <b>${st.symbol || '—'}</b> · <b>${st.tf ? st.tf + 'm' : '—'}</b></span>
        <${Clock} />
        <span class=${'price ' + dir}>${fmt(st.last)}</span>
      </div>
    </header>
    <${SyncStrip} st=${st} />
    <div class="grid">
      <section class="card trackcard">
        <h2><span>TARGET TRACK · ${st.symbol || '—'}</span><span>${st.bars?.length || 0} BARS</span></h2>
        <${Chart} bars=${st.bars} levels=${levels} ov=${st.overlays} />
        <div class="legend">
          <span><i style=${{ background: C.amber }}></i>entry</span><span><i style=${{ background: C.red }}></i>stop / invalidation</span>
          <span><i style=${{ background: C.green }}></i>target</span><span><i style=${{ background: C.violet }}></i>SK 0 · A · B</span>
          <span><i style=${{ background: C.cyan }}></i>SK C · ST trail</span><span>● EIE waves · ■ SK points · dotted bands = indicator zones</span>
        </div>
      </section>
      <div class="side">
        <${Operation} panels=${st.panels || {}} last=${st.last} />
        <${Bot} b=${st.broker} />
        <${Dossier} name="EIE PRO" rows=${(st.panels || {})['EIE PRO']} />
        <${Dossier} name="SK SEQ" rows=${(st.panels || {})['SK SEQ']} />
      </div>
    </div>
    <${WarRoom} mc=${st.mc} rain=${rain} setRain=${setRain} />
    <${Telemetry} tele=${st.tele} mc=${st.mc} />
    <${Log} events=${st.events || []} />
    <footer>Unofficial personal tool · reads your local TradingView Desktop · not financial advice</footer>
  </div>`;
}
ReactDOM.createRoot(document.getElementById('root')).render(html`<${App} />`);
</script>
</body>
</html>
EOF_UI
echo "Installing dashboard libraries (React, htm, Lightweight Charts) into ~/eie-watch"
(cd "$HOME/eie-watch" && { [ -f package.json ] || npm init -y >/dev/null; } && npm install --no-audit --no-fund react@18.3.1 react-dom@18.3.1 htm@3.1.1 lightweight-charts@4.1.3 >/dev/null && echo "dashboard libraries ok")
cat > "$HOME/eie-watch/probe-trading.mjs" <<'EOF_PROBE'
#!/usr/bin/env node
// READ-ONLY probe v3 of TradingView Desktop's trading UI (clicks nothing, places NO orders).
// Scans EVERY page/webview TradingView Desktop exposes on the debug port (chart, trading panel, dialogs).
// Before running: Paper Trading connected, and an order dialog open (right-click chart → Trade → Create limit order…), not submitted.
// Run:  node ~/eie-watch/probe-trading.mjs      → writes ~/eie-watch/probe.txt
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createRequire } from 'node:module';
const require = createRequire(path.join(os.homedir(), 'tradingview-mcp', 'package.json'));
const CDP = require('chrome-remote-interface');
const PORT = Number(process.env.TV_CDP_PORT || 9222);
const fail = (e) => { console.error('Probe failed: ' + (e?.message || e) + '\nIs TradingView open with the debug port? Start it with:  ~/eie-watch/start.sh'); process.exit(1); };

const DUMP = `(function(){
  var vis = function(el){ var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'; };
  var lbl = function(el){ var p = el, t = ''; for (var i = 0; i < 4 && p && !t; i++, p = p.parentElement) { t = (p.innerText || '').trim().split('\\n').slice(0, 3).join(' | '); } return t.slice(0, 80); };
  var R = { url: location.href, title: document.title, broker: [], inputs: [], buttons: [], dataNames: [], frames: document.querySelectorAll('iframe, webview').length };
  var text = (document.body && document.body.innerText) || '';
  (text.match(/[^\\n]{0,40}(Paper Trading|FOREX\\.com|Forex\\.com|PU Prime|Demo|DEMO|Live|LIVE|Real account|Account Balance|Equity)[^\\n]{0,40}/g) || []).slice(0, 25)
    .forEach(function(s){ if (R.broker.indexOf(s) < 0) R.broker.push(s); });
  document.querySelectorAll('input, select, textarea, [contenteditable="true"]').forEach(function(el){
    if (!vis(el) || R.inputs.length >= 80) return;
    R.inputs.push({ tag: el.tagName, type: el.type || '', name: el.name || '', dataName: el.getAttribute('data-name') || '', aria: el.getAttribute('aria-label') || '',
      placeholder: el.getAttribute('placeholder') || '', value: (el.value || '').slice(0, 20), label: lbl(el), cls: String(el.className || '').slice(0, 60) });
  });
  document.querySelectorAll('button, [role=button], [role=tab], [role=radio], [role=switch], [role=checkbox]').forEach(function(el){
    if (!vis(el) || R.buttons.length >= 200) return;
    var t = (el.innerText || el.getAttribute('aria-label') || el.getAttribute('title') || '').trim().replace(/\\s+/g, ' ').slice(0, 50);
    if (!t && !el.getAttribute('data-name')) return;
    R.buttons.push({ text: t, dataName: el.getAttribute('data-name') || '', role: el.getAttribute('role') || el.tagName, aria: el.getAttribute('aria-label') || '',
      state: el.getAttribute('aria-pressed') || el.getAttribute('aria-selected') || el.getAttribute('aria-checked') || '' });
  });
  var seen = {};
  document.querySelectorAll('[data-name]').forEach(function(el){ var d = el.getAttribute('data-name'); if (/order|trad|account|broker|position|buy|sell|bracket|take|stop|qty|quantity|price|place|paper/i.test(d) && !seen[d]) { seen[d] = 1; R.dataNames.push(d); } });
  return R;
})()`;

setTimeout(() => { console.error('Probe timed out after 60 s (partial results saved if any).'); save(); process.exit(1); }, 60000).unref?.();
const withTimeout = (p, ms, what) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`${what} timed out after ${ms / 1000}s`)), ms))]);
const list = await withTimeout(CDP.List({ host: '127.0.0.1', port: PORT }), 5000, 'listing pages').catch(fail);
console.log(`TradingView exposes ${list.length} debug targets; scanning…`);
const results = [];
const dir = path.join(os.homedir(), 'eie-watch');
const save = () => { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, 'probe.txt'), JSON.stringify(results, null, 2)); };
for (const t of list) {
  const entry = { id: t.id, type: t.type, title: t.title, url: (t.url || '').slice(0, 120) };
  if (!['page', 'webview', 'iframe'].includes(t.type) || /devtools:|^chrome-extension:/.test(t.url || '')) { results.push(entry); console.log(`  skip [${t.type}] ${(t.title || t.url || '').slice(0, 60)}`); continue; }
  let client;
  try {
    client = await withTimeout(CDP({ host: '127.0.0.1', port: PORT, target: t.id }), 5000, 'connect');
    const r = await withTimeout(client.Runtime.evaluate({ expression: DUMP, returnByValue: true }), 5000, 'read page');
    entry.dom = r.result?.value || { error: r.exceptionDetails?.text };
  } catch (e) { entry.error = e.message; }
  finally { try { await client?.close(); } catch {} }
  results.push(entry);
  const d = entry.dom;
  console.log(`  [${t.type}] ${(t.title || '').slice(0, 50)} · ${d ? `${d.inputs.length} inputs · ${d.buttons.length} buttons · broker: ${JSON.stringify(d.broker.slice(0, 2))}` : entry.error}`);
  save();
}
save();
console.log(`\nWrote ${path.join(dir, 'probe.txt')} — paste its contents (or attach the file) back to Claude.`);
process.exit(0);
EOF_PROBE
cat > "$HOME/eie-watch/mc-worker.mjs" <<'EOF_MCW'
// Monte Carlo worker (runs on its own CPU core via worker_threads).
// Simulates prop-firm challenge paths from a trade-outcome model and returns aggregates plus a few
// sampled equity curves for the War Room fan chart. Bayesian: each path draws its own win rate from
// Beta(wins + 1, losses + 1), so small samples produce honestly wider outcomes.
import { parentPort } from 'node:worker_threads';

parentPort.on('message', (job) => {
  const { id, n, seed, P } = job;
  let s = (seed >>> 0) || 1;
  const rnd = () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
  const gauss = () => { let u = 0; while (u === 0) u = rnd(); const v = rnd(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); };
  const gamma = (a) => {                    // Marsaglia–Tsang
    if (a < 1) return gamma(a + 1) * Math.pow(rnd() || 1e-12, 1 / a);
    const d = a - 1 / 3, c = 1 / Math.sqrt(9 * d);
    for (;;) {
      let x, v;
      do { x = gauss(); v = 1 + c * x; } while (v <= 0);
      v = v * v * v;
      const u = rnd();
      if (u < 1 - 0.0331 * x ** 4) return d * v;
      if (Math.log(u) < 0.5 * x * x + d * (1 - v + Math.log(v))) return d * v;
    }
  };
  const beta = (a, b) => { const x = gamma(a), y = gamma(b); return x / (x + y); };

  const H = P.horizon;
  const ddBins = new Array(41).fill(0);     // max drawdown 0 … 20 % in 0.5 % steps
  const stBins = new Array(31).fill(0);     // longest losing streak 0 … 30
  let pass = 0, breach = 0, daily = 0, open = 0, ttpSum = 0;
  const sampled = [];
  const every = Math.max(1, Math.floor(n / Math.max(1, P.sample)));
  for (let i = 0; i < n; i++) {
    const p = P.bayes ? beta(P.wins + 1, P.losses + 1) : P.wins / Math.max(1, P.wins + P.losses);
    let eq = 0, peak = 0, mdd = 0, run = 0, mrun = 0, res = 0, dayStart = 0, k = 1;
    const keep = i % every === 0 ? new Array(H + 1).fill(0) : null;
    for (; k <= H; k++) {
      if ((k - 1) % P.perDay === 0) dayStart = eq;
      const win = rnd() < p;
      eq += (win ? P.W : P.L) * P.risk;
      if (eq > peak) peak = eq;
      if (peak - eq > mdd) mdd = peak - eq;
      run = win ? 0 : run + 1;
      if (run > mrun) mrun = run;
      if (keep) keep[k] = eq;
      if (eq >= P.target) { res = 1; break; }
      if (eq <= -P.maxLoss) { res = -1; break; }
      if (dayStart - eq >= P.dailyLoss) { res = -2; break; }
    }
    if (keep) { for (let j = k + 1; j <= H; j++) keep[j] = eq; sampled.push({ r: res, e: keep.map(v => Math.round(v * 100) / 100) }); }
    if (res === 1) { pass++; ttpSum += k; } else if (res === -1) breach++; else if (res === -2) daily++; else open++;
    ddBins[Math.min(40, Math.floor(mdd / 0.5))]++;
    stBins[Math.min(30, mrun)]++;
  }
  parentPort.postMessage({ id, viz: !!job.viz, n, pass, breach, daily, open, ttpSum, ddBins, stBins, sampled });
});
EOF_MCW
cat > "$HOME/eie-watch/start.sh" <<'EOF_START'
#!/bin/bash
# Starts TradingView Desktop with the local debug port (if needed) and runs the watcher, keeping the computer awake.
# Installed to ~/eie-watch/start.sh by scripts/install.sh. All arguments go to eie-watch.mjs.
W="$HOME/eie-watch"
up() { curl -s --max-time 2 http://127.0.0.1:9222/json/version >/dev/null; }
if [[ " $* " != *" --demo "* && " $* " != *" --selftest "* ]] && ! up; then
  case "$(uname)" in
    Darwin)
      osascript -e 'quit app "TradingView"' >/dev/null 2>&1 || true; sleep 3
      open -a TradingView --args --remote-debugging-port=9222 ;;
    Linux)
      pkill -f -i tradingview >/dev/null 2>&1 || true; sleep 2
      if command -v tradingview >/dev/null 2>&1; then nohup tradingview --remote-debugging-port=9222 >/dev/null 2>&1 &
      elif [ -x /snap/bin/tradingview ]; then nohup /snap/bin/tradingview --remote-debugging-port=9222 >/dev/null 2>&1 &
      else echo "TradingView Desktop not found. Start it yourself with --remote-debugging-port=9222"; fi ;;
  esac
  for i in $(seq 1 45); do up && break; sleep 2; done
  up || echo "WARNING: TradingView debug port 9222 is not up. Run: node $W/doctor.mjs"
  sleep 8
fi
PORT=8787; prev=""; for a in "$@"; do [ "$prev" = "--port" ] && PORT="$a"; prev="$a"; done
case " $* " in *" --ui "*|*" --demo "*)
  (sleep 3; if command -v open >/dev/null 2>&1; then open "http://localhost:$PORT"; elif command -v xdg-open >/dev/null 2>&1; then xdg-open "http://localhost:$PORT"; fi) >/dev/null 2>&1 & ;;
esac
if command -v caffeinate >/dev/null 2>&1; then exec caffeinate -i node "$W/eie-watch.mjs" "$@"
elif command -v systemd-inhibit >/dev/null 2>&1; then exec systemd-inhibit --what=idle:sleep --why="Operation Aurum watcher" node "$W/eie-watch.mjs" "$@"
else exec node "$W/eie-watch.mjs" "$@"; fi
EOF_START
chmod +x "$HOME/eie-watch/start.sh"
cat > "$HOME/eie-watch/doctor.mjs" <<'EOF_DOC'
#!/usr/bin/env node
// Operation Aurum health check. Read-only: never changes the chart, settings or orders.
//   node ~/eie-watch/doctor.mjs           human-readable
//   node ~/eie-watch/doctor.mjs --json    machine-readable (for AI agents)
//   node ~/eie-watch/doctor.mjs --ntfy TOPIC   also send a test push to your phone
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf(k); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const W = path.join(os.homedir(), 'eie-watch');
const BRIDGE = path.join(os.homedir(), 'tradingview-mcp');
const WANT = { 'Elliott Impulse': { short: 'EIE PRO', ver: 10 }, 'SK Sequence': { short: 'SK SEQ', ver: 16 } };
const ASSET = (t) => /XAU|GOLD|^GC|^MGC/i.test(t) ? 'GOLD' : /WTI|USOIL|UKOIL|OIL|^CL|^MCL/i.test(t) ? 'CRUDE' : /BTC|XBT/i.test(t) ? 'BTC' : 'OTHER';
const out = [];
const add = (status, check, detail, fix) => out.push({ status, check, detail, ...(fix ? { fix } : {}) });
const get = async (u, ms = 2500) => { const r = await fetch(u, { signal: AbortSignal.timeout(ms) }); if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); };

// 1. runtime + files
const major = Number(process.versions.node.split('.')[0]);
major >= 18 ? add('PASS', 'Node.js', process.version) : add('FAIL', 'Node.js', process.version, 'Install Node.js 18+ from https://nodejs.org');
const files = ['eie-watch.mjs', 'mc-worker.mjs', 'ui.html', 'start.sh'];
const missing = files.filter(f => !fs.existsSync(path.join(W, f)));
missing.length ? add('FAIL', 'Watcher files', `missing in ${W}: ${missing.join(', ')}`, 'Run: bash scripts/install.sh (from the repo)')
  : add('PASS', 'Watcher files', W);
const libs = ['react', 'react-dom', 'htm', 'lightweight-charts'].filter(l => !fs.existsSync(path.join(W, 'node_modules', l)));
libs.length ? add('FAIL', 'Dashboard libraries', `missing: ${libs.join(', ')}`, `Run: cd ${W} && npm install`) : add('PASS', 'Dashboard libraries', 'react · react-dom · htm · lightweight-charts');
const bridgeOk = fs.existsSync(path.join(BRIDGE, 'src', 'server.js')) && fs.existsSync(path.join(BRIDGE, 'node_modules'));
bridgeOk ? add('PASS', 'TradingView bridge', BRIDGE) : add('FAIL', 'TradingView bridge', `not installed at ${BRIDGE}`, 'Run: bash scripts/install.sh (without --demo-only)');

// 2. TradingView Desktop debug port
let chart = null;
try {
  const v = await get('http://127.0.0.1:9222/json/version');
  add('PASS', 'TradingView debug port 9222', v.Browser || 'up');
  const list = await get('http://127.0.0.1:9222/json/list');
  chart = list.find(t => t.type === 'page' && /tradingview\.com\/chart/.test(t.url || ''));
  chart ? add('PASS', 'Chart page', chart.title || chart.url) : add('FAIL', 'Chart page', 'no chart open', 'Open a chart tab in TradingView Desktop');
} catch (e) {
  add('FAIL', 'TradingView debug port 9222', String(e.message || e), process.platform === 'darwin'
    ? 'Run: ~/eie-watch/start.sh (relaunches TradingView with the port), or: open -a TradingView --args --remote-debugging-port=9222'
    : 'Start TradingView Desktop with --remote-debugging-port=9222 (or run ~/eie-watch/start.sh)');
}

// 3. indicators + symbol on the chart (read-only evaluate)
if (chart && bridgeOk) {
  let client;
  try {
    const CDP = createRequire(path.join(BRIDGE, 'package.json'))('chrome-remote-interface');
    client = await CDP({ host: '127.0.0.1', port: 9222, target: chart.id });
    const r = await client.Runtime.evaluate({ returnByValue: true, expression: `(function(){ var a = window.TradingViewApi._activeChartWidgetWV.value();
      return { symbol: a.symbol(), tf: a.resolution(), studies: (a.getAllStudies() || []).map(function(s){ return s.name; }) }; })()` });
    const v = r.result && r.result.value;
    if (!v) throw new Error(r.exceptionDetails ? r.exceptionDetails.text : 'no result');
    const tick = String(v.symbol).split(':').pop();
    const asset = ASSET(tick);
    add(asset === 'OTHER' ? 'WARN' : 'PASS', 'Chart symbol', `${v.symbol} · ${v.tf}m · asset ${asset}`,
      asset === 'OTHER' ? 'Supported: gold (OANDA:XAUUSD), WTI crude (OANDA:WTICOUSD), Bitcoin (BITSTAMP:BTCUSD); others use generic costs' : undefined);
    for (const [key, w] of Object.entries(WANT)) {
      const s = v.studies.find(n => n.includes(key));
      if (!s) { add('FAIL', w.short + ' indicator', 'not on the chart', `Pine Editor → paste ~/eie-watch/pine/${w.short === 'EIE PRO' ? 'eie_pro_v10' : 'sk_engine_v16'}.pine → Save → Add to chart`); continue; }
      const ver = Number((s.match(/ v(\d+)/) || [])[1]);
      ver >= w.ver ? add('PASS', w.short + ' indicator', s) : add('WARN', w.short + ' indicator', `${s} (latest is v${w.ver})`, 'Replace the script with the version in ~/eie-watch/pine/ for gold/crude/BTC auto costs');
    }
  } catch (e) { add('WARN', 'Indicator check', String(e.message || e), 'Make sure the chart has finished loading, then re-run'); }
  finally { try { await client?.close(); } catch {} }
}

// 4. optional phone push test
const topic = arg('--ntfy', '');
if (topic) {
  try {
    const r = await fetch('https://ntfy.sh/', { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(5000),
      body: JSON.stringify({ topic, title: 'Operation Aurum', message: 'doctor: phone alerts work' }) });
    r.ok ? add('PASS', 'Phone push (ntfy)', `sent to topic ${topic}`) : add('FAIL', 'Phone push (ntfy)', 'HTTP ' + r.status);
  } catch (e) { add('FAIL', 'Phone push (ntfy)', String(e.message || e), 'Check the internet connection'); }
}

const fails = out.filter(o => o.status === 'FAIL').length;
if (argv.includes('--json')) console.log(JSON.stringify({ ok: fails === 0, checks: out }, null, 2));
else {
  const c = { PASS: '\x1b[32m', WARN: '\x1b[33m', FAIL: '\x1b[31m' };
  for (const o of out) console.log(`${c[o.status]}${o.status.padEnd(4)}\x1b[0m  ${o.check.padEnd(28)} ${o.detail}${o.fix ? `\n      → ${o.fix}` : ''}`);
  console.log(fails ? `\n${fails} problem(s) to fix.` : '\nAll required checks passed.');
}
process.exit(fails ? 1 : 0);
EOF_DOC
node "$HOME/eie-watch/eie-watch.mjs" --selftest

say "4/6 Connecting the bridge to Claude Code"
if command -v claude >/dev/null 2>&1; then
  claude mcp remove tradingview -s user >/dev/null 2>&1 || true
  claude mcp add --scope user tradingview -- node "$HOME/tradingview-mcp/src/server.js"
else
  echo "Claude Code CLI not found. Install it (npm install -g @anthropic-ai/claude-code), then run:"
  echo "  claude mcp add --scope user tradingview -- node \"$HOME/tradingview-mcp/src/server.js\""
fi

say "5/6 Relaunching TradingView with the local debug port 9222"
if curl -s --max-time 2 http://127.0.0.1:9222/json/version >/dev/null; then echo "Already running with the debug port, not restarting."; else
osascript -e 'quit app "TradingView"' >/dev/null 2>&1 || true; sleep 3
open -a TradingView --args --remote-debugging-port=9222; fi
for i in $(seq 1 45); do curl -s --max-time 2 http://127.0.0.1:9222/json/version >/dev/null && break; sleep 2; done
if curl -s --max-time 2 http://127.0.0.1:9222/json/version >/dev/null; then echo "TradingView debug port is up."
else echo "Port 9222 did not come up. Open TradingView manually with:"; echo "  open -a TradingView --args --remote-debugging-port=9222"; fi

say "6/6 Done"
cat <<'MSG'
Next:
  1. In TradingView: a gold, WTI crude or Bitcoin chart (1m-15m) with your two indicators, EIE PRO and SK SEQ
     (scripts: pine/eie_pro_v10.pine and pine/sk_engine_v16.pine in the GitHub repo; health check: node ~/eie-watch/doctor.mjs)
     (SK setting "EIE direction source" = EIE PRO: EIE direction).
  2. Start watching (Mac notifications when EIE PRO / SK SEQ place, move, fill or cancel a limit):
       ~/eie-watch/start.sh
     Operation Aurum dashboard + Monte Carlo War Room (opens in your browser):
       ~/eie-watch/start.sh --ui            (live, from TradingView)
       ~/eie-watch/start.sh --demo          (preview with a synthetic feed)
     Auto-trade TradingView Paper Trading (order dialog open: right-click chart → Trade → Create limit order):
       ~/eie-watch/start.sh --ui --trade tv-dry   (fills + verifies the dialog, does NOT click Place)
       ~/eie-watch/start.sh --ui --trade tv       (places the order; refuses unless the account is Paper Trading)
     One test order (smallest size, 2% below market, Paper only) to see it work:  node ~/eie-watch/eie-watch.mjs --tv-test
     Or a built-in simulated account:  ~/eie-watch/start.sh --ui --trade paper
     Every bot order is logged to ~/eie-watch/trades.csv
     Phone too (free): install the "ntfy" app, subscribe to a long random topic, then:
       ~/eie-watch/start.sh --ntfy YOUR-LONG-RANDOM-TOPIC
     Gold, crude and Bitcoin on one chart (switches symbol every 20 s; don't trade on that chart):
       ~/eie-watch/start.sh --rotate "OANDA:XAUUSD,OANDA:WTICOUSD,BITSTAMP:BTCUSD" --dwell 20
  3. Ask Claude about signals:   cd ~/eie-watch && claude
  4. Repaint audit summary:       cat ~/eie-watch/report.txt   (updated every 10 min and on Ctrl+C)
Port 9222 listens only on this Mac, but any program on this Mac can control TradingView while it is open.
MSG

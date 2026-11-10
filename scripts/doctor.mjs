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
const WANT = { 'Elliott Impulse': { short: 'EIE PRO', ver: 11 }, 'SK Sequence': { short: 'SK SEQ', ver: 17 } };
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
    add(asset === 'OTHER' ? 'FAIL' : 'PASS', 'Chart symbol', `${v.symbol} · ${v.tf}m · asset ${asset}`,
      asset === 'OTHER' ? 'Supported: gold (OANDA:XAUUSD), WTI crude (OANDA:WTICOUSD), Bitcoin (BITSTAMP:BTCUSD) only. Switch the chart symbol' : undefined);
    for (const [key, w] of Object.entries(WANT)) {
      const s = v.studies.find(n => n.includes(key));
      if (!s) { add('FAIL', w.short + ' indicator', 'not on the chart', `Pine Editor → paste ~/eie-watch/pine/${w.short === 'EIE PRO' ? 'eie_pro_v11' : 'sk_engine_v17'}.pine → Save → Add to chart`); continue; }
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

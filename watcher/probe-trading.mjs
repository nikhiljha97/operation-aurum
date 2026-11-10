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

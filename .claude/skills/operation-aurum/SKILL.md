---
name: operation-aurum
description: Install, verify and run Operation Aurum, a TradingView toolkit for gold (XAUUSD), WTI crude oil and Bitcoin (BTCUSD). It covers two Pine indicators (EIE PRO, SK SEQ), a watcher that reads TradingView Desktop, phone alerts, TradingView Paper Trading orders and a Monte Carlo dashboard. Use when someone wants to set up this repo, get it running, check its health, add gold/crude/BTC, get phone alerts, or interpret its signals.
---

# Operation Aurum: setup and operation

You are setting up and running a trading toolkit for someone who may not be technical. Work through the
steps in order, run the commands yourself where you can, and verify every step before moving on.
Talk in plain language. Never paste secrets into chat or commit them.

## Hard rules (always)
1. **Paper trading only.** The watcher's `--trade tv` mode refuses non-Paper accounts. Never add live-money
   order code, and never suggest bypassing that check.
2. **Ask before restarting TradingView.** `start.sh` quits and relaunches TradingView Desktop if its debug
   port is closed. Say so first.
3. **Don't place, move or cancel orders yourself.** Only the watcher does that, in modes the user picked.
4. **The user pastes the Pine scripts.** TradingView has no API for saving indicators. Give exact clicks.
5. Statistics shown by the indicators are back-tests on one chart. They are not a promise of future results.
   Say so if the user treats them as one.

## Step 1: ask four things (one message)
- **Computer:** macOS (fully supported), Linux (watcher + TradingView snap), Windows (manual: see below).
- **Assets:** any of gold, WTI crude, Bitcoin. Suggested symbols (TradingView Paper Trading can trade them):
  gold `OANDA:XAUUSD` · crude `OANDA:WTICOUSD` · Bitcoin `BITSTAMP:BTCUSD` (or `COINBASE:BTCUSD`).
- **Mode:** alerts only · dashboard · auto-place orders in TradingView **Paper Trading**.
- **Phone alerts:** yes/no. If yes, they need the free **ntfy** app and a long random topic name you
  generate for them (e.g. `aurum-` + 10 random letters/digits). Anyone who knows the topic can read it.

## Step 2: install
From the repo root:
```bash
bash scripts/install.sh
```
It is idempotent (safe to re-run after `git pull`). It installs:
- `~/tradingview-mcp`: the chart bridge (MCP server, reads TradingView Desktop over local port 9222)
- `~/eie-watch`: the watcher, dashboard, `doctor.mjs`, `start.sh`, and a copy of the Pine scripts in `pine/`
- npm packages (React, htm, Lightweight Charts) and a self-test that must print `SELFTEST PASS`

If Node.js 18+ is missing on macOS without Homebrew, send the user to https://nodejs.org (LTS installer), then re-run.
With no TradingView yet (just a preview): `bash scripts/install.sh --demo-only`.

**Windows:** no script. Install Node.js 18+ and git, then:
`git clone https://github.com/tradesdontlie/tradingview-mcp %USERPROFILE%\tradingview-mcp`, run `npm install` there.
Copy `watcher\*` and `scripts\doctor.mjs` to `%USERPROFILE%\eie-watch`, run `npm install` there.
Start TradingView with `"%LOCALAPPDATA%\TradingView\TradingView.exe" --remote-debugging-port=9222`.
Run `node %USERPROFILE%\eie-watch\eie-watch.mjs --ui`.

## Step 3: health check (repeat until clean)
```bash
node ~/eie-watch/doctor.mjs --json
```
Each failed check has a `fix`. Apply it (or walk the user through it), then re-run. Fixes for common
problems are in [references/troubleshooting.md](references/troubleshooting.md).

## Step 4: indicators (the user does this in TradingView)
Free TradingView plan = max 2 indicators, so both scripts bundle everything. For each file
`~/eie-watch/pine/eie_pro_v12.pine` and `~/eie-watch/pine/sk_engine_v18.pine`:
1. TradingView → **Pine Editor** (bottom panel) → **⋯/Open → New indicator**.
2. Select all (Cmd/Ctrl+A), delete, paste the whole file. Don't paste on top of the template.
3. **Save** (name it), then **Add to chart**.

Then in **SK SEQ settings**, set "EIE direction source" to `EIE PRO: EIE direction`.
Any timeframe from 1m to 4H works. The trend filter automatically uses the next higher timeframe (3m→15m, 5m/15m→1H, 30m/1H→4H). Costs and round numbers adapt to the asset. The panels show `GOLD`, `CRUDE` or `BTC`.
Only gold, crude oil and Bitcoin are supported: on other symbols the indicators stop with a message and the watcher does not trade.
Re-run the doctor; both indicators should be PASS.

## Step 5: run it
Always go in this order, confirming each before the next:
```bash
~/eie-watch/start.sh --demo                       # 1. dashboard preview, fake data
~/eie-watch/start.sh --ui                         # 2. live: reads the chart, desktop notifications
~/eie-watch/start.sh --ui --trade tv-dry          # 3. fills the Paper order dialog, does NOT click Place
~/eie-watch/start.sh --ui --trade tv              # 4. places orders in TradingView Paper Trading
```
Add `--ntfy TOPIC` for phone pushes (`node ~/eie-watch/doctor.mjs --ntfy TOPIC` sends a test).
Several assets on **one** chart: add `--rotate "OANDA:XAUUSD,OANDA:WTICOUSD,BITSTAMP:BTCUSD" --dwell 20`. The chart switches
symbol every 20 s, so the user shouldn't trade by hand on that chart. Two TradingView windows or tabs is the alternative.
Before step 4, have the user open the order panel once (right-click chart → Trade → Create limit order) and set
quantity to **Units**. One test order (smallest size, 2% below market, should not fill):
`node ~/eie-watch/eie-watch.mjs --tv-test`. Afterwards the user should cancel it in the Orders tab.

The dashboard is at http://localhost:8787 and only listens on this computer. To see it on a phone, use Tailscale:
`tailscale serve --bg 8787`, then open the printed address on the phone (same Tailscale account).
The computer must stay awake. `start.sh` prevents idle sleep, but closing a laptop lid on battery still sleeps it.

## Step 6: day-to-day help
- Logs live in `~/eie-watch`: `events.jsonl` (every event), `trades.csv` (bot orders and results),
  `report.txt` (repaint audit). Read them before answering questions about signals.
- For a signal, report: symbol, asset, side, entry/stop/target, R:R, distance to invalidation,
  cost-to-stop ratio, higher-TF alignment, and go / no-go with the reason.
- Risk rules built into the watcher: `--risk 25` ($ per trade, 0.5% of 5K), 1:2 R:R, max 5 trades/day,
  stop after 2 losses, one open position across all assets.

## Asset notes
| | Gold | WTI crude | Bitcoin |
|---|---|---|---|
| Auto cost (round trip) | 0.35 | 0.04 | 0.03% of price (~$30 at 100k) |
| Min order size (watcher) | 1 unit | 1 unit | 0.001 BTC |
| News blackout | CPI, NFP, extra events | + EIA Wed 10:30 ET | CPI, NFP, extra events |
| Trading hours | ~23/5 | ~23/5 | 24/7, thin on weekends |

Add FOMC and other events in either indicator: "Extra events" input, `YYYYMMDD-HHMM` New York time.
Watcher overrides: `--spread X` (cost per unit for the built-in paper account), `--risk`, `--max-trades`, `--max-losses`.

## Updating
```bash
git pull && bash scripts/install.sh
```
If `pine/` changed, the user re-pastes the changed script(s). The dashboard's SYNC strip shows each indicator's version and settings fingerprint.

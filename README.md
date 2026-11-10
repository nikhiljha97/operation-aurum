# Operation Aurum

Toolkit for trading XAUUSD and WTI crude with two TradingView indicators, plus a watcher on the Mac
that turns indicator signals into alerts, TradingView **Paper Trading** orders and a live dashboard.

> Paper trading only. Nothing here is financial advice.

## Layout
| Path | What it is |
|---|---|
| `pine/eie_pro_v9.pine` | **EIE PRO**: Elliott impulse engine (fork of Elliott Impulse Engine by WillyAlgoTrader) with Auto-ML, macro, session filters and incremental Monte Carlo |
| `pine/sk_engine_v15.pine` | **SK SEQ**: SK System (0/A/B/C, WCL, counter-trend) with Auto-ML, macro, news blackout, Monte Carlo, Super Signal and built-in SuperTrend AI (lite) |
| `pine/archive/` | Earlier versions |
| `watcher/eie-watch.mjs` | Reads TradingView Desktop over CDP (port 9222): signals, repaint audit, settings sync, paper orders, phone pushes (ntfy), dashboard server |
| `watcher/mc-worker.mjs` | Monte Carlo worker thread (Bayesian win rate, prop-firm rules) |
| `watcher/ui.html` | Operation Aurum dashboard (React + lightweight-charts): War Room, sync strip, telemetry |
| `watcher/probe-trading.mjs` | Read-only probe of TradingView's order dialog |
| `eie_setup.sh` | One-shot macOS installer (contains all watcher files) |
| `research/` | Prop-firm, losing-streak, Auto-ML and SuperTrend simulations; Pine compile checker; mock order dialogs |

## Install (macOS)
```bash
bash eie_setup.sh
~/eie-watch/start.sh --ui --trade tv --ntfy YOUR-LONG-RANDOM-TOPIC
```
Preview without TradingView: `~/eie-watch/start.sh --demo`

## Free TradingView plan limits
At most 2 indicators, no alerts, 0.5 s script time. That is why both Pine scripts bundle everything,
and why the heavy Monte Carlo runs in the watcher.

## Data flow
TradingView chart → watcher (reads panels and drawings about every second) → dashboard / ntfy / paper orders.
Nothing is written back into the indicators.

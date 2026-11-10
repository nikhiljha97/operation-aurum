# Operation Aurum

Toolkit for trading **gold (XAUUSD), WTI crude oil and Bitcoin (BTCUSD)** with two TradingView indicators. A watcher
on your computer turns indicator signals into desktop and phone alerts and TradingView **Paper Trading** orders, and
runs a live Monte Carlo dashboard.

> Paper trading only. Nothing here is financial advice. Back-test statistics do not predict future results.

## Quick start

### With an AI agent (recommended)
Open the repo in any AI coding agent (Claude Code, Codex, Cursor, Gemini CLI, ...) and say:

> Set up Operation Aurum for me.

The agent follows [`.claude/skills/operation-aurum/SKILL.md`](.claude/skills/operation-aurum/SKILL.md). It installs
dependencies, runs the health check, walks you through adding the indicators, and starts the watcher.
`AGENTS.md` points agents that don't use Claude skills to the same runbook.

### By hand (macOS / Linux)
```bash
git clone https://github.com/nikhiljha97/operation-aurum && cd operation-aurum
bash scripts/install.sh
node ~/eie-watch/doctor.mjs
~/eie-watch/start.sh --demo
```
Then paste `pine/eie_pro_v12.pine` and `pine/sk_engine_v18.pine` into TradingView's Pine Editor (Save → Add to chart)
and run `~/eie-watch/start.sh --ui`.

## Supported assets
| Asset | Suggested symbol | Auto cost (round trip) | Min size | Extra news blackout |
|---|---|---|---|---|
| Gold | `OANDA:XAUUSD` | 0.35 | 1 unit | — |
| WTI crude | `OANDA:WTICOUSD` | 0.04 | 1 unit | EIA, Wed 10:30 ET |
| Bitcoin | `BITSTAMP:BTCUSD` | 0.03% of price | 0.001 BTC | — (trades 24/7) |

CPI and NFP blackouts apply to all three. Add FOMC and other events in the indicators' "Extra events" input.
Only these three markets are supported for now: on any other symbol the indicators stop with a message (setting "Supported markets only") and the watcher does not trade. Any timeframe from 1m to 4H works; the trend filter picks the next higher timeframe automatically.

## Layout
| Path | What it is |
|---|---|
| `pine/eie_pro_v12.pine` | **EIE PRO**: Elliott impulse engine (fork of Elliott Impulse Engine by WillyAlgoTrader) with Auto-ML, macro, session filters, Monte Carlo |
| `pine/sk_engine_v18.pine` | **SK SEQ**: SK System (0/A/B/C, WCL, counter-trend) with Auto-ML, macro, news blackout, Monte Carlo, Super Signal, SuperTrend AI (lite) |
| `watcher/` | Node.js watcher (`eie-watch.mjs`), Monte Carlo worker, Operation Aurum dashboard |
| `scripts/install.sh` · `start.sh` · `doctor.mjs` | Installer, launcher, health check |
| `eie_setup.sh` | Single-file macOS installer (rebuilt with `scripts/pack-standalone.py`) |
| `.claude/skills/operation-aurum/` | Agent runbook (setup, operation, troubleshooting) |
| `research/` | Prop-firm, losing-streak, Auto-ML and SuperTrend simulations; Pine compile checker |

## Phone alerts
Install the free **ntfy** app and subscribe to a long random topic, then run
`~/eie-watch/start.sh --ui --ntfy YOUR-TOPIC`. To see the dashboard on your phone, use Tailscale:
`tailscale serve --bg 8787`.

## Data flow
TradingView chart → watcher (reads panels and drawings about every second) → dashboard, alerts, Paper orders.
Nothing is written back into the indicators. Free TradingView plan limits (2 indicators, no alerts, 0.5 s script time)
are why both Pine scripts bundle everything and why the heavy Monte Carlo runs in the watcher.

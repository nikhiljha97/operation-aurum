# Instructions for AI coding agents

This file is for any AI agent (Claude Code, Codex, Cursor, Gemini CLI, Copilot, Aider, ...) working in this repo.

**To set up or run the project, follow `.claude/skills/operation-aurum/SKILL.md` step by step.**
It is a plain-markdown runbook (Agent Skills format) and works with any agent that can run shell commands.
Troubleshooting: `.claude/skills/operation-aurum/references/troubleshooting.md`.

Quick path:
```bash
bash scripts/install.sh               # installs everything into ~/tradingview-mcp and ~/eie-watch
node ~/eie-watch/doctor.mjs --json    # health check; every failure includes a fix
~/eie-watch/start.sh --demo           # dashboard preview without TradingView
```

## Rules
- Paper trading only. Do not add live-money order paths or weaken the Paper-account check in `tvPlaceOrder`.
- Ask before restarting TradingView Desktop. Never place, move or cancel orders yourself.
- Never commit secrets, logs (`events.jsonl`, `trades.csv`) or `node_modules`.

## Layout
- `pine/`: TradingView indicators, current `eie_pro_v11.pine` and `sk_engine_v17.pine`; old versions in `pine/archive/`.
  The free plan allows 2 indicators and 0.5 s of script time, so keep new features inside these two and stay light.
- `watcher/`: Node.js watcher (`eie-watch.mjs`), Monte Carlo worker, dashboard (`ui.html`).
  Run `node watcher/eie-watch.mjs --selftest` after any change. It must print `SELFTEST PASS`.
- `scripts/`: `install.sh`, `start.sh`, `doctor.mjs`, `pack-standalone.py` (rebuilds the single-file installer `eie_setup.sh`).
- `research/`: simulations behind the risk and model choices. `pinecheck.py FILE` compile-checks a Pine script online.

## Assets
Gold, WTI crude and Bitcoin are supported. Per-asset costs and sizes live in two places, which must agree:
`ASSETS` in `watcher/eie-watch.mjs` and the "Asset profile" block in both Pine scripts.

# Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `TradingView debug port 9222` FAIL | TradingView was opened normally (no debug port) | macOS: `~/eie-watch/start.sh` (asks TradingView to quit and relaunch) or `open -a TradingView --args --remote-debugging-port=9222`. Linux: `tradingview --remote-debugging-port=9222`. Windows: `"%LOCALAPPDATA%\TradingView\TradingView.exe" --remote-debugging-port=9222` |
| `Chart page` FAIL | TradingView is open on a non-chart page | Open a chart tab |
| Indicator FAIL "not on the chart" | Script not added, or renamed | Paste from `~/eie-watch/pine/`, Save, Add to chart. The title must still contain "Elliott Impulse" / "SK Sequence" |
| Pine error "2 declarations" / "already declared" | Pasted on top of the template | Select all, delete, then paste |
| Pine runtime error "takes too long … 0.5 s" (free plan) | Too much history / heavy options | In SK SEQ untick the SuperTrend vote or use a higher timeframe; reload the chart |
| SK SEQ appears in a separate pane | Was saved as non-overlay earlier | Pane menu → Move to → Main pane, or remove and re-add |
| Watcher: `NO_INDICATOR` | Indicator filter mismatch | `--study "Elliott Impulse" --sk "SK Sequence"` (defaults) |
| Watcher: `stop … too wide for $25 risk` | Stop distance × min size > risk | Expected on BTC with wide stops; raise `--risk` only if the user wants more risk per trade |
| `could not switch quantity to units` | Order panel set to USD margin / lots | Open the order panel once and set quantity to **Units** |
| Order "unverified" | Orders tab count updated late | Check the Orders tab; the bot blocks new orders until it is cleared |
| Dashboard blank | npm libraries missing | `cd ~/eie-watch && npm install` |
| `SELFTEST FAIL` | Edited / partial watcher copy | `git pull && bash scripts/install.sh` |
| No phone pushes | Topic mismatch or app not subscribed | `node ~/eie-watch/doctor.mjs --ntfy TOPIC`; subscribe to exactly that topic in the ntfy app |
| Nothing happens overnight | Computer slept | Keep it on power; `start.sh` already blocks idle sleep |
| `npm EACCES` | Global npm permissions | Never use sudo for this repo; everything installs under the home folder |

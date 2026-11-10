#!/bin/bash
# Operation Aurum installer (macOS; Linux works for the watcher + TradingView Desktop snap).
# Idempotent: re-run it after `git pull` to update ~/eie-watch.
#   bash scripts/install.sh              full install
#   bash scripts/install.sh --demo-only  skip the TradingView bridge (dashboard demo + self-test only)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$HOME/eie-watch"; BRIDGE="$HOME/tradingview-mcp"
DEMO_ONLY=0; [[ " $* " == *" --demo-only "* ]] && DEMO_ONLY=1
say(){ printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
die(){ printf "\n\033[1;31mERROR: %s\033[0m\n" "$*"; exit 1; }

say "1/6 Checking system"
OS="$(uname)"
case "$OS" in Darwin|Linux) echo "OS: $OS";; *) die "Unsupported OS '$OS'. Use macOS or Linux. On Windows the watcher can run with Node.js directly (see README), but this script does not support it.";; esac
command -v git >/dev/null 2>&1 || { [ "$OS" = Darwin ] && xcode-select --install || true; die "git is missing. Install it and re-run."; }
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 18 ]; then
  if [ "$OS" = Darwin ] && command -v brew >/dev/null 2>&1; then brew install node
  else die "Node.js 18+ is required (found: $(node -v 2>/dev/null || echo none)). Install the LTS from https://nodejs.org and re-run."; fi
fi
command -v npm >/dev/null 2>&1 || die "npm is missing (it ships with Node.js)."
echo "node $(node -v) · npm $(npm -v) · git ok"

say "2/6 TradingView Desktop bridge → $BRIDGE"
if [ "$DEMO_ONLY" = 1 ]; then echo "skipped (--demo-only)"
else
  if [ -d "$BRIDGE/.git" ]; then git -C "$BRIDGE" pull --ff-only || echo "(could not update the bridge, keeping the installed version)"
  else git clone https://github.com/tradesdontlie/tradingview-mcp.git "$BRIDGE"; fi
  (cd "$BRIDGE" && npm install --no-audit --no-fund)
fi

say "3/6 Watcher → $W"
mkdir -p "$W/pine"; rm -f "$W"/pine/eie_pro_v*.pine "$W"/pine/sk_engine_v*.pine
for f in eie-watch.mjs mc-worker.mjs ui.html probe-trading.mjs CLAUDE.md package.json; do cp "$REPO/watcher/$f" "$W/$f"; done
cp "$REPO/scripts/doctor.mjs" "$W/doctor.mjs"
cp "$REPO/scripts/start.sh" "$W/start.sh"; chmod +x "$W/start.sh"
cp "$REPO"/pine/*.pine "$W/pine/"
echo "installed: $(ls "$W" | tr '\n' ' ')"

say "4/6 Dashboard libraries (React, htm, Lightweight Charts)"
(cd "$W" && npm install --no-audit --no-fund --omit=dev)

say "5/6 Self-test"
node "$W/eie-watch.mjs" --selftest | tail -3

say "6/6 Connecting the chart bridge to AI agents (MCP)"
if [ "$DEMO_ONLY" = 1 ]; then echo "skipped (--demo-only)"
elif command -v claude >/dev/null 2>&1; then
  claude mcp remove tradingview -s user >/dev/null 2>&1 || true
  claude mcp add --scope user tradingview -- node "$BRIDGE/src/server.js" && echo "Claude Code: MCP server 'tradingview' added"
else echo "Claude Code CLI not found; skipping."; fi
[ "$DEMO_ONLY" = 1 ] || cat <<MCP
Any other MCP-capable agent (Claude Desktop, Cursor, Codex, Gemini CLI, Continue, ...) — add this server:
  { "mcpServers": { "tradingview": { "command": "node", "args": ["$BRIDGE/src/server.js"] } } }
MCP

cat <<MSG

Installed. Next:
  node ~/eie-watch/doctor.mjs                         health check (tells you what is still missing)
  ~/eie-watch/start.sh --demo                         dashboard preview, no TradingView needed
  ~/eie-watch/start.sh --ui                           live: alerts + dashboard (TradingView open, indicators on chart)
  ~/eie-watch/start.sh --ui --trade tv-dry            fill the Paper Trading order dialog but don't click Place
  ~/eie-watch/start.sh --ui --trade tv --ntfy TOPIC   place Paper Trading orders + phone pushes
Indicators to paste into TradingView's Pine Editor: ~/eie-watch/pine/eie_pro_v11.pine and sk_engine_v17.pine
MSG

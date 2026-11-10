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
